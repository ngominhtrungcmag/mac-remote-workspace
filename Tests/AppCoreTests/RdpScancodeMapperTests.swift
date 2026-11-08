import Foundation
import XCTest

@testable import AppCore

final class RdpScancodeMapperTests: XCTestCase {
  func testMapsBasicKeys() {
    // Letter 'A' (macOS 0x00 -> Windows 0x1E)
    let aEvent = RdpScancodeMapper.mapMacKeyCode(0x00, isKeyUp: false)
    XCTAssertEqual(aEvent?.scancode, 0x1E)
    XCTAssertEqual(aEvent?.isExtended, false)
    XCTAssertEqual(aEvent?.isKeyUp, false)

    // Return (macOS 0x24 -> Windows 0x1C)
    let returnEvent = RdpScancodeMapper.mapMacKeyCode(0x24, isKeyUp: true)
    XCTAssertEqual(returnEvent?.scancode, 0x1C)
    XCTAssertEqual(returnEvent?.isKeyUp, true)

    // Escape (macOS 0x35 -> Windows 0x01)
    let escEvent = RdpScancodeMapper.mapMacKeyCode(0x35)
    XCTAssertEqual(escEvent?.scancode, 0x01)
  }

  func testMapsNavigationAndExtendedKeys() {
    // Left Arrow (macOS 0x7B -> Windows 0x4B, extended)
    let leftEvent = RdpScancodeMapper.mapMacKeyCode(0x7B)
    XCTAssertEqual(leftEvent?.scancode, 0x4B)
    XCTAssertEqual(leftEvent?.isExtended, true)

    // Up Arrow (macOS 0x7E -> Windows 0x48, extended)
    let upEvent = RdpScancodeMapper.mapMacKeyCode(0x7E)
    XCTAssertEqual(upEvent?.scancode, 0x48)
    XCTAssertEqual(upEvent?.isExtended, true)

    // Forward Delete (macOS 0x75 -> Windows 0x53, extended)
    let delEvent = RdpScancodeMapper.mapMacKeyCode(0x75)
    XCTAssertEqual(delEvent?.scancode, 0x53)
    XCTAssertEqual(delEvent?.isExtended, true)
  }

  func testMapsModifiersToWindowsKeys() {
    // Left Command -> Left Windows key (macOS 0x37 -> Windows 0x5B, extended)
    let cmdEvent = RdpScancodeMapper.mapMacKeyCode(0x37)
    XCTAssertEqual(cmdEvent?.scancode, 0x5B)
    XCTAssertEqual(cmdEvent?.isExtended, true)

    // Left Option -> Left Alt (macOS 0x3A -> Windows 0x38, non-extended)
    let optEvent = RdpScancodeMapper.mapMacKeyCode(0x3A)
    XCTAssertEqual(optEvent?.scancode, 0x38)
    XCTAssertEqual(optEvent?.isExtended, false)

    // Left Control -> Left Ctrl (macOS 0x3B -> Windows 0x1D, non-extended)
    let ctrlEvent = RdpScancodeMapper.mapMacKeyCode(0x3B)
    XCTAssertEqual(ctrlEvent?.scancode, 0x1D)
    XCTAssertEqual(ctrlEvent?.isExtended, false)

    let cmdUp = RdpScancodeMapper.mapMacKeyCode(0x37, isKeyUp: true)
    XCTAssertEqual(cmdUp, RdpKeyboardEvent(scancode: 0x5B, isExtended: true, isKeyUp: true))
  }

  func testCtrlAltDelSequence() {
    let sequence = RdpScancodeMapper.ctrlAltDelSequence()
    XCTAssertEqual(sequence.count, 6)

    // 1: Ctrl Down
    XCTAssertEqual(sequence[0].scancode, 0x1D)
    XCTAssertFalse(sequence[0].isKeyUp)

    // 2: Alt Down
    XCTAssertEqual(sequence[1].scancode, 0x38)
    XCTAssertFalse(sequence[1].isKeyUp)

    // 3: Del Down
    XCTAssertEqual(sequence[2].scancode, 0x53)
    XCTAssertTrue(sequence[2].isExtended)
    XCTAssertFalse(sequence[2].isKeyUp)

    // 4: Del Up
    XCTAssertEqual(sequence[3].scancode, 0x53)
    XCTAssertTrue(sequence[3].isExtended)
    XCTAssertTrue(sequence[3].isKeyUp)

    // 5: Alt Up
    XCTAssertEqual(sequence[4].scancode, 0x38)
    XCTAssertTrue(sequence[4].isKeyUp)

    // 6: Ctrl Up
    XCTAssertEqual(sequence[5].scancode, 0x1D)
    XCTAssertTrue(sequence[5].isKeyUp)
  }
}
