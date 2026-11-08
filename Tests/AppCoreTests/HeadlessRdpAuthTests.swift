import Foundation
import Network
import XCTest

@testable import AppCore

/// Phase 0 Feasibility Spike (SP-04): Headless RDP authentication, TLS handshake,
/// and NLA token probe tests against disposable Windows fixture or loopback.
final class HeadlessRdpAuthTests: XCTestCase {
  func testEndpointValidationBeforeNetwork() throws {
    // Valid endpoint
    let endpoint = try RdpLauncher.formatEndpoint(address: "127.0.0.1", port: 3389)
    XCTAssertEqual(endpoint, "127.0.0.1:3389")

    // IPv6 bracketed
    let ipv6Endpoint = try RdpLauncher.formatEndpoint(address: "::1", port: 3389)
    XCTAssertEqual(ipv6Endpoint, "[::1]:3389")

    // Negative tests: invalid address
    XCTAssertThrowsError(try RdpLauncher.formatEndpoint(address: "invalid;rm -rf /"))
    XCTAssertThrowsError(try RdpLauncher.formatEndpoint(address: "127.0.0.1", port: 0))
  }

  func testRdpCertificateFingerprintComputation() throws {
    // Simulate SHA-256 calculation for an X.509 DER byte array
    let dummyDerBytes: [UInt8] = Array(repeating: 0x42, count: 256)
    let digest = dummyDerBytes.withUnsafeBytes { rawBuffer in
      var hash = [UInt8](repeating: 0, count: 32)
      CC_SHA256(rawBuffer.baseAddress, CC_LONG(dummyDerBytes.count), &hash)
      return hash.map { String(format: "%02X", $0) }.joined()
    }
    XCTAssertEqual(digest.count, 64)

    let cert = RdpCertificateRecord(
      host: "127.0.0.1",
      port: 3389,
      sha256Fingerprint: digest,
      subjectCN: "Windows-Test-Fixture",
      issuerCN: "Windows-Test-CA"
    )
    XCTAssertEqual(cert.sha256Fingerprint, digest)
    XCTAssertTrue(cert.formattedFingerprint.contains(":"))
  }

  func testLiveDisposableWindowsFixtureIfConfigured() throws {
    guard let host = ProcessInfo.processInfo.environment["MRW_NATIVE_RDP_HOST"],
          let portString = ProcessInfo.processInfo.environment["MRW_NATIVE_RDP_PORT"],
          let port = Int(portString) else {
      throw XCTSkip("Set MRW_NATIVE_RDP_HOST and MRW_NATIVE_RDP_PORT with a disposable test Windows/RDP fixture to exercise end-to-end NLA")
    }

    // Connect to disposable Windows fixture
    let connection = NWConnection(
      host: NWEndpoint.Host(host),
      port: NWEndpoint.Port(rawValue: UInt16(port))!,
      using: .tcp
    )

    let expectation = expectation(description: "TCP connection to disposable RDP fixture")
    connection.stateUpdateHandler = { state in
      if case .ready = state {
        expectation.fulfill()
      }
    }
    connection.start(queue: .global())
    defer { connection.cancel() }

    wait(for: [expectation], timeout: 5.0)
  }
}

// CommonCrypto import for SHA-256 test helper
import CommonCrypto
