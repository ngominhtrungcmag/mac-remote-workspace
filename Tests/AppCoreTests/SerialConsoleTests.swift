import Darwin
import Foundation
import XCTest

@testable import AppCore

final class SerialConsoleTests: XCTestCase {
  func testValidation() throws {
    try SerialConfig(path: "/dev/cu.usbserial-1").validate()
    for bad in ["/dev/tty.x", "/etc/passwd", "/dev/cu.", "/dev/cu.a/../b", "/dev/cu.a/b"] {
      XCTAssertThrowsError(try SerialConfig(path: bad).validate(), bad)
    }
    XCTAssertThrowsError(try SerialConfig(path: "/dev/cu.x", baudRate: 1234).validate())
    XCTAssertThrowsError(try SerialConfig(path: "/dev/cu.x", dataBits: 9).validate())
    XCTAssertThrowsError(try SerialConfig(path: "/dev/cu.x", stopBits: 3).validate())
  }

  func testTermiosMapping() {
    let t = SerialConfig(
      path: "/dev/cu.x", baudRate: 9600, dataBits: 7, parity: .odd, stopBits: 2, flowControl: .rtsCts
    ).makeTermios()
    XCTAssertEqual(t.c_cflag & tcflag_t(CSIZE), tcflag_t(CS7))
    XCTAssertNotEqual(t.c_cflag & tcflag_t(PARENB), 0)
    XCTAssertNotEqual(t.c_cflag & tcflag_t(PARODD), 0)
    XCTAssertNotEqual(t.c_cflag & tcflag_t(CSTOPB), 0)
    XCTAssertNotEqual(t.c_cflag & tcflag_t(CRTSCTS), 0)
    XCTAssertEqual(t.c_ispeed, 9600)
    let d = SerialConfig(path: "/dev/cu.x", flowControl: .xonXoff).makeTermios()
    XCTAssertEqual(d.c_cflag & tcflag_t(CSIZE), tcflag_t(CS8))
    XCTAssertEqual(d.c_cflag & tcflag_t(PARENB | CSTOPB | CRTSCTS), 0)
    XCTAssertNotEqual(d.c_iflag & tcflag_t(IXON | IXOFF), 0)
  }

  func testOpenMissingPort() {
    XCTAssertThrowsError(try SerialSession.open(SerialConfig(path: "/dev/cu.nope-xyz"), onData: { _ in })) {
      XCTAssertEqual($0 as? SerialError, .notFound("/dev/cu.nope-xyz"))
    }
  }

  func testPtyLoopback() throws {
    var master: Int32 = -1
    var slave: Int32 = -1
    var nameBuf = [CChar](repeating: 0, count: 128)
    XCTAssertEqual(openpty(&master, &slave, &nameBuf, nil, nil), 0)
    defer { Darwin.close(master); Darwin.close(slave) }
    let path = String(cString: nameBuf)

    let got = LockedData()
    let received = expectation(description: "data")
    let session = try SerialSession.open(
      SerialConfig(path: path, baudRate: 9600, dataBits: 8, parity: .none, stopBits: 1),
      devicePrefix: "/dev/",
      onData: { got.append($0); if got.value.count >= 5 { received.fulfill() } })
    // device -> app
    XCTAssertEqual(Darwin.write(master, "hello", 5), 5)
    wait(for: [received], timeout: 3)
    XCTAssertEqual(String(decoding: got.value, as: UTF8.self), "hello")
    // app -> device
    try session.write(Data("world".utf8))
    var buf = [UInt8](repeating: 0, count: 16)
    var n = -1
    _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
    for _ in 0..<50 {
      n = read(master, &buf, buf.count)
      if n > 0 { break }
      usleep(50_000)
    }
    XCTAssertEqual(String(decoding: buf[0..<max(n, 0)], as: UTF8.self), "world")
    // ponytail: EBUSY via TIOCEXCL is not enforced on ptys; needs real hardware to verify.
    session.close()
    session.close()
    XCTAssertThrowsError(try session.write(Data("x".utf8))) { XCTAssertEqual($0 as? SerialError, .closed) }
  }
}

private final class LockedData: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()
  func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
  var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}
