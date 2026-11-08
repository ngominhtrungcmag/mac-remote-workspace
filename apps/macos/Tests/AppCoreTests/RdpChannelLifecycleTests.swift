import CFreeRDP
import Darwin
import Foundation
import XCTest
@testable import AppCore

private enum ChannelLoadProbe {
  static let lock = NSLock()
  nonisolated(unsafe) static var original: pConnectCallback?
  nonisolated(unsafe) static var counts: [UInt32] = []
  nonisolated(unsafe) static var threading: UInt32 = 0

  static func record(_ instance: UnsafeMutablePointer<freerdp>?) -> ObjCBool {
    guard let instance, let settings = instance.pointee.context?.pointee.settings,
      let original = lock.withLock({ original }) else { return false }
    let result = original(instance)
    lock.withLock {
      counts.append(freerdp_settings_get_uint32(settings, FreeRDP_ChannelCount))
      threading = freerdp_settings_get_uint32(settings, FreeRDP_ThreadingFlags)
    }
    return result
  }
}

final class RdpChannelLifecycleTests: XCTestCase {
  func testRealFreeRdpReloadsClipboardAfterPreConnectReset() throws {
    let instance = try XCTUnwrap(freerdp_new())
    XCTAssertTrue(freerdp_context_new(instance))
    defer { freerdp_context_free(instance); freerdp_free(instance) }
    let settings = try XCTUnwrap(instance.pointee.context?.pointee.settings)
    FreeRdpClient.installChannelLoader(on: instance)
    let loader = try XCTUnwrap(instance.pointee.LoadChannels,
      "FreeRDP discards channels loaded in PreConnect; use its reload callback")
    ChannelLoadProbe.lock.withLock {
      ChannelLoadProbe.original = loader
      ChannelLoadProbe.counts = []
      ChannelLoadProbe.threading = 0
    }
    defer { ChannelLoadProbe.lock.withLock { ChannelLoadProbe.original = nil } }
    instance.pointee.LoadChannels = { ChannelLoadProbe.record($0) }

    // Reserve a non-listening loopback socket: connection must fail before trust/authentication.
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(fd, 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    XCTAssertEqual(bound, 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    XCTAssertEqual(named, 0)
    XCTAssertTrue(freerdp_settings_set_string(settings, FreeRDP_ServerHostname, "127.0.0.1"))
    XCTAssertTrue(freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, UInt32(UInt16(bigEndian: address.sin_port))))
    XCTAssertTrue(freerdp_settings_set_uint32(settings, FreeRDP_TcpConnectTimeout, 100))
    XCTAssertFalse(freerdp_connect(instance))
    let result = ChannelLoadProbe.lock.withLock { (ChannelLoadProbe.counts, ChannelLoadProbe.threading) }
    XCTAssertFalse(result.0.isEmpty, "the real FreeRDP connect lifecycle must invoke our loader")
    XCTAssertTrue(result.0.allSatisfy { $0 == 2 }, "only drdynvc and cliprdr should be loaded")
    XCTAssertNotEqual(result.1 & UInt32(THREADING_FLAGS_DISABLE_THREADS), 0,
      "clipboard callbacks and polling must share the RDP thread")
    XCTAssertNotNil(freerdp_load_channel_addin_entry("disp", nil, nil, UInt32(FREERDP_ADDIN_CHANNEL_DYNAMIC)),
      "drdynvc must resolve the built-in display channel without loading a dylib")
  }
}
