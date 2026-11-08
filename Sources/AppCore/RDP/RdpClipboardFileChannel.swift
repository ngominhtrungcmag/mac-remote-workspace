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
  private struct Request {
    let index: Int
    let offset: UInt64
    let length: Int
  }
  private var inFlight: [UInt32: Request] = [:]
  private var buffered: [UInt32: (Request, Data)] = [:]
  private var nextIndex = 0
  private var nextOffset: UInt64 = 0
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
      nextIndex = receiver?.index ?? 0
      nextOffset = receiver?.offset ?? 0
      fillWindow(context)
    } catch { fail(error) }
  }

  func receiveContents(_ response: CLIPRDR_FILE_CONTENTS_RESPONSE, context: UnsafeMutablePointer<CliprdrClientContext>) {
    guard let request = inFlight.removeValue(forKey: response.streamId), let receiver else { return }
    do {
      guard pasteboard.changeCount == clipboardCount,
        response.common.msgFlags & 1 != 0, response.cbRequested > 0,
        response.cbRequested <= request.length, response.common.dataLen == response.cbRequested + 4,
        let bytes = response.requestedData else { throw RdpClipboardFileError.changed }
      deadline = Date().addingTimeInterval(30)
      buffered[response.streamId] = (request, Data(bytes: bytes, count: Int(response.cbRequested)))
      while let entry = buffered.first(where: { $0.value.0.index == receiver.index && $0.value.0.offset == receiver.offset }) {
        buffered.removeValue(forKey: entry.key)
        try receiver.append(entry.value.1)
        if entry.value.1.count < entry.value.0.length {
          inFlight.removeAll()
          buffered.removeAll()
          nextIndex = receiver.index
          nextOffset = receiver.offset
          break
        }
      }
      fillWindow(context)
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
    inFlight.removeAll()
    buffered.removeAll()
    nextIndex = 0
    nextOffset = 0
    deadline = nil
  }

  private func fillWindow(_ c: UnsafeMutablePointer<CliprdrClientContext>) {
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
    if Date().timeIntervalSince(lastProgress) > 0.5 {
      lastProgress = Date()
      onStatus?("Receiving clipboard file \(receiver.index + 1) of \(receiver.entries.count)…", true)
    }
    while inFlight.count + buffered.count < RdpClipboardFiles.maxInFlightRequests, nextIndex < receiver.entries.count {
      let entry = receiver.entries[nextIndex]
      if entry.isDirectory || nextOffset == entry.size {
        nextIndex += 1
        nextOffset = 0
        continue
      }
      let length = Int(min(UInt64(RdpClipboardFiles.chunkBytes), entry.size - nextOffset))
      streamID &+= 1
      inFlight[streamID] = Request(index: nextIndex, offset: nextOffset, length: length)
      var request = CLIPRDR_FILE_CONTENTS_REQUEST(
        common: .init(msgType: 8, msgFlags: 0, dataLen: 24), streamId: streamID,
        listIndex: UInt32(nextIndex), dwFlags: 2,
        nPositionLow: UInt32(truncatingIfNeeded: nextOffset), nPositionHigh: UInt32(nextOffset >> 32),
        cbRequested: UInt32(length), haveClipDataId: false, clipDataId: 0)
      nextOffset += UInt64(length)
      deadline = Date().addingTimeInterval(30)
      if c.pointee.ClientFileContentsRequest?(c, &request) != 0 {
        fail(RdpClipboardFileError.io)
        return
      }
    }
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
