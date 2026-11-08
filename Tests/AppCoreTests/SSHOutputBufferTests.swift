import Foundation
import XCTest
@testable import AppCore

final class SSHOutputBufferTests: XCTestCase {
  func testBoundedCapacityEnforcement() {
    let buffer = SSHOutputBuffer(capacity: 100)
    let payload = Data(repeating: 0x41, count: 150) // 'A'
    buffer.append(payload)

    let drained = buffer.drainDecodableString()
    XCTAssertEqual(drained.count, 100)
  }

  func testSplitMultibyteUTF8Preservation() {
    let buffer = SSHOutputBuffer(capacity: 1000)

    // The emoji "🚀" is 4 bytes in UTF-8: 0xF0 0x9F 0x9A 0x80
    let rocketBytes = Array("🚀".utf8)
    let part1 = Data(rocketBytes[0..<2]) // First 2 bytes
    let part2 = Data(rocketBytes[2..<4]) // Last 2 bytes

    buffer.append(part1)
    // First drain should return empty string because multi-byte sequence is split/incomplete
    let drain1 = buffer.drainDecodableString()
    XCTAssertEqual(drain1, "")

    // Second chunk completes the emoji
    buffer.append(part2)
    let drain2 = buffer.drainDecodableString()
    XCTAssertEqual(drain2, "🚀")
  }

  func testSplitKoreanCharacters() {
    let buffer = SSHOutputBuffer(capacity: 1000)
    // "한" is 3 bytes in UTF-8: Array("한".utf8)
    let hanBytes = Array("한".utf8)
    buffer.append(Data(hanBytes[0..<1]))
    XCTAssertEqual(buffer.drainDecodableString(), "")

    buffer.append(Data(hanBytes[1..<3]))
    XCTAssertEqual(buffer.drainDecodableString(), "한")
  }

  func testValidAsciiImmediatelyDrained() {
    let buffer = SSHOutputBuffer(capacity: 1000)
    buffer.append("Hello world!\n".data(using: .utf8)!)
    XCTAssertEqual(buffer.drainDecodableString(), "Hello world!\n")
  }

  func testDrainBytesReturnsRawEscapeSequencesAndSplitUTF8() {
    let buffer = SSHOutputBuffer(capacity: 1000)
    let bytes: [UInt8] = [0x1B, 0x5B, 0x32, 0x4A, 0xF0, 0x9F] // ESC[2J + partial emoji
    buffer.append(Data(bytes))
    XCTAssertEqual([UInt8](buffer.drainBytes()), bytes)
    XCTAssertTrue(buffer.drainBytes().isEmpty)
  }
}

extension SSHOutputBufferTests {
  func testMalformedUTF8DoesNotDeadlockAndStaysBounded() {
    let buffer = SSHOutputBuffer(capacity: 8)
    buffer.append(Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))
    XCTAssertFalse(buffer.drainDecodableString().isEmpty)
    buffer.append(Data(repeating: 0x42, count: 1_000))
    XCTAssertEqual(buffer.drainBytes().count, 8)
  }
}
