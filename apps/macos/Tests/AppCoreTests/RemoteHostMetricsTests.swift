import XCTest
@testable import AppCore

final class RemoteHostMetricsTests: XCTestCase {
  private let linux = """
    OS=Linux
    LOAD=0.52 0.38 0.30
    UPTIME=351735.47
    MemTotal:       16314356 kB
    MemAvailable:   11874520 kB
    DF=/dev/nvme0n1p2 487652284 201345120 261608020 44% /
    """

  private let darwin = """
    OS=Darwin
    LOAD= 1.85 2.10 2.35
    UPTIME=86461
    MEMTOTAL=17179869184
    Mach Virtual Memory Statistics: (page size of 16384 bytes)
    Pages free:                               12000.
    Pages active:                            400000.
    Pages inactive:                          380000.
    Pages speculative:                         8000.
    DF=/dev/disk3s1s1 971350180 15034912 421118804 4% /
    """

  func testParsesLinux() throws {
    let m = try RemoteHostMetricsParser.parse(linux)
    XCTAssertEqual(m.operatingSystem, "Linux")
    XCTAssertEqual(m.load5, 0.38)
    XCTAssertEqual(m.uptimeSeconds, 351735)
    XCTAssertEqual(m.memoryTotalBytes, 16_314_356 * 1024)
    XCTAssertEqual(m.memoryAvailableBytes, 11_874_520 * 1024)
    XCTAssertEqual(m.diskTotalBytes, 487_652_284 * 1024)
    XCTAssertEqual(m.diskUsedBytes, 201_345_120 * 1024)
    XCTAssertEqual(m.memoryUsedFraction, 1 - 11_874_520.0 / 16_314_356.0, accuracy: 1e-9)
  }

  func testParsesDarwin() throws {
    let m = try RemoteHostMetricsParser.parse(darwin)
    XCTAssertEqual(m.operatingSystem, "Darwin")
    XCTAssertEqual(m.load1, 1.85)
    XCTAssertEqual(m.memoryTotalBytes, 17_179_869_184)
    XCTAssertEqual(m.memoryAvailableBytes, (12000 + 380000 + 8000) * 16384)
  }

  func testRejectsMalformedOutput() {
    let bad = [
      "",
      "garbage\nmore garbage",
      linux.replacingOccurrences(of: "LOAD=0.52 0.38 0.30", with: "LOAD=abc"),
      linux.replacingOccurrences(of: "UPTIME=351735.47", with: "UPTIME=-5"),
      linux.replacingOccurrences(of: "MemAvailable:   11874520 kB", with: ""),
      linux.replacingOccurrences(of: "MemTotal:       16314356 kB", with: "MemTotal: 0 kB"),
      linux.replacingOccurrences(of: "201345120", with: "999999999999"),
      linux.replacingOccurrences(of: "DF=/dev/nvme0n1p2 487652284 201345120 261608020 44% /", with: "DF=short"),
      darwin.replacingOccurrences(of: "Pages free:                               12000.", with: ""),
    ]
    for output in bad {
      XCTAssertThrowsError(try RemoteHostMetricsParser.parse(output), output) {
        XCTAssertTrue($0 is RemoteHostMetricsError)
      }
    }
  }

  func testRejectsUnsupportedOS() {
    XCTAssertThrowsError(try RemoteHostMetricsParser.parse(linux.replacingOccurrences(of: "OS=Linux", with: "OS=FreeBSD"))) {
      XCTAssertEqual($0 as? RemoteHostMetricsError, .unsupportedOperatingSystem("FreeBSD"))
    }
  }

  func testCommandIsFixedReadOnlyAndShellSafe() {
    let c = RemoteHostMetricsParser.command
    XCTAssertTrue(c.hasPrefix("/bin/sh -c '"))
    XCTAssertEqual(c.dropFirst(12).dropLast().contains("'"), false)
    for forbidden in ["sudo", "rm ", ">", "curl", "wget", "tee"] {
      XCTAssertFalse(c.contains(forbidden), forbidden)
    }
  }

  /// Runs the real fixed command locally (this Mac acts as the "remote") and parses its output.
  func testCommandOutputParsesOnThisHost() throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", RemoteHostMetricsParser.command]
    let pipe = Pipe()
    p.standardOutput = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    XCTAssertEqual(p.terminationStatus, 0)
    let m = try RemoteHostMetricsParser.parse(String(decoding: data, as: UTF8.self))
    XCTAssertGreaterThan(m.memoryTotalBytes, 0)
    XCTAssertGreaterThan(m.uptimeSeconds, 0)
  }

  func testArgumentsUseStrictTrustAndNoPTY() throws {
    let hosts = FileManager.default.temporaryDirectory.appendingPathComponent("mrw-metrics-kh-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: hosts.path, contents: Data())
    defer { try? FileManager.default.removeItem(at: hosts) }
    let config = NativeSSHConfiguration(
      host: "h.example.net", port: 2222, username: "u", knownHostsFileURL: hosts,
      authentication: .identityFile(hosts))
    let args = NativeSSHSession.buildMetricsSSHArguments(for: config)
    XCTAssertTrue(args.contains("StrictHostKeyChecking=yes"))
    XCTAssertTrue(args.contains("-T"))
    XCTAssertFalse(args.contains("-tt"))
    XCTAssertFalse(args.joined(separator: " ").contains("StrictHostKeyChecking=no"))
    XCTAssertEqual(args.suffix(2).first, "u@h.example.net")
    XCTAssertEqual(args.last, RemoteHostMetricsParser.command)
  }

  func testTrustFailureAbortsWithoutParsing() {
    let err = NativeSSHMetricsClient.classify(stderr: "Host key verification failed.\n", status: 255)
    guard case NativeSSHError.hostVerificationFailed = err else { return XCTFail("\(err)") }
    let changed = NativeSSHMetricsClient.classify(
      stderr: "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!\nHost key verification failed.", status: 255)
    guard case NativeSSHError.hostVerificationFailed = changed else { return XCTFail("\(changed)") }
  }

  func testClientRefusesProxyJump() throws {
    let hosts = FileManager.default.temporaryDirectory.appendingPathComponent("mrw-metrics-kh-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: hosts.path, contents: Data())
    defer { try? FileManager.default.removeItem(at: hosts) }
    let config = NativeSSHConfiguration(
      host: "h.example.net", username: "u", knownHostsFileURL: hosts, authentication: .identityFile(hosts),
      proxyJump: NativeSSHProxyJumpEndpoint(host: "j.example.net", port: 22, username: "r"))
    XCTAssertThrowsError(try NativeSSHMetricsClient(configuration: config))
  }
}
