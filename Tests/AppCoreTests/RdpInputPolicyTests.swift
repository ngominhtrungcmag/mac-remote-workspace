import Darwin
import Foundation
import Metal
import XCTest

@testable import AppCore

final class RdpInputPolicyTests: XCTestCase {
  func testInputPolicyDefaultsToInteractiveAndExposesCapabilities() {
    let config = RdpSessionConfiguration(
      host: "fixture.invalid",
      username: "fixture",
      credentialRefID: nil
    )
    XCTAssertEqual(config.inputPolicy, .interactive)
    XCTAssertFalse(RdpInputPolicy.interactive.isViewOnly)
    XCTAssertTrue(RdpInputPolicy.interactive.allowsInput)
    XCTAssertTrue(RdpInputPolicy.interactive.allowsClipboard)

    XCTAssertTrue(RdpInputPolicy.viewOnly.isViewOnly)
    XCTAssertFalse(RdpInputPolicy.viewOnly.allowsInput)
    XCTAssertFalse(RdpInputPolicy.viewOnly.allowsClipboard)
  }

  func testServiceBoundaryBlocksKeyPointerAndClipboardWhilePreservingFramesAndResize() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rdp-input-policy-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }

    let frameBytes = Data([0x20, 0x40, 0xE0, 0xFF, 0x20, 0x40, 0xE0, 0xFF,
                           0x20, 0x40, 0xE0, 0xFF, 0x20, 0x40, 0xE0, 0xFF])
    var wire = try RdpHelperMessage.connected.encoded()
    wire.append(try RdpHelperMessage.frame(width: 2, height: 2, bytesPerRow: 8, data: frameBytes).encoded())
    try wire.write(to: directory.appendingPathComponent("connected"))

    let script = directory.appendingPathComponent("helper")
    try "#!/bin/sh\n/bin/cat '\(directory.path)/connected'\nexec /bin/cat > '\(directory.path)/captured'\n"
      .write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

    let session = NativeRdpSession(
      configuration: RdpSessionConfiguration(
        host: "fixture.invalid",
        username: "fixture",
        credentialRefID: nil,
        initialResolution: RdpDisplayResolution(width: 800, height: 600),
        options: RdpConnectionOptions(displayMode: .window, retina: false, networkProfile: .automatic)
      ),
      certificateVerifier: UnusedCertificateVerifier(),
      credentialResolver: UnusedCredentialResolver(),
      helperURL: script
    )

    let frameExpectation = expectation(description: "frame forwarded in view-only")
    session.onFrameReady = { frame in
      if frame.data == frameBytes {
        frameExpectation.fulfill()
      }
    }

    let policyRecorder = PolicyRecorder()
    session.onInputPolicyChange = { policy in
      policyRecorder.append(policy)
    }

    // Switch to view-only before connect: initial clipboard focus and all inputs must be blocked.
    session.setClipboardFocused(true)
    session.setViewOnly(true)
    XCTAssertTrue(session.isViewOnly)
    XCTAssertEqual(session.inputPolicy, .viewOnly)
    XCTAssertEqual(policyRecorder.values, [.viewOnly])

    try await session.connect()
    await fulfillment(of: [frameExpectation], timeout: 3)

    // Attempt direct service bypasses for keys, Ctrl+Alt+Del, pointer, and clipboard focus while view-only.
    session.sendKeyEvent(RdpKeyboardEvent(scancode: 0x1E, isExtended: false, isKeyUp: false))
    for event in RdpScancodeMapper.ctrlAltDelSequence() {
      session.sendKeyEvent(event)
    }
    session.sendPointerEvent(x: 100, y: 200, buttonFlags: 0x01)
    session.sendPointerEvent(x: 100, y: 200, buttonFlags: 0x10)
    session.setClipboardFocused(true)

    // Display resize must still pass through as a barrier marker while view-only is active.
    let resizeMarker = RdpHelperMessage.resize(width: 1024, height: 768, scaleFactor: 100)
    session.updateResolution(RdpDisplayResolution(width: 1024, height: 768, scaleFactor: 100))

    let messagesWhileViewOnly = try await waitForCapturedMessages(
      at: directory.appendingPathComponent("captured"),
      containing: resizeMarker
    )
    XCTAssertFalse(
      messagesWhileViewOnly.contains {
        switch $0 {
        case .key, .pointer: return true
        case .clipboardActive(let active): return active
        default: return false
        }
      },
      "View-only mode must block all key, pointer, and active clipboard messages at the service boundary: \(messagesWhileViewOnly)"
    )
    XCTAssertTrue(messagesWhileViewOnly.contains(.clipboardActive(false)))

    // Re-enabling interactive mode restores input and previously requested clipboard focus.
    session.setViewOnly(false)
    XCTAssertFalse(session.isViewOnly)
    XCTAssertEqual(policyRecorder.values, [.viewOnly, .interactive])

    let interactiveKey = RdpKeyboardEvent(scancode: 0x2E, isExtended: false, isKeyUp: false)
    let interactivePointer = RdpHelperMessage.pointer(x: 42, y: 84, buttonFlags: 0x01)
    session.sendKeyEvent(interactiveKey)
    session.sendPointerEvent(x: 42, y: 84, buttonFlags: 0x01)

    let messagesAfterInteractive = try await waitForCapturedMessages(
      at: directory.appendingPathComponent("captured"),
      containing: interactivePointer
    )
    XCTAssertTrue(messagesAfterInteractive.contains(.key(scancode: 0x2E, isExtended: false, isKeyUp: false)))
    XCTAssertTrue(messagesAfterInteractive.contains(interactivePointer))

    // Toggling back to view-only while connected cancels any active clipboard transfer and deactivates clipboard.
    session.setViewOnly(true)
    let secondResize = RdpHelperMessage.resize(width: 1280, height: 720, scaleFactor: 100)
    session.updateResolution(RdpDisplayResolution(width: 1280, height: 720, scaleFactor: 100))
    let messagesAfterSecondViewOnly = try await waitForCapturedMessages(
      at: directory.appendingPathComponent("captured"),
      containing: secondResize
    )
    XCTAssertTrue(messagesAfterSecondViewOnly.contains(.cancelClipboardFiles))

    if let pid = session.helperProcessIdentifier { kill(pid, SIGKILL) }
    await session.disconnect()
  }

  func testSwitchingToViewOnlyFlushesHeldKeysAndButtonsBeforeClosingInputGate() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rdp-release-policy-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }

    try RdpHelperMessage.connected.encoded().write(to: directory.appendingPathComponent("connected"))
    let script = directory.appendingPathComponent("helper")
    try "#!/bin/sh\n/bin/cat '\(directory.path)/connected'\nexec /bin/cat > '\(directory.path)/captured'\n"
      .write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

    let session = NativeRdpSession(
      configuration: RdpSessionConfiguration(
        host: "fixture.invalid",
        username: "fixture",
        credentialRefID: nil,
        initialResolution: RdpDisplayResolution(width: 800, height: 600),
        options: RdpConnectionOptions(displayMode: .window, retina: false, networkProfile: .automatic)
      ),
      certificateVerifier: UnusedCertificateVerifier(),
      credentialResolver: UnusedCredentialResolver(),
      helperURL: script
    )

    try await session.connect()
    session.setClipboardFocused(true)

    let releaseTracker = HeldInputTracker()
    var keyboard = RdpKeyboardInput()
    _ = keyboard.modifierChanged(0x37) // Left Command
    for event in keyboard.keyDown(0x08) { // 'C' -> emits Ctrl down (0x1D) + C down (0x2E)
      session.sendKeyEvent(event)
    }
    session.sendPointerEvent(x: 50, y: 60, buttonFlags: 0x01) // Left button down

    session.onReleaseHeldInput = { [weak session, releaseTracker] in
      releaseTracker.recordInvocation()
      // Transport already atomically flushed held releases and closed the input gate under lock;
      // any late or re-entrant input injection inside onReleaseHeldInput must be rejected.
      session?.sendKeyEvent(RdpKeyboardEvent(scancode: 0x1F, isExtended: false, isKeyUp: false))
      session?.sendPointerEvent(x: 70, y: 80, buttonFlags: 0x04)
    }

    // Transition to view-only and immediately attempt post-transition inputs that must be dropped.
    session.setViewOnly(true)
    session.setViewOnly(true) // idempotent repeat must not re-fire release hook
    XCTAssertEqual(releaseTracker.invocations, 1)

    session.sendKeyEvent(RdpKeyboardEvent(scancode: 0x1E, isExtended: false, isKeyUp: false))
    session.sendPointerEvent(x: 99, y: 99, buttonFlags: 0x01)

    // Use a resize message as an end-of-stream barrier.
    let barrier = RdpHelperMessage.resize(width: 1200, height: 900, scaleFactor: 100)
    session.updateResolution(RdpDisplayResolution(width: 1200, height: 900, scaleFactor: 100))

    let messages = try await waitForCapturedMessages(
      at: directory.appendingPathComponent("captured"),
      containing: barrier
    )

    // Held keys (Ctrl up 0x1D, C up 0x2E) and left mouse button up (0x02) must have crossed before the gate closed.
    XCTAssertTrue(messages.contains(.key(scancode: 0x1D, isExtended: false, isKeyUp: false)))
    XCTAssertTrue(messages.contains(.key(scancode: 0x2E, isExtended: false, isKeyUp: false)))
    XCTAssertTrue(messages.contains(.pointer(x: 50, y: 60, buttonFlags: 0x01)))
    XCTAssertTrue(messages.contains(.key(scancode: 0x2E, isExtended: false, isKeyUp: true)))
    XCTAssertTrue(messages.contains(.key(scancode: 0x1D, isExtended: false, isKeyUp: true)))
    XCTAssertTrue(messages.contains(.pointer(x: 50, y: 60, buttonFlags: 0x02)))
    XCTAssertTrue(messages.contains(.clipboardActive(false)))
    XCTAssertTrue(messages.contains(.cancelClipboardFiles))

    // Late inputs during onReleaseHeldInput or after view-only must be absent.
    XCTAssertFalse(messages.contains(.key(scancode: 0x1F, isExtended: false, isKeyUp: false)))
    XCTAssertFalse(messages.contains(.pointer(x: 70, y: 80, buttonFlags: 0x04)))
    XCTAssertFalse(messages.contains(.key(scancode: 0x1E, isExtended: false, isKeyUp: false)))
    XCTAssertFalse(messages.contains(.pointer(x: 99, y: 99, buttonFlags: 0x01)))

    if let pid = session.helperProcessIdentifier { kill(pid, SIGKILL) }
    await session.disconnect()
  }

  func testConfiguringSessionAsViewOnlyBlocksFromStartWithoutAffectingHostTrust() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rdp-initial-viewonly-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }

    try RdpHelperMessage.connected.encoded().write(to: directory.appendingPathComponent("connected"))
    let script = directory.appendingPathComponent("helper")
    try "#!/bin/sh\n/bin/cat '\(directory.path)/connected'\nexec /bin/cat > '\(directory.path)/captured'\n"
      .write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

    let session = NativeRdpSession(
      configuration: RdpSessionConfiguration(
        host: "fixture.invalid",
        username: "fixture",
        credentialRefID: nil,
        initialResolution: RdpDisplayResolution(width: 800, height: 600),
        options: RdpConnectionOptions(displayMode: .window, retina: false, networkProfile: .automatic),
        inputPolicy: .viewOnly
      ),
      certificateVerifier: UnusedCertificateVerifier(),
      credentialResolver: UnusedCredentialResolver(),
      helperURL: script
    )

    XCTAssertTrue(session.isViewOnly)
    XCTAssertEqual(session.inputPolicy, .viewOnly)
    session.setClipboardFocused(true)

    try await session.connect()
    session.sendKeyEvent(RdpKeyboardEvent(scancode: 0x1E, isExtended: false, isKeyUp: false))
    session.sendPointerEvent(x: 10, y: 20, buttonFlags: 0x01)

    let barrier = RdpHelperMessage.resize(width: 900, height: 700, scaleFactor: 100)
    session.updateResolution(RdpDisplayResolution(width: 900, height: 700, scaleFactor: 100))

    let messages = try await waitForCapturedMessages(
      at: directory.appendingPathComponent("captured"),
      containing: barrier
    )
    XCTAssertTrue(messages.contains(.clipboardActive(false)))
    XCTAssertTrue(
      messages.contains(.cancelClipboardFiles),
      "Initial view-only session must deliver .cancelClipboardFiles to the helper immediately on start: \(messages)"
    )
    if let startIndex = messages.firstIndex(where: { if case .start = $0 { return true }; return false }),
       let cancelIndex = messages.firstIndex(of: .cancelClipboardFiles),
       let resizeIndex = messages.firstIndex(of: barrier) {
      XCTAssertLessThan(startIndex, cancelIndex)
      XCTAssertLessThan(cancelIndex, resizeIndex)
    } else {
      XCTFail("Expected .start, .cancelClipboardFiles, and .resize in captured messages: \(messages)")
    }
    XCTAssertFalse(messages.contains {
      switch $0 {
      case .key, .pointer: return true
      case .clipboardActive(let active): return active
      default: return false
      }
    })

    if let pid = session.helperProcessIdentifier { kill(pid, SIGKILL) }
    await session.disconnect()
  }

  func testConcurrentOffMainViewOnlyTransitionDoesNotDeadlockAndLeavesNoStuckHeldInput() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rdp-concurrent-policy-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }

    try RdpHelperMessage.connected.encoded().write(to: directory.appendingPathComponent("connected"))
    let script = directory.appendingPathComponent("helper")
    try "#!/bin/sh\n/bin/cat '\(directory.path)/connected'\nexec /bin/cat > '\(directory.path)/captured'\n"
      .write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

    let session = NativeRdpSession(
      configuration: RdpSessionConfiguration(
        host: "fixture.invalid",
        username: "fixture",
        credentialRefID: nil,
        initialResolution: RdpDisplayResolution(width: 800, height: 600),
        options: RdpConnectionOptions(displayMode: .window, retina: false, networkProfile: .automatic)
      ),
      certificateVerifier: UnusedCertificateVerifier(),
      credentialResolver: UnusedCredentialResolver(),
      helperURL: script
    )

    try await session.connect()

    // Press initial key and mouse button before concurrent transition.
    session.sendKeyEvent(RdpKeyboardEvent(scancode: 0x1E, isExtended: false, isKeyUp: false))
    session.sendPointerEvent(x: 10, y: 20, buttonFlags: 0x01)

    // Simulate a caller holding the main thread while a background queue triggers setInputPolicy(.viewOnly)
    // and another thread races sendKeyEvent / sendPointerEvent calls.
    let transitionDone = DispatchSemaphore(value: 0)
    let spamDone = DispatchSemaphore(value: 0)

    await MainActor.run {
      DispatchQueue.global(qos: .userInitiated).async {
        for i in 0..<25 {
          let code = UInt16(0x20 + (i % 5))
          session.sendKeyEvent(RdpKeyboardEvent(scancode: code, isExtended: false, isKeyUp: false))
          session.sendPointerEvent(x: UInt16(30 + i), y: 40, buttonFlags: 0x04)
        }
        spamDone.signal()
      }
      DispatchQueue.global(qos: .userInitiated).async {
        session.setInputPolicy(.viewOnly)
        transitionDone.signal()
      }
      // Block the main thread waiting for the background policy transition: if setInputPolicy used
      // DispatchQueue.main.sync internally, this wait would deterministically time out (deadlock).
      XCTAssertEqual(transitionDone.wait(timeout: .now() + 2), .success, "setInputPolicy(.viewOnly) off-main must never deadlock when main thread is blocked")
      XCTAssertEqual(spamDone.wait(timeout: .now() + 2), .success)
    }

    let barrier = RdpHelperMessage.resize(width: 1000, height: 800, scaleFactor: 100)
    session.updateResolution(RdpDisplayResolution(width: 1000, height: 800, scaleFactor: 100))

    let messages = try await waitForCapturedMessages(
      at: directory.appendingPathComponent("captured"),
      containing: barrier
    )

    // Verify that after all messages settle in view-only mode, every key-down or button-down that
    // crossed the wire before the gate closed has a matching key-up / button-up (zero stuck inputs).
    var netHeldKeys: Set<UInt16> = []
    var netHeldButtons: Set<UInt16> = []
    for msg in messages {
      switch msg {
      case .key(let scancode, _, let isKeyUp):
        if isKeyUp {
          netHeldKeys.remove(scancode)
        } else {
          netHeldKeys.insert(scancode)
        }
      case .pointer(_, _, let flags):
        switch flags {
        case 0x01: netHeldButtons.insert(0x01)
        case 0x02: netHeldButtons.remove(0x01)
        case 0x04: netHeldButtons.insert(0x04)
        case 0x08: netHeldButtons.remove(0x04)
        case 0x09: netHeldButtons.insert(0x09)
        case 0x0A: netHeldButtons.remove(0x09)
        default: break
        }
      default:
        break
      }
    }
    XCTAssertTrue(netHeldKeys.isEmpty, "No key may remain stuck down after view-only transition: \(netHeldKeys)")
    XCTAssertTrue(netHeldButtons.isEmpty, "No mouse button may remain stuck down after view-only transition: \(netHeldButtons)")

    if let pid = session.helperProcessIdentifier { kill(pid, SIGKILL) }
    await session.disconnect()
  }

  private func waitForCapturedMessages(
    at url: URL,
    containing marker: RdpHelperMessage
  ) async throws -> [RdpHelperMessage] {
    var messages: [RdpHelperMessage] = []
    for _ in 0..<80 {
      messages = (try? capturedMessages(at: url)) ?? []
      if messages.contains(marker) { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(messages.contains(marker), "Timed out waiting for marker \(marker) in \(messages)")
    return messages
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
}

private final class PolicyRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var _values: [RdpInputPolicy] = []

  var values: [RdpInputPolicy] {
    lock.withLock { _values }
  }

  func append(_ policy: RdpInputPolicy) {
    lock.withLock { _values.append(policy) }
  }
}

private final class HeldInputTracker: @unchecked Sendable {
  private let lock = NSLock()
  var keyboard = RdpKeyboardInput()
  private var _invocations = 0

  var invocations: Int {
    lock.withLock { _invocations }
  }

  func recordInvocation() {
    lock.withLock { _invocations += 1 }
  }

  func releaseKeyboard() -> [RdpKeyboardEvent] {
    lock.withLock { keyboard.releaseAll() }
  }
}
