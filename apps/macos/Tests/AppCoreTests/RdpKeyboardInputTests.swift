import XCTest
@testable import AppCore

final class RdpKeyboardInputTests: XCTestCase {
  func testWindowsAppCommandShortcuts() {
    for key: UInt16 in [0x08, 0x07, 0x09, 0x00, 0x06, 0x03, 0x0D] {
      var input = RdpKeyboardInput()
      XCTAssertEqual(input.modifierChanged(0x37), [])
      let mapped = RdpScancodeMapper.mapMacKeyCode(key)!
      XCTAssertEqual(input.keyDown(key), [RdpKeyboardEvent(scancode: 0x1D), mapped])
      XCTAssertEqual(input.keyUp(key), [RdpKeyboardEvent(scancode: mapped.scancode, isKeyUp: true), RdpKeyboardEvent(scancode: 0x1D, isKeyUp: true)])
      XCTAssertEqual(input.modifierChanged(0x37), [])
    }
  }

  func testCommandAloneOpensStartOnRelease() {
    var input = RdpKeyboardInput()
    XCTAssertEqual(input.modifierChanged(0x37), [])
    XCTAssertEqual(input.modifierChanged(0x37), [RdpKeyboardEvent(scancode: 0x5B, isExtended: true), RdpKeyboardEvent(scancode: 0x5B, isExtended: true, isKeyUp: true)])
  }

  func testOtherCommandCombinationsStillUseWindowsKey() {
    var input = RdpKeyboardInput()
    _ = input.modifierChanged(0x36)
    XCTAssertEqual(input.keyDown(0x0F), [RdpKeyboardEvent(scancode: 0x5C, isExtended: true), RdpKeyboardEvent(scancode: 0x13)])
    XCTAssertEqual(input.releaseAll().count, 2)
    XCTAssertEqual(input.releaseAll(), [])
  }

  func testRepeatAndPhysicalControlAreBalanced() {
    var input = RdpKeyboardInput()
    _ = input.modifierChanged(0x3B)
    _ = input.modifierChanged(0x37)
    XCTAssertEqual(input.keyDown(0x08), [RdpKeyboardEvent(scancode: 0x2E)])
    XCTAssertEqual(input.keyDown(0x08), [RdpKeyboardEvent(scancode: 0x2E)])
    XCTAssertEqual(input.keyUp(0x08), [RdpKeyboardEvent(scancode: 0x2E, isKeyUp: true)])
    XCTAssertEqual(input.modifierChanged(0x37), [])
    XCTAssertEqual(input.modifierChanged(0x3B), [RdpKeyboardEvent(scancode: 0x1D, isKeyUp: true)])
  }

  func testRightCommandAndShiftPreserveRedoAndModifierReleaseOrder() {
    var input = RdpKeyboardInput()
    _ = input.modifierChanged(0x36)
    XCTAssertEqual(input.modifierChanged(0x3C), [RdpKeyboardEvent(scancode: 0x36)])
    XCTAssertEqual(input.keyDown(0x06), [RdpKeyboardEvent(scancode: 0x1D), RdpKeyboardEvent(scancode: 0x2C)])
    XCTAssertEqual(input.modifierChanged(0x36), [])
    XCTAssertEqual(input.keyUp(0x06), [RdpKeyboardEvent(scancode: 0x2C, isKeyUp: true), RdpKeyboardEvent(scancode: 0x1D, isKeyUp: true)])
    XCTAssertEqual(input.releaseAll(), [RdpKeyboardEvent(scancode: 0x36, isKeyUp: true)])
  }

  func testShortcutAfterWindowsCombinationWithoutReleasingCommand() {
    var input = RdpKeyboardInput()
    _ = input.modifierChanged(0x37)
    _ = input.keyDown(0x0F)
    _ = input.keyUp(0x0F)
    XCTAssertEqual(input.keyDown(0x08), [RdpKeyboardEvent(scancode: 0x5B, isExtended: true, isKeyUp: true), RdpKeyboardEvent(scancode: 0x1D), RdpKeyboardEvent(scancode: 0x2E)])
  }

  func testFocusLossReleasesShortcutAndIgnoresLateKeyUp() {
    var input = RdpKeyboardInput()
    _ = input.modifierChanged(0x37)
    _ = input.keyDown(0x09)
    XCTAssertEqual(input.releaseAll(), [RdpKeyboardEvent(scancode: 0x2F, isKeyUp: true), RdpKeyboardEvent(scancode: 0x1D, isKeyUp: true)])
    XCTAssertEqual(input.keyUp(0x09), [])
  }
}
