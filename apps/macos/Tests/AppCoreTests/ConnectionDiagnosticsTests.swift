import Darwin
import Foundation
import XCTest
@testable import AppCore

final class ConnectionDiagnosticsTests: XCTestCase {
  func testReportsDNSFailureAndSkipsLaterStages() {
    let report = SSHConnectionDiagnosticProbe.run(host: "mrw-no-such-host.invalid", port: 22)

    XCTAssertEqual(report.dnsResolution.status, .failed(.dnsResolutionFailed))
    XCTAssertEqual(report.tcpConnection.status, .skipped)
    XCTAssertEqual(report.sshHandshake.status, .skipped)
  }

  func testReportsTCPRefusalAfterDNSResolves() throws {
    let port = try unusedLoopbackPort()
    let report = SSHConnectionDiagnosticProbe.run(host: "127.0.0.1", port: port)

    XCTAssertEqual(report.dnsResolution.status, .succeeded)
    XCTAssertEqual(report.tcpConnection.status, .failed(.tcpConnectionRefused))
    XCTAssertEqual(report.sshHandshake.status, .skipped)
  }

  func testReportsSSHHandshakeFailureWhenTCPServiceIsNotSSH() throws {
    let server = try LoopbackListener()
    let accepted = expectation(description: "non-SSH TCP client accepted")
    DispatchQueue.global().async {
      server.acceptAndCloseOnce()
      accepted.fulfill()
    }

    let report = SSHConnectionDiagnosticProbe.run(host: "127.0.0.1", port: server.port)

    XCTAssertEqual(report.dnsResolution.status, .succeeded)
    XCTAssertEqual(report.tcpConnection.status, .succeeded)
    XCTAssertEqual(report.sshHandshake.status, .failed(.sshHandshakeFailed))
    wait(for: [accepted], timeout: 2)
  }

  func testProbesDisposableSSHFixtureWithoutChangingKnownHosts() throws {
    guard let host = ProcessInfo.processInfo.environment["MRW_NATIVE_SSH_HOST"],
          let portString = ProcessInfo.processInfo.environment["MRW_NATIVE_SSH_PORT"],
          let port = Int(portString),
          let fixtureRoot = ProcessInfo.processInfo.environment["MRW_NATIVE_FIXTURE_ROOT"] else {
      throw XCTSkip("Run apps/macos/run-ssh-fixture.sh to exercise the disposable SSH server")
    }

    let knownHostsURL = URL(fileURLWithPath: fixtureRoot).appendingPathComponent("known_hosts")
    let before = try Data(contentsOf: knownHostsURL)
    let report = SSHConnectionDiagnosticProbe.run(host: host, port: port)

    XCTAssertEqual(report.dnsResolution.status, .succeeded)
    XCTAssertEqual(report.tcpConnection.status, .succeeded)
    XCTAssertEqual(report.sshHandshake.status, .succeeded)
    XCTAssertEqual(try Data(contentsOf: knownHostsURL), before)
  }

  private func unusedLoopbackPort() throws -> Int {
    let listener = try LoopbackListener()
    let port = listener.port
    listener.close()
    return port
  }
}

private final class LoopbackListener: @unchecked Sendable {
  private var descriptor: Int32 = -1
  private(set) var port = 0

  init() throws {
    descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let bindResult = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else {
      close()
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }

    var boundAddress = sockaddr_in()
    var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &boundAddress) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(descriptor, $0, &addressLength)
      }
    }
    guard nameResult == 0 else {
      close()
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    port = Int(UInt16(bigEndian: boundAddress.sin_port))

    guard Darwin.listen(descriptor, 1) == 0 else {
      close()
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
  }

  func acceptAndCloseOnce() {
    let client = Darwin.accept(descriptor, nil, nil)
    if client >= 0 { Darwin.close(client) }
  }

  func close() {
    guard descriptor >= 0 else { return }
    Darwin.close(descriptor)
    descriptor = -1
  }

  deinit { close() }
}
