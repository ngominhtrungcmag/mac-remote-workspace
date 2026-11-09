import Darwin
import Foundation
import Metal
import XCTest

@testable import AppCore

final class RdpHelperProcessTests: XCTestCase {
  func testClipboardStatusDeliveryAndStagingCleanupAfterHelperCrash() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rdp-clipboard-helper-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: dir) }
    var wire = try RdpHelperMessage.connected.encoded()
    wire.append(try RdpHelperMessage.clipboardStatus(message: "Receiving clipboard files…", busy: true).encoded())
    try wire.write(to: dir.appendingPathComponent("messages"))
    let script = dir.appendingPathComponent("helper")
    try "#!/bin/sh\n/bin/cat '\(dir.appendingPathComponent("messages").path)'\nexec /bin/sleep 60\n"
      .write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let status = expectation(description: "file progress crosses helper IPC")
    let helper = RdpHelperProcess(helperURL: script, host: "fixture", port: 3389,
      resolution: .init(width: 800, height: 600, scaleFactor: 100), callbacks: .init(
        onCertificate: { _, _ in }, onConnected: {}, onFrame: { _ in },
        onEnded: { _, _, _ in }, onCrash: { _ in }, onClipboardStatus: { message, busy in
          XCTAssertEqual(message, "Receiving clipboard files…")
          XCTAssertTrue(busy)
          status.fulfill()
        }))
    try helper.start()
    await fulfillment(of: [status], timeout: 3)
    let root = helper.clipboardDirectory
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    try Data([1, 2, 3]).write(to: root.appendingPathComponent("partial"))
    kill(try XCTUnwrap(helper.processIdentifier), SIGKILL)
    XCTAssertTrue(helper.waitUntilFinished(timeout: 3))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }

  func testSessionSendsCapturedOptionsToHelperAndFixedModeBlocksResize() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rdp-options-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    try RdpHelperMessage.connected.encoded().write(to: directory.appendingPathComponent("connected"))
    let script = directory.appendingPathComponent("helper")
    try "#!/bin/sh\n/bin/cat '\(directory.path)/connected'\nexec /bin/cat > '\(directory.path)/captured'\n"
      .write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let marker = RdpHelperMessage.key(scancode: 0x1E, isExtended: false, isKeyUp: true)
    for mode in [RdpConnectionOptions.DisplayMode.fullHD, .window] {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent("captured"))
      let options = RdpConnectionOptions(displayMode: mode, retina: false, networkProfile: .lan)
      let session = NativeRdpSession(configuration: .init(host: "fixture.invalid", username: "fixture", credentialRefID: nil,
        initialResolution: .init(width: 800, height: 600), options: options),
        certificateVerifier: UnusedCertificateVerifier(), credentialResolver: UnusedCredentialResolver(), helperURL: script)
      try await session.connect()
      session.updateResolution(.init(width: 1000, height: 700))
      session.sendKeyEvent(.init(scancode: 0x1E, isExtended: false, isKeyUp: true))
      var messages: [RdpHelperMessage] = []
      for _ in 0..<60 {
        messages = (try? capturedMessages(at: directory.appendingPathComponent("captured"))) ?? []
        if messages.contains(marker) { break }
        try await Task.sleep(for: .milliseconds(50))
      }
      XCTAssertTrue(messages.contains(marker), "Helper consumed the stream through the resize barrier")
      let start = messages.first { if case .start = $0 { return true }; return false }
      guard case .start(_, _, let width, let height, _, _, _, let receivedOptions)? = start else {
        await session.disconnect()
        return XCTFail("Missing helper start")
      }
      XCTAssertEqual(receivedOptions, options, "Options must cross both session and helper-process boundaries")
      XCTAssertEqual(width, mode == .window ? 800 : 1920)
      XCTAssertEqual(height, mode == .window ? 600 : 1080)
      let resizes = messages.filter { if case .resize = $0 { return true }; return false }
      XCTAssertEqual(resizes, mode == .window ? [.resize(width: 1000, height: 700, scaleFactor: 100)] : [])
      if let pid = session.helperProcessIdentifier { kill(pid, SIGKILL) }
      await session.disconnect()
    }
  }

  private func capturedMessages(at url: URL) throws -> [RdpHelperMessage] {
    let data = try Data(contentsOf: url)
    var offset = 0
    var messages: [RdpHelperMessage] = []
    while offset + 4 <= data.count {
      let count = data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
      guard count <= data.count - offset - 4 else { break }
      messages.append(try RdpHelperMessage.decode(body: Data(data[offset + 4..<offset + 4 + count])))
      offset += 4 + count
    }
    return messages
  }

  func testLegacyStartWithoutOptionsAndOptionsSocketRoundTrip() throws {
    let legacy = Data(#"{"start":{"host":"fixture.invalid","port":3389,"width":800,"height":600,"scaleFactor":100}}"#.utf8)
    XCTAssertEqual(try JSONDecoder().decode(RdpHelperMessage.self, from: legacy),
      .start(host: "fixture.invalid", port: 3389, width: 800, height: 600, scaleFactor: 100))
    var fds: [Int32] = [0, 0]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
    let sender = RdpHelperChannel(fd: fds[0]), receiver = RdpHelperChannel(fd: fds[1])
    defer { sender.close(); receiver.close() }
    let message = RdpHelperMessage.start(host: "fixture.invalid", port: 3389, width: 800, height: 600, scaleFactor: 100,
      options: .init(displayMode: .uhd4K, retina: false, networkProfile: .reducedBandwidth))
    sender.send(message)
    XCTAssertEqual(try receiver.receive(), message)
    let invalid = Data(#"{"start":{"host":"fixture.invalid","port":3389,"width":800,"height":600,"scaleFactor":100,"options":{"displayMode":"invalid","retina":true,"networkProfile":"automatic"}}}"#.utf8)
    XCTAssertThrowsError(try JSONDecoder().decode(RdpHelperMessage.self, from: invalid))
  }

  func testMessageRoundTrip() throws {
    let messages: [RdpHelperMessage] = [
      .start(host: "h", port: 3389, width: 1920, height: 1080, scaleFactor: 200),
      .trustDecision(accepted: true, username: "u", domain: nil, password: "p"),
      .key(scancode: 0x1E, isExtended: true, isKeyUp: false),
      .pointer(x: 1, y: 2, buttonFlags: 4),
      .resize(width: 800, height: 600, scaleFactor: 100),
      .clipboardActive(true),
      .cancelClipboardFiles,
      .clipboardStatus(message: "Receiving clipboard files…", busy: true),
      .start(host: "h", port: 3389, width: 800, height: 600, scaleFactor: 100, clipboardDirectory: "/tmp/test-clipboard"),
      .abort,
      .certificate(host: "h", port: 3389, sha256: "AB", subjectCN: "s", issuerCN: "i", changed: false),
      .connected,
      .frame(width: 2, height: 2, bytesPerRow: 8, data: Data(repeating: 7, count: 16)),
      .ended(code: 5, message: "m", connected: true),
    ]
    for message in messages {
      let wire = try message.encoded()
      let length = wire.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
      XCTAssertEqual(length, wire.count - 4)
      XCTAssertEqual(try RdpHelperMessage.decode(body: wire.dropFirst(4)), message)
    }
    XCTAssertThrowsError(try RdpHelperMessage.decode(body: Data([9])))
    XCTAssertThrowsError(try RdpHelperMessage.decode(body: Data([1, 0, 0, 0, 1])))
    XCTAssertThrowsError(try RdpHelperMessage.decode(body: Data([
      1, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    ])))
  }

  func testChannelOverSocketPairAndEOF() throws {
    var fds: [Int32] = [0, 0]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
    let a = RdpHelperChannel(fd: fds[0]), b = RdpHelperChannel(fd: fds[1])
    let frame = RdpHelperMessage.frame(width: 64, height: 64, bytesPerRow: 256, data: Data(repeating: 1, count: 256 * 64))
    let writer = Thread { a.send(frame); a.send(.abort); a.close() }
    writer.start()
    XCTAssertEqual(try b.receive(), frame)
    XCTAssertEqual(try b.receive(), .abort)
    XCTAssertNil(try b.receive())  // peer closed -> EOF
  }

  func testSendAfterCloseDoesNotWriteToReusedDescriptor() throws {
    var fds: [Int32] = [0, 0]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
    let channel = RdpHelperChannel(fd: fds[0])
    channel.close()
    defer { Darwin.close(fds[1]) }
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: path) }
    let file = open(path.path, O_CREAT | O_RDWR, 0o600)
    defer { Darwin.close(file) }
    // Another thread (e.g. the async logger) may grab the freed number first.
    guard file == fds[0] else { throw XCTSkip("descriptor number reused by another thread") }
    XCTAssertFalse(channel.send(.abort))
    XCTAssertEqual(lseek(file, 0, SEEK_END), 0)
  }

  /// Fake helper: announces `connected`, then idles. Killing it must surface `.helperCrashed`.
  func testKillingHelperYieldsHelperCrashed() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rdp-helper-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try RdpHelperMessage.connected.encoded().write(to: dir.appendingPathComponent("msg"))
    let script = dir.appendingPathComponent("fake-helper")
    try "#!/bin/sh\n/bin/cat '\(dir.path)/msg'\nexec /bin/sleep 60\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let session = NativeRdpSession(
      configuration: RdpSessionConfiguration(host: "windows.example", username: "u", credentialRefID: nil),
      certificateVerifier: UnusedCertificateVerifier(), credentialResolver: UnusedCredentialResolver(),
      helperURL: script)
    try await session.connect()
    XCTAssertEqual(session.state, NativeRdpSessionState.connected)
    let pid = try XCTUnwrap(session.helperProcessIdentifier)
    kill(pid, SIGKILL)
    for _ in 0..<100 where session.state == .connected { try await Task.sleep(nanoseconds: 50_000_000) }
    XCTAssertEqual(session.state, NativeRdpSessionState.disconnected(reason: .helperCrashed))
  }

  func testHelperFrameReachesMetalRenderer() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("Metal default device not available in this test environment")
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rdp-frame-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let frameBytes = Data([0x20, 0x40, 0xE0, 0xFF, 0x20, 0x40, 0xE0, 0xFF,
                           0x20, 0x40, 0xE0, 0xFF, 0x20, 0x40, 0xE0, 0xFF])
    var wire = try RdpHelperMessage.connected.encoded()
    wire.append(try RdpHelperMessage.frame(
      width: 2, height: 2, bytesPerRow: 8, data: frameBytes
    ).encoded())
    try wire.write(to: dir.appendingPathComponent("messages"))
    let script = dir.appendingPathComponent("fake-helper")
    try "#!/bin/sh\n/bin/cat '\(dir.appendingPathComponent("messages").path)'\nexec /bin/sleep 60\n"
      .write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let renderer = RdpMetalRenderer()
    let frameReceived = expectation(description: "helper framebuffer reaches renderer")
    let session = NativeRdpSession(
      configuration: RdpSessionConfiguration(host: "windows.example", username: "u", credentialRefID: nil),
      certificateVerifier: UnusedCertificateVerifier(), credentialResolver: UnusedCredentialResolver(),
      helperURL: script)
    session.onFrameReady = { frame in
      XCTAssertEqual(frame.data, frameBytes)
      try? renderer.uploadFrame(frame)
      frameReceived.fulfill()
    }
    try await session.connect()
    await fulfillment(of: [frameReceived], timeout: 2)
    XCTAssertEqual(renderer.currentFrameSize?.width, 2)
    XCTAssertEqual(renderer.currentFrameSize?.height, 2)
    if let pid = session.helperProcessIdentifier { kill(pid, SIGKILL) }
    await session.disconnect()
  }

  func testHelperDyingBeforeConnectFailsConnect() async throws {
    let session = NativeRdpSession(
      configuration: RdpSessionConfiguration(host: "windows.example", username: "u", credentialRefID: nil),
      certificateVerifier: UnusedCertificateVerifier(), credentialResolver: UnusedCredentialResolver(),
      helperURL: URL(fileURLWithPath: "/usr/bin/true"))
    do {
      try await session.connect()
      XCTFail("must fail")
    } catch {
      guard case .helperProcessFailed = error as? RdpSessionError else { return XCTFail("\(error)") }
    }
  }

  /// Real helper binary + FreeRDP against a closed loopback port: error comes back over the socket.
  func testRealHelperReportsConnectFailure() async throws {
    XCTAssertNotNil(RdpHelperProcess.defaultHelperURL(), "RdpSessionHelper must be built next to the tests")
    let session = NativeRdpSession(
      configuration: RdpSessionConfiguration(host: "127.0.0.1", port: 1, username: "u", credentialRefID: nil),
      certificateVerifier: UnusedCertificateVerifier(), credentialResolver: UnusedCredentialResolver())
    do {
      try await session.connect()
      XCTFail("must fail")
    } catch {
      guard case .tcpConnectionFailed = error as? RdpSessionError else {
        return XCTFail("FreeRDP did not reach the loopback connection: \(error)")
      }
    }
  }
}
