import XCTest
@testable import AppCore

final class RdpClipboardTextTests: XCTestCase {
  func testRoundTripWithNonBMPAndVietnamese() {
    let s = "Xin chào 😀 世界\r\nline2"
    let data = RdpClipboardText.encode(s)
    XCTAssertEqual(data?.suffix(2), Data([0, 0]))
    XCTAssertEqual(RdpClipboardText.decode(data!), s)
  }

  func testEncodeIsUTF16LE() {
    XCTAssertEqual(RdpClipboardText.encode("A"), Data([0x41, 0, 0, 0]))
  }

  func testDecodeStopsAtNulAndIgnoresOddByte() {
    XCTAssertEqual(RdpClipboardText.decode(Data([0x41, 0, 0, 0, 0x42, 0])), "A")
    XCTAssertEqual(RdpClipboardText.decode(Data([0x41, 0, 0x42])), "A")
  }

  func testRejectsEmptyAndLoneSurrogate() {
    XCTAssertNil(RdpClipboardText.encode(""))
    XCTAssertNil(RdpClipboardText.decode(Data([0, 0])))
    XCTAssertNil(RdpClipboardText.decode(Data([0x00, 0xD8, 0x41, 0])))
  }

  func testSizeCap() {
    XCTAssertNotNil(RdpClipboardText.encode("ab", maxBytes: 6))
    XCTAssertNil(RdpClipboardText.encode("abc", maxBytes: 6))
    XCTAssertNil(RdpClipboardText.decode(Data(count: 7), maxBytes: 6))
    XCTAssertNil(RdpClipboardText.encode(String(repeating: "a", count: RdpClipboardText.maxBytes)))
  }
}
