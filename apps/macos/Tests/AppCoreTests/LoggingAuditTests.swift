import Foundation
import XCTest
@testable import AppCore

/// FR-013: lifecycle audit events exist and carry no secrets.
final class LoggingAuditTests: XCTestCase {
  private let canary = "CANARY-SECRET-7f3a"

  private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
  }

  func testHostKeyTrustAndRemovalAreAudited() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mrw-audit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: dir) }
    let events = Events()
    let service = NativeSSHHostTrustService(
      knownHostsFileURL: dir.appendingPathComponent("known_hosts"),
      audit: { action, entity, outcome, _ in events.add("\(action)|\(entity)|\(outcome.rawValue)") })
    func challenge(_ b64: String) -> SSHHostTrustChallenge {
      SSHHostTrustChallenge(host: "127.0.0.1", port: 22, presentedKey: SSHHostKeyRecord(
        rawLine: "127.0.0.1 ssh-ed25519 \(b64)", keyType: "ssh-ed25519", keyBase64: b64,
        algorithm: "ED25519", fingerprintSHA256: "SHA256:x"))
    }
    let good = "AAAAC3NzaC1lZDI1NTE5AAAAIBw4ONu6jpEcSxnYb0tUI3tpRYIW8gGvrYcg1Ps1dyUj"
    try service.approveChallenge(challenge(good), expectedHost: "127.0.0.1", expectedPort: 22)
    XCTAssertEqual(events.all, ["ssh.hostkey.trusted|127.0.0.1:22|success"])

    XCTAssertThrowsError(try service.approveChallenge(
      challenge("AAAAC3NzaC1lZDI1NTE5AAAAIBw4ONu6jpEcSxnYb0tUI3tpRYIW8gGvrYcg1Ps1dyUa"),
      expectedHost: "127.0.0.1", expectedPort: 22))
    XCTAssertEqual(events.all.last, "ssh.hostkey.rejected|127.0.0.1:22|failure")

    let entry = try XCTUnwrap(try service.loadAllKnownHosts().first)
    try service.removeKnownHostEntry(entry)
    XCTAssertTrue(events.all.last?.hasPrefix("ssh.hostkey.removed|") == true)
  }

  func testCredentialAuditAndLogsContainNoSecret() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mrw-audit-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let repo = try SQLiteHostRepository(databaseURL: url)
    defer { try? repo.close() }
    let ref = KeychainCredentialStore.freshReference()
    let rec = try repo.createCredentialRef(label: "audit-test", kind: .keyPassphrase, keychainItemID: ref.encoded)
    try repo.deleteCredentialRef(id: rec.id)

    RedactedLogger.shared.error("credential", "failed password=\(canary)")
    let events = try repo.listAuditEvents(limit: 20)
    XCTAssertEqual(Set(events.map(\.action)), ["credential.create", "credential.delete"])
    let dump = events.map { "\($0.action)\($0.entityID ?? "")\($0.errorCode ?? "")" }.joined()
    XCTAssertFalse(dump.contains(canary))
    XCTAssertFalse(dump.contains(ref.encoded))
    XCTAssertFalse(RedactedLogger.shared.recentEntries().map(\.message).joined().contains(canary))
  }

  func testRdpCertTrustAndMismatchAreAudited() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mrw-audit-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let repo = try SQLiteHostRepository(databaseURL: url)
    defer { try? repo.close() }
    let service = NativeRdpCertificateTrustService(repository: repo)
    func cert(_ c: String) -> RdpCertificateRecord {
      RdpCertificateRecord(host: "rdp.example.com", port: 3389,
        sha256Fingerprint: String(repeating: c, count: 64), subjectCN: "s", issuerCN: "i")
    }
    guard case .unknown(let challenge) = try await service.evaluateTrust(
      host: "rdp.example.com", port: 3389, presented: cert("A")) else { return XCTFail("expected unknown") }
    try await service.approveChallenge(challenge)
    guard case .mismatch = try await service.evaluateTrust(
      host: "rdp.example.com", port: 3389, presented: cert("B")) else { return XCTFail("expected mismatch") }
    let actions = try repo.listAuditEvents(limit: 10).map(\.action)
    XCTAssertTrue(actions.contains("rdp.cert.trusted"))
    XCTAssertTrue(actions.contains("rdp.cert.rejected"))
  }
}
