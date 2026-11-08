import AppKit
import XCTest
@testable import MacRemoteWorkspace

final class WindowCloseGuardTests: XCTestCase {
  @MainActor
  func testCloseGuardConsultsAndRestoresPreviousDelegate() {
    let window = NSWindow()
    let previous = PreviousDelegate()
    window.delegate = previous
    var allow = false
    let guardDelegate = WindowCloseGuard.Coordinator { allow }
    guardDelegate.attach(to: window)
    XCTAssertFalse(guardDelegate.windowShouldClose(window))
    XCTAssertEqual(previous.calls, 0)
    allow = true
    XCTAssertTrue(guardDelegate.windowShouldClose(window))
    XCTAssertEqual(previous.calls, 1)
    guardDelegate.detach()
    XCTAssertTrue(window.delegate === previous)
  }
}

private final class PreviousDelegate: NSObject, NSWindowDelegate {
  var calls = 0
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    calls += 1
    return true
  }
}
