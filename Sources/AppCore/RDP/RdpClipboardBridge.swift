import AppKit
import CFreeRDP
import Foundation

// MARK: - Pure helpers (unit-tested)

/// CF_UNICODETEXT <-> String conversion with a hard size cap. Never logs content.
public enum RdpClipboardText {
  public static let cfUnicodeText: UInt32 = 13
  /// Max wire payload (bytes) accepted or produced in either direction.
  public static let maxBytes = 1 << 20

  /// UTF-16LE with trailing NUL; nil if empty or over the cap.
  public static func encode(_ text: String, maxBytes: Int = maxBytes) -> Data? {
    guard !text.isEmpty else { return nil }
    var data = Data()
    data.reserveCapacity(text.utf16.count * 2 + 2)
    for unit in text.utf16 {
      data.append(UInt8(unit & 0xFF))
      data.append(UInt8(unit >> 8))
    }
    data.append(contentsOf: [0, 0])
    return data.count <= maxBytes ? data : nil
  }

  /// Decodes up to the first NUL; nil if over the cap, empty, or not valid UTF-16.
  public static func decode(_ data: Data, maxBytes: Int = maxBytes) -> String? {
    guard data.count <= maxBytes else { return nil }
    var end = data.startIndex
    while end + 1 < data.endIndex, data[end] != 0 || data[end + 1] != 0 { end += 2 }
    guard end > data.startIndex else { return nil }
    return String(data: data[data.startIndex..<end], encoding: .utf16LittleEndian)
  }
}

// MARK: - cliprdr <-> NSPasteboard

/// Text and bounded file clipboard sync. Not thread-safe except `setActive`: every other member is used
/// only from the RDP thread (channel callbacks and `pollLocalChange`).
/// Only the focused session may announce or request a new clipboard selection.
/// An already requested file download may finish after switching to Finder.
final class RdpClipboardBridge: @unchecked Sendable {
  private let activeLock = NSLock()
  private var active = false
  private let pasteboard: NSPasteboard

  private var context: UnsafeMutablePointer<CliprdrClientContext>?
  private var announcedChangeCount: Int
  private var ready = false
  private var announcedText = false
  private var formatDeadline: Date?
  private var formatTimedOut = false
  private let files: RdpClipboardFileChannel
  private var requestedChangeCount = 0
  private var requestedFormat: UInt32?
  private var requestedGeneration: UInt64 = 0
  private var generation: UInt64 = 0
  private var remoteFormat: UInt32?
  private var remoteIsFiles = false
  private var requestIsFiles = false
  private var cancelled = false
  private var becameActive = false
  private var invalidationEpoch: UInt64 = 0
  private var consumedInvalidationEpoch: UInt64 = 0

  func configureFiles(directory: URL?, onStatus: (@Sendable (String, Bool) -> Void)?) {
    files.directory = directory
    files.onStatus = onStatus
  }

  func cancelFileTransfer() {
    activeLock.withLock {
      cancelled = true
      invalidationEpoch &+= 1
    }
  }

  init(pasteboard: NSPasteboard = .general) {
    self.pasteboard = pasteboard
    announcedChangeCount = pasteboard.changeCount
    files = RdpClipboardFileChannel(pasteboard: pasteboard)
  }

  func setActive(_ value: Bool) {
    activeLock.lock()
    if value && !active { becameActive = true }
    active = value
    activeLock.unlock()
  }

  private var isActive: Bool {
    activeLock.lock()
    defer { activeLock.unlock() }
    return active
  }

  /// Applies any pending cross-thread cancellation (`cancelFileTransfer()`) immediately on the RDP thread
  /// before processing incoming channel callbacks or polling local changes.
  @discardableResult
  private func processPendingCancellation(_ context: UnsafeMutablePointer<CliprdrClientContext>?) -> Bool {
    let shouldCancel = activeLock.withLock { () -> Bool in
      guard cancelled || invalidationEpoch != consumedInvalidationEpoch else { return false }
      cancelled = false
      consumedInvalidationEpoch = invalidationEpoch
      return true
    }
    guard shouldCancel else { return false }
    generation &+= 1
    remoteFormat = nil
    requestedFormat = nil
    formatDeadline = nil
    files.cancel(clearPublished: true)
    files.clearSource()
    announcedText = false
    files.onStatus?("Clipboard file transfer cancelled. Copy again to retry.", false)
    if ready, let context {
      var empty = CLIPRDR_FORMAT_LIST(common: .init(msgType: 2, msgFlags: 0, dataLen: 0), numFormats: 0, formats: nil)
      _ = context.pointee.ClientFormatList?(context, &empty)
    }
    return true
  }

  // MARK: Channel hookup (RDP thread)

  func attach(_ ctx: UnsafeMutablePointer<CliprdrClientContext>) {
    ctx.pointee.custom = Unmanaged.passUnretained(self).toOpaque()
    ctx.pointee.MonitorReady = { c, _ in
      guard let c, let me = RdpClipboardBridge.bridge(c) else { return 1 }
      return me.monitorReady(c)
    }
    ctx.pointee.ServerFormatList = { c, list in
      guard let c, let list, let me = RdpClipboardBridge.bridge(c) else { return 1 }
      return me.serverFormatList(c, list)
    }
    ctx.pointee.ServerFormatDataRequest = { c, req in
      guard let c, let req, let me = RdpClipboardBridge.bridge(c) else { return 1 }
      return me.serverDataRequest(c, req.pointee.requestedFormatId)
    }
    ctx.pointee.ServerFormatDataResponse = { c, resp in
      guard let c, let resp, let me = RdpClipboardBridge.bridge(c) else { return 1 }
      return me.serverDataResponse(resp)
    }
    ctx.pointee.ServerCapabilities = { c, caps in
      guard let c, let caps, let me = RdpClipboardBridge.bridge(c) else { return 1 }
      me.files.receiveCapabilities(caps)
      return 0
    }
    ctx.pointee.ServerFileContentsRequest = { c, request in
      guard let c, let request, let me = RdpClipboardBridge.bridge(c) else { return 1 }
      _ = me.processPendingCancellation(c)
      return me.files.serve(c, request.pointee,
        allowed: me.isActive && me.pasteboard.changeCount == me.announcedChangeCount)
    }
    ctx.pointee.ServerFileContentsResponse = { c, response in
      guard let c, let response, let me = RdpClipboardBridge.bridge(c) else { return 1 }
      if me.processPendingCancellation(c) { return 0 }
      me.files.receiveContents(response.pointee, context: c)
      return 0
    }
    context = ctx
  }

  func detach() {
    context?.pointee.custom = nil
    context = nil
    ready = false
    requestedFormat = nil
    remoteFormat = nil
    files.cancel(clearPublished: true)
    files.clearSource()
  }

  private static func bridge(_ c: UnsafeMutablePointer<CliprdrClientContext>) -> RdpClipboardBridge? {
    c.pointee.custom.map { Unmanaged<RdpClipboardBridge>.fromOpaque($0).takeUnretainedValue() }
  }

  /// Call periodically from the RDP loop; advances transfers and announces local selections.
  func pollLocalChange() {
    guard ready, let context else { return }
    _ = processPendingCancellation(context)
    files.poll()
    if let formatDeadline, Date() > formatDeadline {
      self.formatDeadline = nil
      formatTimedOut = true
      files.onStatus?("Clipboard response timed out. Reconnect to retry file copy.", false)
    }
    guard isActive else { return }
    let count = pasteboard.changeCount
    let refresh = activeLock.withLock { let value = becameActive; becameActive = false; return value }
    guard refresh || count != announcedChangeCount else { return }
    if count == files.publishedChangeCount { announcedChangeCount = count; return }
    if refresh, count == announcedChangeCount, remoteFormat != nil { return }
    announcedChangeCount = count
    generation &+= 1
    remoteFormat = nil
    files.cancel(clearPublished: false)
    sendFormatList(context, available: hasLocalText)
  }

  // MARK: Protocol steps

  private func monitorReady(_ c: UnsafeMutablePointer<CliprdrClientContext>) -> UInt32 {
    var general = CLIPRDR_GENERAL_CAPABILITY_SET(
      capabilitySetType: 1, capabilitySetLength: 12, version: 2, generalFlags: 0xE)  // long names + streaming + no absolute file paths
    let rc: UInt32 = withUnsafeMutablePointer(to: &general) { gp in
      gp.withMemoryRebound(to: CLIPRDR_CAPABILITY_SET.self, capacity: 1) { sets in
        var caps = CLIPRDR_CAPABILITIES(
          common: CLIPRDR_HEADER(msgType: 7, msgFlags: 0, dataLen: 0), cCapabilitiesSets: 1,
          capabilitySets: sets)
        return c.pointee.ClientCapabilities?(c, &caps) ?? 1
      }
    }
    guard rc == 0 else { return rc }
    ready = true
    if processPendingCancellation(c) { return 0 }
    announcedChangeCount = pasteboard.changeCount
    return sendFormatList(c, available: isActive && hasLocalText)
  }

  private var hasLocalText: Bool { pasteboard.string(forType: .string)?.isEmpty == false }

  @discardableResult
  private func sendFormatList(_ c: UnsafeMutablePointer<CliprdrClientContext>, available: Bool) -> UInt32 {
    files.clearSource()
    announcedText = false
    let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    if !urls.isEmpty, isActive, files.captureLocalFiles(urls) {
      return RdpClipboardFiles.formatName.withCString { name in
        "Preferred DropEffect".withCString { effect in
          var formats = [
            CLIPRDR_FORMAT(formatId: RdpClipboardFiles.formatID, formatName: UnsafeMutablePointer(mutating: name)),
            CLIPRDR_FORMAT(formatId: RdpClipboardFiles.formatID + 1, formatName: UnsafeMutablePointer(mutating: effect))]
          return formats.withUnsafeMutableBufferPointer { buffer in
            var list = CLIPRDR_FORMAT_LIST(common: .init(msgType: 2, msgFlags: 0, dataLen: 0), numFormats: 2, formats: buffer.baseAddress)
            return c.pointee.ClientFormatList?(c, &list) ?? 1
          }
        }
      }
    }
    var format = CLIPRDR_FORMAT(formatId: RdpClipboardText.cfUnicodeText, formatName: nil)
    return withUnsafeMutablePointer(to: &format) { fp in
      let textAvailable = available && urls.isEmpty
      announcedText = textAvailable
      var list = CLIPRDR_FORMAT_LIST(
        common: CLIPRDR_HEADER(msgType: 2, msgFlags: 0, dataLen: 0),
        numFormats: textAvailable ? 1 : 0, formats: textAvailable ? fp : nil)
      return c.pointee.ClientFormatList?(c, &list) ?? 1
    }
  }

  private func serverFormatList(
    _ c: UnsafeMutablePointer<CliprdrClientContext>, _ list: UnsafePointer<CLIPRDR_FORMAT_LIST>
  ) -> UInt32 {
    _ = processPendingCancellation(c)
    var response = CLIPRDR_FORMAT_LIST_RESPONSE(common: CLIPRDR_HEADER(msgType: 3, msgFlags: 1, dataLen: 0))
    let rc = c.pointee.ClientFormatListResponse?(c, &response) ?? 1
    generation &+= 1
    files.cancel(clearPublished: true)
    files.clearSource()
    remoteFormat = nil
    guard rc == 0, isActive, list.pointee.numFormats <= 4096, let formats = list.pointee.formats else { return rc }
    for i in 0..<Int(list.pointee.numFormats) {
      if let name = formats[i].formatName, String(cString: name) == RdpClipboardFiles.formatName, files.remoteSupportsFiles {
        remoteFormat = formats[i].formatId
        remoteIsFiles = true
        break
      }
      if formats[i].formatId == RdpClipboardText.cfUnicodeText {
        remoteFormat = formats[i].formatId
        remoteIsFiles = false
      }
    }
    return requestRemoteFormat(c)
  }

  private func requestRemoteFormat(_ c: UnsafeMutablePointer<CliprdrClientContext>) -> UInt32 {
    guard !formatTimedOut, requestedFormat == nil, let remoteFormat else { return 0 }
    requestedFormat = remoteFormat
    requestedGeneration = generation
    requestedChangeCount = pasteboard.changeCount
    requestIsFiles = remoteIsFiles
    formatDeadline = Date().addingTimeInterval(30)
    if remoteIsFiles { files.onStatus?("Preparing clipboard files from Windows…", true) }
    var request = CLIPRDR_FORMAT_DATA_REQUEST(
      common: CLIPRDR_HEADER(msgType: 4, msgFlags: 0, dataLen: 4), requestedFormatId: remoteFormat)
    return c.pointee.ClientFormatDataRequest?(c, &request) ?? 1
  }

  private func serverDataRequest(_ c: UnsafeMutablePointer<CliprdrClientContext>, _ formatId: UInt32) -> UInt32 {
    _ = processPendingCancellation(c)
    let data: Data?
    let allowed = isActive && pasteboard.changeCount == announcedChangeCount
    if allowed,
      formatId == RdpClipboardFiles.formatID, let source = files.source {
      data = try? RdpClipboardFiles.encode(source.entries)
    } else if allowed, formatId == RdpClipboardFiles.formatID + 1, files.source != nil {
      data = Data([1, 0, 0, 0]) // DROPEFFECT_COPY: never move or delete the source.
    } else {
      data = allowed && announcedText && formatId == RdpClipboardText.cfUnicodeText
        ? pasteboard.string(forType: .string).flatMap { RdpClipboardText.encode($0) } : nil
    }
    var bytes = [UInt8](data ?? Data())
    return bytes.withUnsafeMutableBufferPointer { buf in
      var response = CLIPRDR_FORMAT_DATA_RESPONSE(
        common: CLIPRDR_HEADER(
          msgType: 5, msgFlags: data == nil ? 2 : 1, dataLen: UInt32(buf.count)),
        requestedFormatData: data == nil ? nil : UnsafePointer(buf.baseAddress))
      return c.pointee.ClientFormatDataResponse?(c, &response) ?? 1
    }
  }

  private func serverDataResponse(_ resp: UnsafePointer<CLIPRDR_FORMAT_DATA_RESPONSE>) -> UInt32 {
    if processPendingCancellation(context) { return 0 }
    guard !formatTimedOut, requestedFormat != nil else { return 0 }
    formatDeadline = nil
    requestedFormat = nil
    guard requestedGeneration == generation else {
      if let context { return requestRemoteFormat(context) }
      return 0
    }
    let header = resp.pointee.common
    if requestIsFiles {
      guard header.msgFlags & 1 != 0, header.dataLen > 0,
        header.dataLen <= RdpClipboardFiles.maxDescriptorBytes,
        let ptr = resp.pointee.requestedFormatData,
        pasteboard.changeCount == requestedChangeCount, let context else {
        files.onStatus?("Clipboard files could not be received. Copy again to retry.", false)
        return 0
      }
      files.receiveManifest(Data(bytes: ptr, count: Int(header.dataLen)), context: context)
      return 0
    }
    guard header.msgFlags & 1 != 0, header.dataLen > 0, Int(header.dataLen) <= RdpClipboardText.maxBytes,
      let ptr = resp.pointee.requestedFormatData, isActive,
      pasteboard.changeCount == requestedChangeCount,
      let text = RdpClipboardText.decode(Data(bytes: ptr, count: Int(header.dataLen)))
    else { return 0 }  // dropped: failed, empty, oversized, invalid, or window not active
    let pb = pasteboard
    pb.clearContents()
    pb.setString(text, forType: .string)
    announcedChangeCount = pb.changeCount  // don't echo the remote text back
    return 0
  }
}
