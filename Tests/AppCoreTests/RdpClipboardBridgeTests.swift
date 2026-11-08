import AppKit
import CFreeRDP
import XCTest
@testable import AppCore

private final class ClipboardBridgeHarness {
  let pb = NSPasteboard.withUniqueName()
  let context = UnsafeMutablePointer<CliprdrClientContext>.allocate(capacity: 1)
  let bridge: RdpClipboardBridge
  var formats: [(UInt32, String?)] = []
  var requestedFormats: [UInt32] = []
  var requestedFiles: [CLIPRDR_FILE_CONTENTS_REQUEST] = []
  var response: Data?
  var responseOK = false

  init() {
    bridge = RdpClipboardBridge(pasteboard: pb)
    context.initialize(to: CliprdrClientContext())
    context.pointee.handle = Unmanaged.passUnretained(self).toOpaque()
    context.pointee.ClientCapabilities = { _, _ in 0 }
    context.pointee.ClientFormatListResponse = { _, _ in 0 }
    context.pointee.ClientFormatList = { c, list in
      guard let me = ClipboardBridgeHarness.recorder(c), let list else { return 1 }
      me.formats = (0..<Int(list.pointee.numFormats)).map { i in
        let format = list.pointee.formats![i]
        return (format.formatId, format.formatName.map { String(cString: $0) })
      }
      return 0
    }
    context.pointee.ClientFormatDataRequest = { c, request in
      guard let me = ClipboardBridgeHarness.recorder(c), let request else { return 1 }
      me.requestedFormats.append(request.pointee.requestedFormatId)
      return 0
    }
    context.pointee.ClientFormatDataResponse = { c, response in
      guard let me = ClipboardBridgeHarness.recorder(c), let response else { return 1 }
      me.responseOK = response.pointee.common.msgFlags == 1
      me.response = response.pointee.requestedFormatData.map { Data(bytes: $0, count: Int(response.pointee.common.dataLen)) }
      return 0
    }
    context.pointee.ClientFileContentsRequest = { c, request in
      guard let me = ClipboardBridgeHarness.recorder(c), let request else { return 1 }
      me.requestedFiles.append(request.pointee)
      return 0
    }
    bridge.attach(context)
  }

  deinit {
    bridge.detach()
    context.deinitialize(count: 1)
    context.deallocate()
    pb.releaseGlobally()
  }

  private static func recorder(_ context: UnsafeMutablePointer<CliprdrClientContext>?) -> ClipboardBridgeHarness? {
    context?.pointee.handle.map { Unmanaged<ClipboardBridgeHarness>.fromOpaque($0).takeUnretainedValue() }
  }

  func ready(active: Bool) {
    bridge.setActive(active)
    var general = CLIPRDR_GENERAL_CAPABILITY_SET(capabilitySetType: 1, capabilitySetLength: 12, version: 2, generalFlags: 0xE)
    withUnsafeMutablePointer(to: &general) { ptr in
      ptr.withMemoryRebound(to: CLIPRDR_CAPABILITY_SET.self, capacity: 1) { sets in
        var caps = CLIPRDR_CAPABILITIES(common: .init(), cCapabilitiesSets: 1, capabilitySets: sets)
        _ = context.pointee.ServerCapabilities?(context, &caps)
      }
    }
    var ready = CLIPRDR_MONITOR_READY(common: .init())
    _ = context.pointee.MonitorReady?(context, &ready)
    bridge.pollLocalChange()
  }

  func remoteList(files: Bool) {
    RdpClipboardFiles.formatName.withCString { name in
      var format = CLIPRDR_FORMAT(formatId: files ? 0xD001 : 13,
        formatName: files ? UnsafeMutablePointer(mutating: name) : nil)
      withUnsafeMutablePointer(to: &format) { ptr in
        var list = CLIPRDR_FORMAT_LIST(common: .init(), numFormats: 1, formats: ptr)
        _ = context.pointee.ServerFormatList?(context, &list)
      }
    }
  }

  func remoteData(_ data: Data) {
    data.withUnsafeBytes { raw in
      var response = CLIPRDR_FORMAT_DATA_RESPONSE(
        common: .init(msgType: 5, msgFlags: 1, dataLen: UInt32(data.count)),
        requestedFormatData: raw.bindMemory(to: UInt8.self).baseAddress)
      _ = context.pointee.ServerFormatDataResponse?(context, &response)
    }
  }
}

final class RdpClipboardBridgeTests: XCTestCase {
  func testFinderSelectionAdvertisesFilesAndCopyOnlyDropEffectWhenFocused() throws {
    let h = ClipboardBridgeHarness()
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("abc".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    h.pb.writeObjects([file as NSURL])
    h.ready(active: false)
    XCTAssertTrue(h.formats.isEmpty)
    h.bridge.setActive(true)
    h.bridge.pollLocalChange()
    XCTAssertEqual(h.formats.map { $0.1 }, ["FileGroupDescriptorW", "Preferred DropEffect"])
    var request = CLIPRDR_FORMAT_DATA_REQUEST(common: .init(), requestedFormatId: RdpClipboardFiles.formatID)
    _ = h.context.pointee.ServerFormatDataRequest?(h.context, &request)
    XCTAssertTrue(h.responseOK)
    XCTAssertEqual(try RdpClipboardFiles.decode(XCTUnwrap(h.response)).first?.size, 3)
    request.requestedFormatId += 1
    _ = h.context.pointee.ServerFormatDataRequest?(h.context, &request)
    XCTAssertEqual(h.response, Data([1, 0, 0, 0]))
    h.bridge.setActive(false)
    request.requestedFormatId -= 1
    _ = h.context.pointee.ServerFormatDataRequest?(h.context, &request)
    XCTAssertFalse(h.responseOK)
  }

  func testRemoteCopyCanFinishAfterSwitchingToFinder() throws {
    let h = ClipboardBridgeHarness()
    h.ready(active: true)
    h.remoteList(files: true)
    XCTAssertEqual(h.requestedFormats, [0xD001])
    h.bridge.setActive(false)
    h.remoteData(try RdpClipboardFiles.encode([.init(name: "empty.txt", size: 0, isDirectory: false)]))
    let urls = try XCTUnwrap(h.pb.readObjects(forClasses: [NSURL.self]) as? [URL])
    XCTAssertEqual(urls.first?.lastPathComponent, "empty.txt")
    XCTAssertEqual(try Data(contentsOf: urls[0]), Data())
  }

  func testClipboardChangeWhileWaitingForManifestIsNotOverwritten() throws {
    let h = ClipboardBridgeHarness()
    h.ready(active: true)
    h.remoteList(files: true)
    h.bridge.setActive(false)
    h.pb.clearContents()
    h.pb.setString("keep", forType: .string)
    h.remoteData(try RdpClipboardFiles.encode([.init(name: "x", size: 1, isDirectory: false)]))
    XCTAssertEqual(h.pb.string(forType: .string), "keep")
    XCTAssertTrue(h.requestedFiles.isEmpty)
  }

  func testSupersededUntaggedFormatResponseCannotBeInterpretedAsFileManifest() throws {
    let h = ClipboardBridgeHarness()
    h.ready(active: true)
    h.remoteList(files: false)
    h.remoteList(files: true)
    XCTAssertEqual(h.requestedFormats, [13])
    h.remoteData(try XCTUnwrap(RdpClipboardText.encode("stale")))
    XCTAssertNil(h.pb.string(forType: .string))
    XCTAssertEqual(h.requestedFormats, [13, 0xD001])
    h.remoteData(try RdpClipboardFiles.encode([.init(name: "empty", size: 0, isDirectory: false)]))
    XCTAssertNotNil(h.pb.readObjects(forClasses: [NSURL.self]))
  }

  func testUnannouncedOrInactiveClipboardCannotBeReadByServer() {
    let h = ClipboardBridgeHarness()
    h.ready(active: true)
    h.pb.clearContents()
    h.pb.setString("private local clipboard", forType: .string)
    var request = CLIPRDR_FORMAT_DATA_REQUEST(common: .init(), requestedFormatId: 13)
    _ = h.context.pointee.ServerFormatDataRequest?(h.context, &request)
    XCTAssertFalse(h.responseOK)
    h.bridge.pollLocalChange()
    _ = h.context.pointee.ServerFormatDataRequest?(h.context, &request)
    XCTAssertTrue(h.responseOK)
    h.bridge.setActive(false)
    _ = h.context.pointee.ServerFormatDataRequest?(h.context, &request)
    XCTAssertFalse(h.responseOK)
  }

  func testTextClipboardStillWorksWithoutEcho() throws {
    let h = ClipboardBridgeHarness()
    h.ready(active: true)
    h.remoteList(files: false)
    h.remoteData(try XCTUnwrap(RdpClipboardText.encode("Xin chào")))
    XCTAssertEqual(h.pb.string(forType: .string), "Xin chào")
    h.bridge.pollLocalChange()
    XCTAssertTrue(h.formats.isEmpty)
  }

  func testClipboardChangeWhileWaitingForTextIsNotOverwritten() throws {
    let h = ClipboardBridgeHarness()
    h.ready(active: true)
    h.remoteList(files: false)
    XCTAssertEqual(h.requestedFormats, [RdpClipboardText.cfUnicodeText])

    h.pb.clearContents()
    h.pb.setString("keep local copy", forType: .string)
    h.remoteData(try XCTUnwrap(RdpClipboardText.encode("stale remote text")))

    XCTAssertEqual(h.pb.string(forType: .string), "keep local copy")
  }
}
