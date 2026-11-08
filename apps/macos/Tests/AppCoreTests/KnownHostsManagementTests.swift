import Darwin
import Foundation
import XCTest
@testable import AppCore

final class KnownHostsManagementTests: XCTestCase {
  private var tempDir: URL!
  private var knownHostsFile: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("mrw-knownhosts-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    tempDir = base
    knownHostsFile = base.appendingPathComponent("known_hosts")
  }

  override func tearDownWithError() throws {
    if let dir = tempDir {
      try? FileManager.default.removeItem(at: dir)
    }
    try super.tearDownWithError()
  }

  private func generateEd25519KeyLine(host: String) throws -> String {
    let keyPath = tempDir.appendingPathComponent("id_\(UUID().uuidString)")
    let gen = Process()
    gen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    gen.arguments = ["-q", "-N", "", "-t", "ed25519", "-f", keyPath.path]
    try gen.run()
    gen.waitUntilExit()
    guard gen.terminationStatus == 0 else {
      throw XCTSkip("ssh-keygen unavailable")
    }
    let pubData = try Data(contentsOf: URL(fileURLWithPath: keyPath.path + ".pub"))
    let pubStr = String(decoding: pubData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = pubStr.split(separator: " ")
    guard parts.count >= 2 else { throw XCTSkip("malformed pub key") }
    return "\(host) \(parts[0]) \(parts[1])"
  }

  func testLoadAllKnownHostsReturnsEmptyWhenFileMissing() throws {
    let service = NativeSSHHostTrustService(knownHostsFileURL: knownHostsFile)
    let entries = try service.loadAllKnownHosts()
    XCTAssertTrue(entries.isEmpty)
  }

  func testLoadAllKnownHostsParsesMultipleEntriesAndSkipsComments() throws {
    let line1 = try generateEd25519KeyLine(host: "example.com")
    let line2 = try generateEd25519KeyLine(host: "[127.0.0.1]:2222")

    let content = """
    # This is a known_hosts header comment

    \(line1) test-comment-1
    # Another comment in between
    \(line2)

    """
    try content.write(to: knownHostsFile, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHostsFile.path)

    let service = NativeSSHHostTrustService(knownHostsFileURL: knownHostsFile)
    let entries = try service.loadAllKnownHosts()

    XCTAssertEqual(entries.count, 2)
    XCTAssertEqual(entries[0].hostPattern, "example.com")
    XCTAssertEqual(entries[0].keyRecord.algorithm.uppercased(), "ED25519")
    XCTAssertTrue(entries[0].keyRecord.fingerprintSHA256.starts(with: "SHA256:"))
    XCTAssertEqual(entries[0].keyRecord.comment, "test-comment-1")

    XCTAssertEqual(entries[1].hostPattern, "[127.0.0.1]:2222")
    XCTAssertEqual(entries[1].keyRecord.algorithm.uppercased(), "ED25519")
  }

  func testRemoveKnownHostEntryRemovesTargetAndPreservesOthers() throws {
    let line1 = try generateEd25519KeyLine(host: "host1.local")
    let line2 = try generateEd25519KeyLine(host: "host2.local")
    let line3 = try generateEd25519KeyLine(host: "host3.local")

    let content = "\(line1)\n\(line2)\n\(line3)\n"
    try content.write(to: knownHostsFile, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHostsFile.path)

    let service = NativeSSHHostTrustService(knownHostsFileURL: knownHostsFile)
    var entries = try service.loadAllKnownHosts()
    XCTAssertEqual(entries.count, 3)

    let entryToRemove = entries[1]
    XCTAssertEqual(entryToRemove.hostPattern, "host2.local")

    try service.removeKnownHostEntry(entryToRemove)

    entries = try service.loadAllKnownHosts()
    XCTAssertEqual(entries.count, 2)
    XCTAssertEqual(entries[0].hostPattern, "host1.local")
    XCTAssertEqual(entries[1].hostPattern, "host3.local")

    // Check file permissions remain 0600
    var st = stat()
    XCTAssertEqual(stat(knownHostsFile.path, &st), 0)
    XCTAssertEqual(st.st_mode & 0o777, 0o600)
  }

  func testRemoveKnownHostEntryFailsGracefullyOnUnsafeDirectory() throws {
    let line1 = try generateEd25519KeyLine(host: "unsafe.local")
    try "\(line1)\n".write(to: knownHostsFile, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHostsFile.path)

    let service = NativeSSHHostTrustService(knownHostsFileURL: knownHostsFile)
    let entries = try service.loadAllKnownHosts()
    XCTAssertEqual(entries.count, 1)

    // Make parent directory world-writable, which must fail closed under openSecureKnownHostsFile
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: tempDir.path)

    XCTAssertThrowsError(try service.removeKnownHostEntry(entries[0])) { error in
      guard case SSHHostTrustError.knownHostsFileUnwritable = error else {
        XCTFail("Expected knownHostsFileUnwritable but got \(error)")
        return
      }
    }
  }
}
