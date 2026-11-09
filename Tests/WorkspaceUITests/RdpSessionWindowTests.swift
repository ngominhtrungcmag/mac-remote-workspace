import AppCore
import AppKit
import XCTest
@testable import MacRemoteWorkspace

final class RdpSessionWindowTests: XCTestCase {
  @MainActor
  func testEntryWaitsForVisibilityAndOnlyHappensOncePerWindow() {
    let window = FullscreenTestWindow()
    let view = RdpDefaultFullscreen.HostingView()
    window.contentView = view
    view.enterIfReady()
    XCTAssertEqual(window.toggles, 0)
    window.visibleForTest = true
    view.enterIfReady()
    view.enterIfReady()
    XCTAssertEqual(window.toggles, 1)

    let replacement = RdpDefaultFullscreen.HostingView()
    window.contentView = replacement
    replacement.enterIfReady()
    XCTAssertEqual(window.toggles, 1)
  }

  @MainActor
  func testAlreadyFullscreenIsNotToggled() {
    let window = FullscreenTestWindow()
    window.visibleForTest = true
    window.styleMask.insert(.fullScreen)
    let view = RdpDefaultFullscreen.HostingView()
    window.contentView = view
    view.enterIfReady()
    window.styleMask.remove(.fullScreen)
    view.enterIfReady()
    XCTAssertEqual(window.toggles, 0)
  }

  @MainActor
  func testMetalHostingViewSuppressesInputAndClipboardFocusInViewOnlyMode() throws {
    let renderer = RdpMetalRenderer()
    let frameBytes = Data(repeating: 0xFF, count: 4 * 4 * 4)
    try? renderer.uploadFrame(RdpFramebuffer(width: 4, height: 4, bytesPerRow: 16, pixelFormat: .bgra8Unorm, data: frameBytes))

    let view = RdpMetalHostingView(renderer: renderer)
    view.frame = NSRect(x: 0, y: 0, width: 100, height: 100)

    var keyEvents: [RdpKeyboardEvent] = []
    var pointerEvents: [(UInt16, UInt16, UInt16)] = []
    var clipboardFocusEvents: [Bool] = []
    view.onKeyEvent = { keyEvents.append($0) }
    view.onPointerEvent = { pointerEvents.append(($0, $1, $2)) }
    view.onClipboardFocus = { clipboardFocusEvents.append($0) }

    let keyDown = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
        isARepeat: false, keyCode: 0x00)
    )
    view.keyDown(with: keyDown)
    XCTAssertEqual(keyEvents, [RdpKeyboardEvent(scancode: 0x1E, isExtended: false, isKeyUp: false)])

    view.setViewOnly(true)
    XCTAssertTrue(view.isViewOnly)
    // Transitioning to view-only releases local held key state and drops clipboard focus.
    XCTAssertEqual(keyEvents.last, RdpKeyboardEvent(scancode: 0x1E, isExtended: false, isKeyUp: true))
    XCTAssertEqual(clipboardFocusEvents.last, false)

    let countBeforeViewOnlyKey = keyEvents.count
    view.keyDown(with: keyDown)
    XCTAssertEqual(keyEvents.count, countBeforeViewOnlyKey, "View-only hosting view must suppress keyDown")
    XCTAssertEqual(pointerEvents.count, 0)
  }
}

private final class FullscreenTestWindow: NSWindow {
  var visibleForTest = false
  var toggles = 0
  override var styleMask: NSWindow.StyleMask {
    get { testStyleMask }
    set { testStyleMask = newValue }
  }
  private var testStyleMask: NSWindow.StyleMask = []
  override var isVisible: Bool { visibleForTest }
  override func toggleFullScreen(_ sender: Any?) { toggles += 1 }
}
