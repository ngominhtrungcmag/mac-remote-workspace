import Darwin
import Foundation
import XCTest

@testable import AppCore

/// Security/negative tests for the app <-> RdpSessionHelper boundary. Fake helpers are shell scripts;
/// no Windows host or real FreeRDP session is involved.
final class RdpHelperSecurityTests: XCTestCase {
  private static let canary = "CANARY-\(UUID().uuidString)"
  private static let cert = RdpCertificateRecord(
    host: "windows.example", port: 3389, sha256Fingerprint: String(repeating: "AB", count: 32),
    subjectCN: "s", issuerCN: "i")

  private struct Fixture {
    let dir: URL
    var script: URL { dir.appendingPathComponent("fake-helper") }
    var stdinLog: String { (try? String(decoding: Data(contentsOf: dir.appendingPathComponent("stdin.log")), as: UTF8.self)) ?? "" }
    func read(_ name: String) -> String { (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? "" }
  }

  /// `body` is shell run after the helper logs argv/env and starts copying its stdin to stdin.log.
  private func makeFixture(_ body: String) throws -> Fixture {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rdp-sec-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    try RdpHelperMessage.certificate(
      host: "windows.example", port: 3389, sha256: Self.cert.sha256Fingerprint, subjectCN: "s", issuerCN: "i",
      changed: false).encoded().write(to: dir.appendingPathComponent("cert"))
    try RdpHelperMessage.connected.encoded().write(to: dir.appendingPathComponent("connected"))
    try RdpHelperMessage.ended(code: 1, message: "x", connected: false).encoded().write(to: dir.appendingPathComponent("ended"))
    let text = """
      #!/bin/sh
      D='\(dir.path)'
      echo "argc=$# argv=$*" > "$D/argv"
      /usr/bin/env > "$D/env"
      /bin/cat <&0 >> "$D/stdin.log" &
      \(body)
      """
    try text.write(to: dir.appendingPathComponent("fake-helper"), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("fake-helper").path)
    return Fixture(dir: dir)
  }

  private func waitFor(_ timeout: TimeInterval = 8, _ condition: () -> Bool) async throws {
    let end = Date().addingTimeInterval(timeout)
    while !condition() && Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
  }

  private func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

  private func makeSession(
    _ f: Fixture, verifier: RdpHostCertificateVerifier, resolver: RdpCredentialResolving
  ) -> NativeRdpSession {
    NativeRdpSession(
      configuration: RdpSessionConfiguration(host: "windows.example", username: "u", credentialRefID: "ref"),
      certificateVerifier: verifier, credentialResolver: resolver, helperURL: f.script)
  }

  // MARK: trust round trip

  func testUnknownCertificateWaitsForUserAndSecretOnlyTravelsAfterAcceptance() async throws {
    let f = try makeFixture(
      "/bin/cat \"$D/cert\"\nuntil /usr/bin/grep -q CANARY \"$D/stdin.log\"; do /bin/sleep 0.1; done\n/bin/cat \"$D/connected\"\nexec /bin/sleep 60")
    let resolver = CanaryResolver(password: Self.canary)
    let session = makeSession(f, verifier: StubVerifier(status: .unknown(challenge: .init(host: "windows.example", port: 3389, presentedCertificate: Self.cert))), resolver: resolver)
    try await session.connect()  // returns at the pending trust prompt
    guard case .verifyingCertificate = session.state else { return XCTFail("\(session.state)") }
    let pid = try XCTUnwrap(session.helperProcessIdentifier)

    // before the user accepts: no credential lookup, nothing secret on the wire
    XCTAssertEqual(resolver.calls, 0)
    XCTAssertFalse(f.stdinLog.contains(Self.canary))

    try await session.confirmTrustAndAuthenticate()
    XCTAssertEqual(session.state, .connected)
    XCTAssertTrue(f.stdinLog.contains(Self.canary), "credentials reach the helper over the socket")

    // never via argv, env, or the process table
    XCTAssertTrue(f.read("argv").hasPrefix("argc=0"), f.read("argv"))
    XCTAssertFalse(f.read("env").contains(Self.canary))
    XCTAssertFalse(psCommand(pid).contains(Self.canary))
    XCTAssertFalse("\(RdpResolvedCredentials(username: "u", domain: nil, password: Self.canary))".contains(Self.canary))
    await session.disconnect()
  }

  func testRejectingUnknownCertificateAbortsBeforeAuthAndKillsHelper() async throws {
    let f = try makeFixture("/bin/cat \"$D/cert\"\nexec /bin/sleep 60")
    let resolver = CanaryResolver(password: Self.canary)
    let session = makeSession(f, verifier: StubVerifier(status: .unknown(challenge: .init(host: "windows.example", port: 3389, presentedCertificate: Self.cert))), resolver: resolver)
    try await session.connect()
    let pid = try XCTUnwrap(session.helperProcessIdentifier)
    session.rejectCertificate()
    XCTAssertEqual(session.state, .disconnected(reason: .certificateRejected))
    try await waitFor(12) { !isAlive(pid) }
    XCTAssertFalse(isAlive(pid), "helper must not outlive a rejected session")
    XCTAssertEqual(resolver.calls, 0)
    XCTAssertFalse(f.stdinLog.contains(Self.canary))
  }

  func testCertificateMismatchBlocksWithoutCredentials() async throws {
    let f = try makeFixture("/bin/cat \"$D/cert\"\n/bin/sleep 0.5\n/bin/cat \"$D/ended\"\nexec /bin/sleep 60")
    let other = RdpCertificateRecord(host: "windows.example", port: 3389, sha256Fingerprint: String(repeating: "CD", count: 32), subjectCN: "s", issuerCN: "i")
    let resolver = CanaryResolver(password: Self.canary)
    let session = makeSession(f, verifier: StubVerifier(status: .mismatch(recorded: Self.cert, presented: other)), resolver: resolver)
    do {
      try await session.connect()
      XCTFail("mismatch must not connect")
    } catch {
      guard case .certificateMismatch = error as? RdpSessionError else { return XCTFail("\(error)") }
    }
    XCTAssertEqual(resolver.calls, 0)
    XCTAssertFalse(f.stdinLog.contains(Self.canary))
    await session.disconnect()
  }

  func testChangedCertificateFlagBlocksWithoutVerifierOrCredentials() async throws {
    let f = try makeFixture("/bin/cat \"$D/cert\"\n/bin/sleep 0.5\n/bin/cat \"$D/ended\"\nexec /bin/sleep 60")
    try RdpHelperMessage.certificate(
      host: "windows.example", port: 3389, sha256: Self.cert.sha256Fingerprint, subjectCN: "s", issuerCN: "i",
      changed: true).encoded().write(to: f.dir.appendingPathComponent("cert"))
    let resolver = CanaryResolver(password: Self.canary)
    let session = makeSession(f, verifier: UnusedCertificateVerifier(), resolver: resolver)
    do {
      try await session.connect()
      XCTFail("changed cert must not connect")
    } catch {
      guard case .certificateMismatch = error as? RdpSessionError else { return XCTFail("\(error)") }
    }
    XCTAssertEqual(resolver.calls, 0)
    XCTAssertFalse(f.stdinLog.contains(Self.canary))
    await session.disconnect()
  }

  // MARK: lifecycle / crash

  func testDisconnectLeavesNoOrphanHelper() async throws {
    let f = try makeFixture("/bin/cat \"$D/connected\"\nexec /bin/sleep 60")
    let session = makeSession(f, verifier: UnusedCertificateVerifier(), resolver: UnusedCredentialResolver())
    try await session.connect()
    let pid = try XCTUnwrap(session.helperProcessIdentifier)
    await session.disconnect()
    try await waitFor(12) { !isAlive(pid) }
    XCTAssertFalse(isAlive(pid))
    XCTAssertEqual(session.state, .disconnected(reason: .userInitiated))
  }

  func testDroppingSessionKillsHelper() async throws {
    let f = try makeFixture("/bin/cat \"$D/connected\"\nexec /bin/sleep 60")
    var session: NativeRdpSession? = makeSession(f, verifier: UnusedCertificateVerifier(), resolver: UnusedCredentialResolver())
    try await session!.connect()
    let pid = try XCTUnwrap(session!.helperProcessIdentifier)
    session = nil
    try await waitFor(12) { !isAlive(pid) }
    XCTAssertFalse(isAlive(pid))
  }

  func testGarbageFromHelperIsTreatedAsCrash() async throws {
    // valid `connected`, then a frame header claiming an absurd length
    let f = try makeFixture("/bin/cat \"$D/connected\"\nprintf '\\377\\377\\377\\377'\nexec /bin/sleep 60")
    let session = makeSession(f, verifier: UnusedCertificateVerifier(), resolver: UnusedCredentialResolver())
    try await session.connect()
    try await waitFor { session.state != .connected }
    XCTAssertEqual(session.state, .disconnected(reason: .helperCrashed))
    if let pid = session.helperProcessIdentifier { XCTAssertFalse(isAlive(pid)) }
  }

  func testHelperIgnoringAbortIsHardKilled() async throws {
    let f = try makeFixture("trap '' TERM\n/bin/cat \"$D/connected\"\nwhile :; do /bin/sleep 1; done")
    let session = makeSession(f, verifier: UnusedCertificateVerifier(), resolver: UnusedCredentialResolver())
    try await session.connect()
    let start = Date()
    await session.disconnect()  // must return (bounded wait), not hang the UI
    XCTAssertLessThan(Date().timeIntervalSince(start), 8)
  }

  // MARK: malformed messages

  func testMalformedMessagesAreRejected() throws {
    var fds: [Int32] = [0, 0]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
    let reader = RdpHelperChannel(fd: fds[0])
    let raw = RdpHelperChannel(fd: fds[1])
    _ = raw
    func inject(_ bytes: [UInt8]) {
      bytes.withUnsafeBytes { _ = Darwin.write(fds[1], $0.baseAddress!, $0.count) }
    }
    inject([0xFF, 0xFF, 0xFF, 0xFF])  // oversize
    XCTAssertThrowsError(try reader.receive()) { XCTAssertEqual($0 as? RdpHelperProtocolError, .tooLarge) }
    inject([0, 0, 0, 0])  // zero length
    XCTAssertThrowsError(try reader.receive())
    inject([0, 0, 0, 3, 0, 0x7B, 0x7B])  // tag 0 with invalid JSON
    XCTAssertThrowsError(try reader.receive())
    // frame whose pixel count disagrees with its header
    var frame: [UInt8] = [1, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 8, 1, 2, 3]
    frame.insert(contentsOf: [0, 0, 0, UInt8(frame.count)], at: 0)
    inject(frame)
    XCTAssertThrowsError(try reader.receive())
    // huge dimensions must not overflow or allocate
    inject([0, 0, 0, 13, 1, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    XCTAssertThrowsError(try reader.receive())
    // truncated body then EOF = nil (peer gone), not a crash
    inject([0, 0, 0, 50, 0, 1])
    raw.close()
    XCTAssertNil(try reader.receive())
  }

  /// Real helper binary: a bad first message makes it exit(2) instead of hanging or crashing.
  func testRealHelperExitsOnMalformedFirstMessage() throws {
    let url = try XCTUnwrap(RdpHelperProcess.defaultHelperURL())
    var fds: [Int32] = [0, 0]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
    let child = FileHandle(fileDescriptor: fds[1], closeOnDealloc: false)
    let p = Process()
    p.executableURL = url
    p.environment = [:]
    p.standardInput = child
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    Darwin.close(fds[1])
    let channel = RdpHelperChannel(fd: fds[0])
    channel.send(.abort)  // not `start`
    let exited = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { p.waitUntilExit(); exited.signal() }
    if exited.wait(timeout: .now() + 10) != .success { p.terminate(); XCTFail("helper hung") }
    XCTAssertEqual(p.terminationStatus, 2)
    channel.close()
  }

  /// Real helper exits when the app side of the socket goes away (app crash) -> no orphan.
  func testRealHelperExitsWhenParentSocketCloses() throws {
    let url = try XCTUnwrap(RdpHelperProcess.defaultHelperURL())
    var fds: [Int32] = [0, 0]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
    let child = FileHandle(fileDescriptor: fds[1], closeOnDealloc: false)
    let p = Process()
    p.executableURL = url
    p.environment = [:]
    p.standardInput = child
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    Darwin.close(fds[1])
    let channel = RdpHelperChannel(fd: fds[0])
    // 192.0.2.1 (TEST-NET-1) never answers: helper stays in connect until we vanish
    channel.send(.start(host: "192.0.2.1", port: 3389, width: 800, height: 600, scaleFactor: 100))
    Thread.sleep(forTimeInterval: 0.5)
    channel.close()
    let exited = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { p.waitUntilExit(); exited.signal() }
    if exited.wait(timeout: .now() + 15) != .success { p.terminate(); XCTFail("helper outlived the app socket") }
  }

  private func psCommand(_ pid: Int32) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-ww", "-o", "command=", "-p", "\(pid)"]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
  }
}

private struct StubVerifier: RdpHostCertificateVerifier {
  let status: RdpHostTrustStatus
  func evaluateTrust(host: String, port: Int, presented: RdpCertificateRecord) async throws -> RdpHostTrustStatus { status }
  func approveChallenge(_ challenge: RdpCertificateTrustChallenge) async throws {}
  func revokeTrust(host: String, port: Int) async throws {}
  func listTrustedCertificates() async throws -> [RdpCertificateRecord] { [] }
}

private final class CanaryResolver: RdpCredentialResolving, @unchecked Sendable {
  let password: String
  private let lock = NSLock()
  private var _calls = 0
  var calls: Int { lock.withLock { _calls } }
  init(password: String) { self.password = password }
  func resolveCredentials(rawUsername: String, credentialRefID: String?) throws -> RdpResolvedCredentials {
    lock.withLock { _calls += 1 }
    return RdpResolvedCredentials(username: "user", domain: nil, password: password)
  }
  func parseUsernameAndDomain(from raw: String) -> (username: String, domain: String?) { (raw, nil) }
}
