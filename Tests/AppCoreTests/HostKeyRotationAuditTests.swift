import Darwin
import Foundation
import XCTest
@testable import AppCore

/// docs/09-security §4 / FR-006 / FR-013: explicit host-key rotation is audited; mismatch stays fail-closed.
final class HostKeyRotationAuditTests: XCTestCase {
  private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(action: String, entity: String)] = []
    func add(_ a: String, _ e: String) { lock.lock(); items.append((a, e)); lock.unlock() }
    var all: [(action: String, entity: String)] { lock.lock(); defer { lock.unlock() }; return items }
    func count(_ action: String) -> Int { all.filter { $0.action == action }.count }
  }

  private var dir: URL!
  private var file: URL!
  private var events: Events!
  private var service: NativeSSHHostTrustService!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("mrw-rotate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    file = dir.appendingPathComponent("known_hosts")
    events = Events()
    let sink = events!
    service = NativeSSHHostTrustService(knownHostsFileURL: file, audit: { action, entity, _, _ in sink.add(action, entity) })
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  private func makeKey() throws -> SSHHostKeyRecord {
    let keyPath = dir.appendingPathComponent("id_\(UUID().uuidString)")
    let gen = Process()
    gen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    gen.arguments = ["-q", "-N", "", "-t", "ed25519", "-f", keyPath.path]
    try gen.run()
    gen.waitUntilExit()
    guard gen.terminationStatus == 0 else { throw XCTSkip("ssh-keygen unavailable") }
    let pub = try String(contentsOfFile: keyPath.path + ".pub", encoding: .utf8)
    let parts = pub.split(whereSeparator: { $0.isWhitespace })
    return try service.parseHostKeyLine("127.0.0.1 \(parts[0]) \(parts[1])")
  }

  private func challenge(_ key: SSHHostKeyRecord) -> SSHHostTrustChallenge {
    SSHHostTrustChallenge(host: "127.0.0.1", port: 22, presentedKey: key)
  }

  func testRotationEmitsOneRotatedEventAndReplacesKey() throws {
    let oldKey = try makeKey()
    let newKey = try makeKey()
    try service.approveChallenge(challenge(oldKey), expectedHost: "127.0.0.1", expectedPort: 22)

    try service.rotateKnownHostKey(challenge(newKey), expectedHost: "127.0.0.1", expectedPort: 22)

    let rotated = events.all.filter { $0.action == "ssh.hostkey.rotated" }
    XCTAssertEqual(rotated.count, 1)
    XCTAssertEqual(
      rotated.first?.entity,
      "127.0.0.1:22 old=\(oldKey.fingerprintSHA256) new=\(newKey.fingerprintSHA256)")

    let recorded = try service.queryRecordedKeys(host: "127.0.0.1", port: 22)
    XCTAssertEqual(recorded.map(\.keyBase64), [newKey.keyBase64])
    // Old key no longer trusted: approving it again is now a blocked mismatch.
    XCTAssertThrowsError(try service.approveChallenge(challenge(oldKey), expectedHost: "127.0.0.1", expectedPort: 22))
  }

  func testRotationAtomicallyPreservesOtherHostPatternsAndPermissions() throws {
    let oldKey = try makeKey()
    let newKey = try makeKey()
    let original = "# preserved\n127.0.0.1,other.example \(oldKey.keyType) \(oldKey.keyBase64)\n"
    try Data(original.utf8).write(to: file)
    let oldFD = open(file.path, O_RDONLY)
    XCTAssertGreaterThanOrEqual(oldFD, 0)
    defer { close(oldFD) }
    try service.rotateKnownHostKey(challenge(newKey), expectedHost: "127.0.0.1", expectedPort: 22)
    let result = try String(contentsOf: file, encoding: .utf8)
    XCTAssertTrue(result.contains("# preserved\nother.example \(oldKey.keyType) \(oldKey.keyBase64)\n"))
    XCTAssertEqual(try service.queryRecordedKeys(host: "other.example", port: 22).map(\.keyBase64), [oldKey.keyBase64])
    XCTAssertEqual(try service.queryRecordedKeys(host: "127.0.0.1", port: 22).map(\.keyBase64), [newKey.keyBase64])
    let oldContents = FileHandle(fileDescriptor: oldFD, closeOnDealloc: false).readDataToEndOfFile()
    XCTAssertEqual(String(data: oldContents, encoding: .utf8), original)
    for path in [file.path, file.path + ".mrw.lock"] {
      let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
      XCTAssertEqual(mode.intValue & 0o777, 0o600)
    }
  }

  func testRotationRemovesDuplicateHostPatterns() throws {
    let oldKey = try makeKey()
    let newKey = try makeKey()
    try Data("127.0.0.1,127.0.0.1 \(oldKey.keyType) \(oldKey.keyBase64)\n".utf8).write(to: file)
    try service.rotateKnownHostKey(challenge(newKey), expectedHost: "127.0.0.1", expectedPort: 22)
    XCTAssertEqual(try service.queryRecordedKeys(host: "127.0.0.1", port: 22).map(\.keyBase64), [newKey.keyBase64])
  }

  func testRotationExcludesHostFromRemainingWildcard() throws {
    let oldKey = try makeKey()
    let newKey = try makeKey()
    let line = "127.0.0.1,* \(oldKey.keyType) \(oldKey.keyBase64)\n"
    try Data(line.utf8).write(to: file)
    try service.rotateKnownHostKey(challenge(newKey), expectedHost: "127.0.0.1", expectedPort: 22)
    XCTAssertEqual(try service.queryRecordedKeys(host: "127.0.0.1", port: 22).map(\.keyBase64), [newKey.keyBase64])
    XCTAssertEqual(try service.queryRecordedKeys(host: "other.example", port: 22).map(\.keyBase64), [oldKey.keyBase64])
  }

  func testRotationPreservesOtherHashedEntry() throws {
    let oldKey = try makeKey()
    let newKey = try makeKey()
    let original = "127.0.0.1 \(oldKey.keyType) \(oldKey.keyBase64)\nother.example \(oldKey.keyType) \(oldKey.keyBase64)\n"
    try Data(original.utf8).write(to: file)
    let hash = Process()
    hash.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    hash.arguments = ["-q", "-H", "-f", file.path]
    hash.standardError = FileHandle.nullDevice
    try hash.run()
    hash.waitUntilExit()
    XCTAssertEqual(hash.terminationStatus, 0)
    try service.rotateKnownHostKey(challenge(newKey), expectedHost: "127.0.0.1", expectedPort: 22)
    XCTAssertEqual(try service.queryRecordedKeys(host: "other.example", port: 22).map(\.keyBase64), [oldKey.keyBase64])
    XCTAssertEqual(try service.queryRecordedKeys(host: "127.0.0.1", port: 22).map(\.keyBase64), [newKey.keyBase64])
  }

  func testConcurrentApprovalsPreserveBothEntries() throws {
    let key = try makeKey()
    let hosts = ["first.example", "second.example"]
    let url = file!
    let lock = NSLock()
    nonisolated(unsafe) var errors: [Error] = []
    DispatchQueue.concurrentPerform(iterations: hosts.count) { index in
      do {
        let service = NativeSSHHostTrustService(knownHostsFileURL: url)
        let challenge = SSHHostTrustChallenge(host: hosts[index], port: 22, presentedKey: key)
        try service.approveChallenge(challenge, expectedHost: hosts[index], expectedPort: 22)
      } catch {
        lock.lock(); errors.append(error); lock.unlock()
      }
    }
    XCTAssertTrue(errors.isEmpty, "\(errors)")
    for host in hosts {
      XCTAssertEqual(try service.queryRecordedKeys(host: host, port: 22).map(\.keyBase64), [key.keyBase64])
    }
  }

  func testMismatchWithoutRotationRejectsAndDoesNotRotate() throws {
    let oldKey = try makeKey()
    let newKey = try makeKey()
    try service.approveChallenge(challenge(oldKey), expectedHost: "127.0.0.1", expectedPort: 22)

    XCTAssertThrowsError(try service.approveChallenge(challenge(newKey), expectedHost: "127.0.0.1", expectedPort: 22)) {
      guard case SSHHostTrustError.mismatchBlocked = $0 else { return XCTFail("unexpected \($0)") }
    }
    XCTAssertEqual(events.count("ssh.hostkey.rejected"), 1)
    XCTAssertEqual(events.count("ssh.hostkey.rotated"), 0)
    XCTAssertEqual(try service.queryRecordedKeys(host: "127.0.0.1", port: 22).map(\.keyBase64), [oldKey.keyBase64])
  }

  func testRotationWithoutExistingEntryFailsAndDoesNotEmit() throws {
    let newKey = try makeKey()
    XCTAssertThrowsError(try service.rotateKnownHostKey(challenge(newKey), expectedHost: "127.0.0.1", expectedPort: 22)) {
      guard case SSHHostTrustError.hostKeyNotFound = $0 else { return XCTFail("unexpected \($0)") }
    }
    XCTAssertEqual(events.count("ssh.hostkey.rotated"), 0)
    XCTAssertTrue(try service.queryRecordedKeys(host: "127.0.0.1", port: 22).isEmpty)
  }

  func testRotationToAlreadyTrustedKeyIsRejectedWithoutEvent() throws {
    let key = try makeKey()
    try service.approveChallenge(challenge(key), expectedHost: "127.0.0.1", expectedPort: 22)
    XCTAssertThrowsError(try service.rotateKnownHostKey(challenge(key), expectedHost: "127.0.0.1", expectedPort: 22))
    XCTAssertEqual(events.count("ssh.hostkey.rotated"), 0)
  }
}
