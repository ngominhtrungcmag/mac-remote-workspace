import AppKit
import CFreeRDP
import XCTest
@testable import AppCore

private final class FileChannelHarness {
  var requests: [CLIPRDR_FILE_CONTENTS_REQUEST] = []
  var response: Data?
  var responseOK = false
  let context = UnsafeMutablePointer<CliprdrClientContext>.allocate(capacity: 1)
  init() {
    context.initialize(to: CliprdrClientContext())
    context.pointee.custom = Unmanaged.passUnretained(self).toOpaque()
    context.pointee.ClientFileContentsRequest = { c, request in
      guard let c, let request, let ptr = c.pointee.custom else { return 1 }
      Unmanaged<FileChannelHarness>.fromOpaque(ptr).takeUnretainedValue().requests.append(request.pointee)
      return 0
    }
    context.pointee.ClientFileContentsResponse = { c, response in
      guard let c, let response, let ptr = c.pointee.custom else { return 1 }
      let me = Unmanaged<FileChannelHarness>.fromOpaque(ptr).takeUnretainedValue()
      me.responseOK = response.pointee.common.msgFlags == 1
      me.response = response.pointee.requestedData.map { Data(bytes: $0, count: Int(response.pointee.cbRequested)) }
      return 0
    }
  }
  deinit { context.deinitialize(count: 1); context.deallocate() }

  func deliver(_ data: Data, stream: UInt32, to channel: RdpClipboardFileChannel, ok: Bool = true) {
    data.withUnsafeBytes { raw in
      let response = CLIPRDR_FILE_CONTENTS_RESPONSE(
        common: .init(msgType: 9, msgFlags: ok ? 1 : 2, dataLen: UInt32(data.count + 4)),
        streamId: stream, cbRequested: UInt32(data.count), requestedData: raw.bindMemory(to: UInt8.self).baseAddress)
      channel.receiveContents(response, context: context)
    }
  }
}

final class RdpClipboardFileChannelTests: XCTestCase {
  func testRemoteFilesStreamInChunksAndPublishOnlyAfterCompletion() throws {
    let pb = NSPasteboard.withUniqueName()
    defer { pb.releaseGlobally() }
    let channel = RdpClipboardFileChannel(pasteboard: pb)
    let harness = FileChannelHarness()
    let count = RdpClipboardFiles.chunkBytes + 3
    channel.receiveManifest(try RdpClipboardFiles.encode([.init(name: "test.bin", size: UInt64(count), isDirectory: false)]), context: harness.context)
    defer { channel.cancel(clearPublished: true) }
    XCTAssertEqual(harness.requests.count, 2)
    let first = try XCTUnwrap(harness.requests.first)
    XCTAssertEqual(first.cbRequested, UInt32(RdpClipboardFiles.chunkBytes))
    XCTAssertNil(channel.publishedChangeCount)
    harness.deliver(Data(repeating: 7, count: RdpClipboardFiles.chunkBytes), stream: first.streamId, to: channel)
    let last = try XCTUnwrap(harness.requests.last)
    XCTAssertEqual(last.nPositionLow, UInt32(RdpClipboardFiles.chunkBytes))
    XCTAssertEqual(last.cbRequested, 3)
    harness.deliver(Data([1, 2, 3]), stream: last.streamId, to: channel)
    let urls = try XCTUnwrap(pb.readObjects(forClasses: [NSURL.self]) as? [URL])
    XCTAssertEqual(try Data(contentsOf: urls[0]).count, count)
    XCTAssertEqual(channel.publishedChangeCount, pb.changeCount)
  }

  func testWindowRefillsAndReverseResponsesStayOrdered() throws {
    let pb = NSPasteboard.withUniqueName()
    defer { pb.releaseGlobally() }
    let channel = RdpClipboardFileChannel(pasteboard: pb)
    defer { channel.cancel(clearPublished: true) }
    let harness = FileChannelHarness()
    let chunk = RdpClipboardFiles.chunkBytes
    channel.receiveManifest(try RdpClipboardFiles.encode([.init(name: "x", size: UInt64(20 * chunk), isDirectory: false)]), context: harness.context)
    XCTAssertEqual(harness.requests.count, 16)
    let first = harness.requests[0]
    harness.deliver(Data(repeating: 0, count: chunk), stream: first.streamId, to: channel)
    XCTAssertEqual(harness.requests.count, 17)
    // Buffer later replies in reverse; the window cannot grow while the next chunk is missing.
    for request in harness.requests[1...16].reversed() {
      harness.deliver(Data(repeating: UInt8(request.nPositionLow / UInt32(chunk)), count: chunk), stream: request.streamId, to: channel)
    }
    XCTAssertNil(channel.publishedChangeCount)
    for request in harness.requests[17...].reversed() {
      harness.deliver(Data(repeating: UInt8(request.nPositionLow / UInt32(chunk)), count: chunk), stream: request.streamId, to: channel)
    }
    let urls = try XCTUnwrap(pb.readObjects(forClasses: [NSURL.self]) as? [URL])
    let expected = Data((0..<20).flatMap { Array(repeating: UInt8($0), count: chunk) })
    XCTAssertEqual(try Data(contentsOf: urls[0]), expected)
    XCTAssertEqual(channel.publishedChangeCount, pb.changeCount)
  }

  func testShortResponseRestartsAndStaleResponsesAreIgnored() throws {
    let pb = NSPasteboard.withUniqueName()
    defer { pb.releaseGlobally() }
    let channel = RdpClipboardFileChannel(pasteboard: pb)
    defer { channel.cancel(clearPublished: true) }
    let harness = FileChannelHarness()
    let chunk = RdpClipboardFiles.chunkBytes
    channel.receiveManifest(try RdpClipboardFiles.encode([.init(name: "x", size: UInt64(chunk + 3), isDirectory: false)]), context: harness.context)
    let old = harness.requests
    harness.deliver(Data([1, 2]), stream: old[0].streamId, to: channel)
    XCTAssertEqual(harness.requests[2].nPositionLow, 2)
    harness.deliver(Data([9, 9, 9]), stream: old[1].streamId, to: channel)
    harness.deliver(Data([9]), stream: UInt32.max, to: channel)
    XCTAssertNil(channel.publishedChangeCount)
    let fresh = Array(harness.requests.dropFirst(2))
    harness.deliver(Data(repeating: 3, count: chunk), stream: fresh[0].streamId, to: channel)
    harness.deliver(Data([4]), stream: fresh[1].streamId, to: channel)
    let urls = try XCTUnwrap(pb.readObjects(forClasses: [NSURL.self]) as? [URL])
    XCTAssertEqual(try Data(contentsOf: urls[0]), Data([1, 2]) + Data(repeating: 3, count: chunk) + Data([4]))
    channel.cancel(clearPublished: true)
    harness.deliver(Data([4]), stream: fresh[1].streamId, to: channel)
    XCTAssertNil(channel.publishedChangeCount)
  }

  func testRequestsSpanFilesAndSkipDirectoriesAndEmptyFiles() throws {
    let pb = NSPasteboard.withUniqueName()
    defer { pb.releaseGlobally() }
    let channel = RdpClipboardFileChannel(pasteboard: pb)
    defer { channel.cancel(clearPublished: true) }
    let harness = FileChannelHarness()
    let entries: [RdpClipboardFile] = [
      .init(name: "dir", size: 0, isDirectory: true),
      .init(name: "dir/a", size: 2, isDirectory: false),
      .init(name: "empty", size: 0, isDirectory: false),
      .init(name: "b", size: 1, isDirectory: false)]
    channel.receiveManifest(try RdpClipboardFiles.encode(entries), context: harness.context)
    XCTAssertEqual(harness.requests.map(\.listIndex), [1, 3])
    harness.deliver(Data([3]), stream: harness.requests[1].streamId, to: channel)
    XCTAssertNil(channel.publishedChangeCount)
    harness.deliver(Data([1, 2]), stream: harness.requests[0].streamId, to: channel)
    let urls = try XCTUnwrap(pb.readObjects(forClasses: [NSURL.self]) as? [URL])
    let dir = try XCTUnwrap(urls.first { $0.lastPathComponent == "dir" })
    let b = try XCTUnwrap(urls.first { $0.lastPathComponent == "b" })
    XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("a")), Data([1, 2]))
    XCTAssertEqual(try Data(contentsOf: b), Data([3]))
  }

  func testStaleStreamCannotPopulateNewClipboardAndReplacementCancels() throws {
    let pb = NSPasteboard.withUniqueName()
    defer { pb.releaseGlobally() }
    let channel = RdpClipboardFileChannel(pasteboard: pb)
    let harness = FileChannelHarness()
    let manifest = try RdpClipboardFiles.encode([.init(name: "x", size: 1, isDirectory: false)])
    channel.receiveManifest(manifest, context: harness.context)
    let old = harness.requests[0].streamId
    channel.receiveManifest(manifest, context: harness.context)
    harness.deliver(Data([1]), stream: old, to: channel)
    XCTAssertNil(channel.publishedChangeCount)
    pb.clearContents()
    pb.setString("new clipboard", forType: .string)
    harness.deliver(Data([1]), stream: harness.requests.last!.streamId, to: channel)
    XCTAssertNil(channel.publishedChangeCount)
    XCTAssertEqual(pb.string(forType: .string), "new clipboard")
  }

  func testOversizedFailedAndTimedOutResponsesNeverPublish() throws {
    let pb = NSPasteboard.withUniqueName()
    defer { pb.releaseGlobally() }
    let channel = RdpClipboardFileChannel(pasteboard: pb)
    let harness = FileChannelHarness()
    let manifest = try RdpClipboardFiles.encode([.init(name: "x", size: 1, isDirectory: false)])
    channel.receiveManifest(manifest, context: harness.context)
    harness.deliver(Data([1, 2]), stream: harness.requests.last!.streamId, to: channel)
    XCTAssertNil(channel.publishedChangeCount)
    channel.receiveManifest(manifest, context: harness.context)
    harness.deliver(Data(), stream: harness.requests.last!.streamId, to: channel, ok: false)
    XCTAssertNil(channel.publishedChangeCount)
    channel.receiveManifest(manifest, context: harness.context)
    let request = harness.requests.last!
    channel.poll(now: Date().addingTimeInterval(31))
    harness.deliver(Data([1]), stream: request.streamId, to: channel)
    XCTAssertNil(channel.publishedChangeCount)
  }

  func testLocalSelectionServesSizeAndRangesButRejectsUnknownAndInactiveReads() throws {
    let pb = NSPasteboard.withUniqueName()
    defer { pb.releaseGlobally() }
    let channel = RdpClipboardFileChannel(pasteboard: pb)
    channel.remoteSupportsFiles = true
    let harness = FileChannelHarness()
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("hello".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    XCTAssertTrue(channel.captureLocalFiles([file]))
    var req = CLIPRDR_FILE_CONTENTS_REQUEST(common: .init(), streamId: 1, listIndex: 0, dwFlags: 1,
      nPositionLow: 0, nPositionHigh: 0, cbRequested: 8, haveClipDataId: false, clipDataId: 0)
    _ = channel.serve(harness.context, req, allowed: true)
    XCTAssertEqual(harness.response, Data([5, 0, 0, 0, 0, 0, 0, 0]))
    req.dwFlags = 2
    req.cbRequested = 64 << 10
    _ = channel.serve(harness.context, req, allowed: true)
    XCTAssertEqual(harness.response, Data("hello".utf8))
    _ = channel.serve(harness.context, req, allowed: false)
    XCTAssertFalse(harness.responseOK)
    req.listIndex = UInt32.max
    _ = channel.serve(harness.context, req, allowed: true)
    XCTAssertFalse(harness.responseOK)
  }
}
