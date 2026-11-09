import Darwin
import Foundation
import XCTest

@testable import AppCore

final class RdpHelperMemoryTests: XCTestCase {
  private func be32(_ value: UInt32) -> Data {
    Data([UInt8(value >> 24), UInt8((value >> 16) & 255),
          UInt8((value >> 8) & 255), UInt8(value & 255)])
  }

  private func legacyEncoded(_ message: RdpHelperMessage) throws -> Data {
    var body = Data()
    if case .frame(let width, let height, let stride, let pixels) = message {
      body.append(1)
      for value in [width, height, stride] {
        body.append(be32(UInt32(truncatingIfNeeded: value)))
      }
      body.append(pixels)
    } else {
      body.append(0)
      body.append(try JSONEncoder().encode(message))
    }
    var wire = be32(UInt32(body.count))
    wire.append(body)
    return wire
  }

  func testFrameGoldenBytesAndLegacyEquivalence() throws {
    // Include row padding and nonzero Data indices.
    let pixels = Data([99, 0, 1, 2, 3, 4, 5, 6, 7]).dropFirst()
    let message = RdpHelperMessage.frame(width: 1, height: 1, bytesPerRow: 8, data: pixels)
    let wire = try message.encoded()
    XCTAssertEqual(wire, Data([
      0, 0, 0, 21, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 8,
      0, 1, 2, 3, 4, 5, 6, 7,
    ]))
    XCTAssertEqual(wire, try legacyEncoded(message))
    XCTAssertEqual(try RdpHelperMessage.decode(body: wire.dropFirst(4)), message)
  }

  func testControlLegacyEquivalenceAndRoundTrips() throws {
    let messages: [RdpHelperMessage] = [
      .start(host: "fixture", port: 3389, width: 800, height: 600, scaleFactor: 100,
             clipboardDirectory: "/tmp/fixture", sharedFolder: "/tmp/shared"),
      .trustDecision(accepted: true, username: "fixture", domain: nil, password: "synthetic"),
      .trustDecision(accepted: false, username: nil, domain: nil, password: nil),
      .key(scancode: 0xffff, isExtended: true, isKeyUp: false),
      .pointer(x: 65535, y: 0, buttonFlags: 4),
      .resize(width: 1920, height: 1080, scaleFactor: 200),
      .clipboardActive(false), .cancelClipboardFiles, .abort,
      .certificate(host: "fixture", port: 3389, sha256: "AB", subjectCN: "s",
                   issuerCN: "i", changed: true),
      .connected, .clipboardStatus(message: "Receiving…", busy: true),
      .ended(code: UInt32.max, message: "done", connected: false),
    ]
    XCTAssertEqual(try RdpHelperMessage.connected.encoded(),
                   Data([0, 0, 0, 17, 0]) + Data(#"{"connected":{}}"#.utf8))
    for message in messages {
      // JSON object key order is unspecified; compare decoded JSON for controls with multiple keys.
      let wire = try message.encoded()
      let legacy = try legacyEncoded(message)
      XCTAssertEqual(wire.prefix(5), legacy.prefix(5))
      let actualJSON = try JSONSerialization.jsonObject(with: wire.dropFirst(5)) as! NSDictionary
      let legacyJSON = try JSONSerialization.jsonObject(with: legacy.dropFirst(5)) as! NSDictionary
      XCTAssertEqual(actualJSON, legacyJSON)
      XCTAssertEqual(try RdpHelperMessage.decode(body: wire.dropFirst(4)), message)
    }
  }

  func testLargeFrameCrossesSmallSocketBufferWithoutTruncation() throws {
    var fds: [Int32] = [0, 0]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
    let sender = RdpHelperChannel(fd: fds[0]), receiver = RdpHelperChannel(fd: fds[1])
    defer { sender.close(); receiver.close() }
    var buffer: Int32 = 4096
    XCTAssertEqual(setsockopt(fds[0], SOL_SOCKET, SO_SNDBUF, &buffer,
                             socklen_t(MemoryLayout<Int32>.size)), 0)
    var actualBuffer: Int32 = 0
    var size = socklen_t(MemoryLayout<Int32>.size)
    XCTAssertEqual(getsockopt(fds[0], SOL_SOCKET, SO_SNDBUF, &actualBuffer, &size), 0)
    let pixels = Data((0..<(1024 * 1024 * 4)).map { UInt8(truncatingIfNeeded: $0) })
    XCTAssertGreaterThan(pixels.count, Int(actualBuffer))
    let message = RdpHelperMessage.frame(width: 1024, height: 1024, bytesPerRow: 4096, data: pixels)
    let sent = expectation(description: "large frame and trailing control sent")
    Thread {
      XCTAssertTrue(sender.send(message))
      XCTAssertTrue(sender.send(.abort))
      sender.close()
      sent.fulfill()
    }.start()
    // Bound the blocking receive if a regression stalls the writer.
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    XCTAssertEqual(setsockopt(fds[1], SOL_SOCKET, SO_RCVTIMEO, &timeout,
                             socklen_t(MemoryLayout<timeval>.size)), 0)
    XCTAssertEqual(try receiver.receive(), message)
    XCTAssertEqual(try receiver.receive(), .abort)
    XCTAssertNil(try receiver.receive())
    wait(for: [sent], timeout: 10)
  }
}
