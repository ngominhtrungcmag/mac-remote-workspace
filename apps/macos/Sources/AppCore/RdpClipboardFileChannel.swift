import AppKit
import CFreeRDP
import Foundation

/// File streaming state, confined to the RDP thread. No drive redirection or remote paths are opened.
final class RdpClipboardFileChannel {
  private let pasteboard: NSPasteboard

  init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }
  var onStatus: (@Sendable (String, Bool) -> Void)?
  var directory: URL?
  var remoteSupportsFiles = false
  private(set) var source: RdpClipboardFileSource?
  private(set) var publishedChangeCount: Int?
  private var receiver: RdpClipboardFileReceiver?
  private var streamID: UInt32 = 0
  private var pendingStream: UInt32?
  private var requestedBytes = 0
  private var deadline: Date?
  private var clipboardCount = 0
  private var lastProgress = Date.distantPast

  func captureLocalFiles(_ urls: [URL]) -> Bool {
    source = nil
    do {
      guard remoteSupportsFiles else {
        onStatus?("The server does not support clipboard file streaming.", false)
        return false
      }
      source = try RdpClipboardFileSource(urls: urls)
      onStatus?("Files copied. Paste in Windows to transfer (copy only).", false)
      return true
    } catch {
      report(error)
      return false
    }
  }

  func clearSource() { source = nil }

  func receiveCapabilities(_ caps: UnsafePointer<CLIPRDR_CAPABILITIES>) {
    remoteSupportsFiles = false
    // FreeRDP 3.10 emits one validated general set per callback, not the raw wire array.
    guard caps.pointee.cCapabilitiesSets == 1, let first = caps.pointee.capabilitySets,
      first.pointee.capabilitySetType == 1, first.pointee.capabilitySetLength == 12 else { return }
    remoteSupportsFiles = UnsafeRawPointer(first).load(as: CLIPRDR_GENERAL_CAPABILITY_SET.self).generalFlags & 4 != 0
  }

  func serve(_ c: UnsafeMutablePointer<CliprdrClientContext>, _ req: CLIPRDR_FILE_CONTENTS_REQUEST, allowed: Bool) -> UInt32 {
    var data: Data?
    do {
      guard allowed, !req.haveClipDataId.boolValue, let source,
        source.entries.indices.contains(Int(req.listIndex)),
        !source.entries[Int(req.listIndex)].isDirectory else { throw RdpClipboardFileError.changed }
      if req.dwFlags == 1, req.cbRequested == 8 {
        let size = source.entries[Int(req.listIndex)].size
        data = Data((0..<8).map { UInt8(truncatingIfNeeded: size >> ($0 * 8)) })
      } else if req.dwFlags == 2 {
        let offset = (UInt64(req.nPositionHigh) << 32) | UInt64(req.nPositionLow)
        let size = source.entries[Int(req.listIndex)].size
        guard offset <= size, req.cbRequested > 0 else { throw RdpClipboardFileError.invalid }
        let count = Int(min(UInt64(req.cbRequested), UInt64(RdpClipboardFiles.chunkBytes), size - offset))
        data = count == 0 ? Data() : try source.read(index: Int(req.listIndex), offset: offset, count: count)
        if Date().timeIntervalSince(lastProgress) > 0.5 {
          lastProgress = Date()
          onStatus?("Sending clipboard files to Windows…", true)
        }
        deadline = Date().addingTimeInterval(30)
        if offset + UInt64(count) == size,
          !source.entries.dropFirst(Int(req.listIndex) + 1).contains(where: { !$0.isDirectory }) {
          deadline = nil
          onStatus?("Clipboard files sent to Windows.", false)
        }
      } else { throw RdpClipboardFileError.invalid }
    } catch { report(error) }
    return (data ?? Data()).withUnsafeBytes { bytes in
      var response = CLIPRDR_FILE_CONTENTS_RESPONSE(
        common: .init(msgType: 9, msgFlags: data == nil ? 2 : 1, dataLen: UInt32(bytes.count + 4)),
        streamId: req.streamId, cbRequested: UInt32(bytes.count),
        requestedData: bytes.bindMemory(to: UInt8.self).baseAddress)
      return c.pointee.ClientFileContentsResponse?(c, &response) ?? 1
    }
  }

  func receiveManifest(_ data: Data, context: UnsafeMutablePointer<CliprdrClientContext>) {
    do {
      cancel(clearPublished: true)
      receiver = try RdpClipboardFileReceiver(entries: RdpClipboardFiles.decode(data), directory: directory)
      clipboardCount = pasteboard.changeCount
      onStatus?("Receiving clipboard files from Windows…", true)
      requestNext(context)
    } catch { fail(error) }
  }

  func receiveContents(_ response: CLIPRDR_FILE_CONTENTS_RESPONSE, context: UnsafeMutablePointer<CliprdrClientContext>) {
    guard pendingStream == response.streamId, let receiver else { return }
    pendingStream = nil
    do {
      guard pasteboard.changeCount == clipboardCount,
        response.common.msgFlags & 1 != 0, response.cbRequested > 0,
        response.cbRequested <= requestedBytes, response.common.dataLen == response.cbRequested + 4,
        let bytes = response.requestedData else { throw RdpClipboardFileError.changed }
      try receiver.append(Data(bytes: bytes, count: Int(response.cbRequested)))
      requestNext(context)
    } catch { fail(error) }
  }

  func poll(now: Date = Date()) {
    if receiver != nil, pasteboard.changeCount != (publishedChangeCount ?? clipboardCount) {
      cancel(clearPublished: false)
    }
    if let deadline, now > deadline { fail(RdpClipboardFileError.io) }
  }

  func cancel(clearPublished: Bool) {
    if clearPublished, let count = publishedChangeCount, pasteboard.changeCount == count {
      pasteboard.clearContents()
    }
    receiver = nil
    publishedChangeCount = nil
    pendingStream = nil
    deadline = nil
  }

  private func requestNext(_ c: UnsafeMutablePointer<CliprdrClientContext>) {
    guard let receiver else { return }
    if let urls = receiver.completedURLs {
      guard pasteboard.changeCount == clipboardCount else { fail(RdpClipboardFileError.changed); return }
      let pb = pasteboard
      pb.clearContents()
      guard pb.writeObjects(urls as [NSURL]) else { fail(RdpClipboardFileError.io); return }
      publishedChangeCount = pb.changeCount
      deadline = nil
      onStatus?("Files ready. Paste in Finder before disconnecting.", false)
      return
    }
    streamID &+= 1
    pendingStream = streamID
    requestedBytes = Int(min(UInt64(RdpClipboardFiles.chunkBytes), receiver.entries[receiver.index].size - receiver.offset))
    deadline = Date().addingTimeInterval(30)
    if Date().timeIntervalSince(lastProgress) > 0.5 {
      lastProgress = Date()
      onStatus?("Receiving clipboard file \(receiver.index + 1) of \(receiver.entries.count)…", true)
    }
    var request = CLIPRDR_FILE_CONTENTS_REQUEST(
      common: .init(msgType: 8, msgFlags: 0, dataLen: 24), streamId: streamID,
      listIndex: UInt32(receiver.index), dwFlags: 2,
      nPositionLow: UInt32(truncatingIfNeeded: receiver.offset), nPositionHigh: UInt32(receiver.offset >> 32),
      cbRequested: UInt32(requestedBytes), haveClipDataId: false, clipDataId: 0)
    if c.pointee.ClientFileContentsRequest?(c, &request) != 0 { fail(RdpClipboardFileError.io) }
  }

  private func report(_ error: Error) {
    onStatus?((error as? RdpClipboardFileError)?.localizedDescription ?? RdpClipboardFileError.io.localizedDescription, false)
  }

  private func fail(_ error: Error) {
    cancel(clearPublished: true)
    source = nil
    report(error)
  }
}
