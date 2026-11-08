import AppCore
import XCTest

final class NativeSSHHostTrustTests: XCTestCase {
  private var tempDirectory: URL!

  override func setUp() {
    super.setUp()
    let unique = "mrw_host_trust_tests_\(UUID().uuidString)"
    tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(unique, isDirectory: true)
    try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
  }

  override func tearDown() {
    if let dir = tempDirectory {
      try? FileManager.default.removeItem(at: dir)
    }
    super.tearDown()
  }

  // MARK: - Endpoint Formatting & Validation Tests

  func testFormatHostPattern() {
    XCTAssertEqual(NativeSSHHostTrustService.formatHostPattern(host: "example.com", port: 22), "example.com")
    XCTAssertEqual(NativeSSHHostTrustService.formatHostPattern(host: "127.0.0.1", port: 22), "127.0.0.1")
    XCTAssertEqual(NativeSSHHostTrustService.formatHostPattern(host: "example.com", port: 2222), "[example.com]:2222")
    XCTAssertEqual(NativeSSHHostTrustService.formatHostPattern(host: "127.0.0.1", port: 2222), "[127.0.0.1]:2222")
    XCTAssertEqual(NativeSSHHostTrustService.formatHostPattern(host: "::1", port: 22), "::1")
    XCTAssertEqual(NativeSSHHostTrustService.formatHostPattern(host: "::1", port: 2222), "[::1]:2222")
    XCTAssertEqual(NativeSSHHostTrustService.formatHostPattern(host: "[::1]", port: 2222), "[::1]:2222")
  }

  func testValidateEndpointRejectsMaliciousInputs() {
    let invalidHosts = [
      "",
      "  ",
      " host",
      "host ",
      "-oProxyCommand=rm",
      "host;whoami",
      "host|sh",
      "host`id`",
      "host$PATH",
      "host\0inject",
      "host\ninject",
      "host@inject",
      // Known_hosts pattern metacharacters that must be rejected to prevent cross-host matching
      "host,other",
      "*.example.com",
      "host?name",
      "!host",
      "host[1-2]",
      "[example.com]", // brackets not allowed on hostname/IPv4
      "host..example.com",
      "host-",
    ]

    for host in invalidHosts {
      XCTAssertThrowsError(try NativeSSHHostTrustService.validateEndpoint(host: host, port: 22)) { error in
        guard case SSHHostTrustError.invalidHost = error else {
          XCTFail("Expected invalidHost for '\(host)' but got \(error)")
          return
        }
      }
    }

    let invalidPorts = [-1, 0, 65536, 99999]
    for port in invalidPorts {
      XCTAssertThrowsError(try NativeSSHHostTrustService.validateEndpoint(host: "127.0.0.1", port: port)) { error in
        guard case SSHHostTrustError.invalidPort = error else {
          XCTFail("Expected invalidPort for \(port) but got \(error)")
          return
        }
      }
    }
  }

  // MARK: - Key Inspection & Fingerprint Parsing Tests

  func testParseHostKeyLineExtractsFingerprintAndArt() throws {
    let dummyKnownHostsURL = tempDirectory.appendingPathComponent("known_hosts")
    let service = NativeSSHHostTrustService(knownHostsFileURL: dummyKnownHostsURL)

    let testLine = "127.0.0.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBw4ONu6jpEcSxnYb0tUI3tpRYIW8gGvrYcg1Ps1dyUj test-comment"
    let record = try service.parseHostKeyLine(testLine)

    XCTAssertEqual(record.keyType, "ssh-ed25519")
    XCTAssertEqual(record.keyBase64, "AAAAC3NzaC1lZDI1NTE5AAAAIBw4ONu6jpEcSxnYb0tUI3tpRYIW8gGvrYcg1Ps1dyUj")
    XCTAssertEqual(record.comment, "test-comment")
    XCTAssertEqual(record.algorithm, "ED25519")
    XCTAssertEqual(record.bitLength, 256)
    XCTAssertEqual(record.fingerprintSHA256, "SHA256:W7zNAzTYnHa7SFG9ZwdzSk/U5nWSWHn6d0TLEAxEGas")
    XCTAssertNotNil(record.visualArt)
    XCTAssertTrue(record.visualArt?.contains("+--[ED25519 256]--+") == true)
  }

  func testParseHostKeyLineHashedKnownHostsEntry() throws {
    let dummyKnownHostsURL = tempDirectory.appendingPathComponent("known_hosts")
    let service = NativeSSHHostTrustService(knownHostsFileURL: dummyKnownHostsURL)

    let hashedLine = "|1|GGNFvhwETtfqDyi2kU2M74jRiuc=|LlVXP1AHT1zSHtkm7NzD9QpFXKw= ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBw4ONu6jpEcSxnYb0tUI3tpRYIW8gGvrYcg1Ps1dyUj"
    let record = try service.parseHostKeyLine(hashedLine)

    XCTAssertEqual(record.keyType, "ssh-ed25519")
    XCTAssertEqual(record.algorithm, "ED25519")
    XCTAssertEqual(record.fingerprintSHA256, "SHA256:W7zNAzTYnHa7SFG9ZwdzSk/U5nWSWHn6d0TLEAxEGas")
  }

  func testParseHostKeyLineThrowsOnMalformedInput() {
    let dummyKnownHostsURL = tempDirectory.appendingPathComponent("known_hosts")
    let service = NativeSSHHostTrustService(knownHostsFileURL: dummyKnownHostsURL)

    XCTAssertThrowsError(try service.parseHostKeyLine("only_one_field"))
    XCTAssertThrowsError(try service.parseHostKeyLine("two fields"))
    XCTAssertThrowsError(try service.parseHostKeyLine("127.0.0.1 ssh-ed25519 not_valid_base64_???"))
  }

  // MARK: - Query Recorded Keys Tests

  func testQueryRecordedKeysFindsExactPortPattern() throws {
    let knownHostsURL = tempDirectory.appendingPathComponent("known_hosts")
    let service = NativeSSHHostTrustService(knownHostsFileURL: knownHostsURL)

    let content = """
    127.0.0.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBw4ONu6jpEcSxnYb0tUI3tpRYIW8gGvrYcg1Ps1dyUj
    [127.0.0.1]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBw4ONu6jpEcSxnYb0tUI3tpRYIW8gGvrYcg1Ps1dyUa
    [::1]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBw4ONu6jpEcSxnYb0tUI3tpRYIW8gGvrYcg1Ps1dyUb
    """
    try content.write(to: knownHostsURL, atomically: true, encoding: .utf8)

    // Standard port 22 matches line 1
    let keys22 = try service.queryRecordedKeys(host: "127.0.0.1", port: 22)
    XCTAssertEqual(keys22.count, 1)
    XCTAssertEqual(keys22[0].keyBase64, "AAAAC3NzaC1lZDI1NTE5AAAAIBw4ONu6jpEcSxnYb0tUI3tpRYIW8gGvrYcg1Ps1dyUj")

    // Port 2222 matches line 2
    let keys2222 = try service.queryRecordedKeys(host: "127.0.0.1", port: 2222)
    XCTAssertEqual(keys2222.count, 1)
    XCTAssertEqual(keys2222[0].keyBase64, "AAAAC3NzaC1lZDI1NTE5AAAAIBw4ONu6jpEcSxnYb0tUI3tpRYIW8gGvrYcg1Ps1dyUa")

    // Port 8022 returns empty
    let keys8022 = try service.queryRecordedKeys(host: "127.0.0.1", port: 8022)
    XCTAssertEqual(keys8022.count, 0)
  }

  // MARK: - Trust Approval and Mismatch Prevention Tests

  func testApproveChallengeAppendsSafelyAndRechecksMismatch() throws {
    let knownHostsURL = tempDirectory.appendingPathComponent("known_hosts")
    let service = NativeSSHHostTrustService(knownHostsFileURL: knownHostsURL)
    let directoryPermissions = try FileManager.default.attributesOfItem(atPath: tempDirectory.path)[.posixPermissions] as? Int

    let keyRecord = SSHHostKeyRecord(
      rawLine: "127.0.0.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBw4ONu6jpEcSxnYb0tUI3tpRYIW8gGvrYcg1Ps1dyUj",
      keyType: "ssh-ed25519",
      keyBase64: "AAAAC3NzaC1lZDI1NTE5AAAAIBw4ONu6jpEcSxnYb0tUI3tpRYIW8gGvrYcg1Ps1dyUj",
      algorithm: "ED25519",
      fingerprintSHA256: "SHA256:W7zNAzTYnHa7SFG9ZwdzSk/U5nWSWHn6d0TLEAxEGas"
    )

    let challenge = SSHHostTrustChallenge(
      host: "127.0.0.1",
      port: 22,
      presentedKey: keyRecord
    )

    // Approve initial unknown challenge
    try service.approveChallenge(challenge, expectedHost: "127.0.0.1", expectedPort: 22)

    // Verify written file
    let saved = try String(contentsOf: knownHostsURL, encoding: .utf8)
    XCTAssertTrue(saved.contains("127.0.0.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBw4ONu6jpEcSxnYb0tUI3tpRYIW8gGvrYcg1Ps1dyUj"))
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: knownHostsURL.path)[.posixPermissions] as? Int, 0o600)
    // Pre-existing directory permissions are left untouched.
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: tempDirectory.path)[.posixPermissions] as? Int, directoryPermissions)

    // Negative: Mismatched target parameters must be rejected
    XCTAssertThrowsError(try service.approveChallenge(challenge, expectedHost: "10.0.0.1", expectedPort: 22))

    // Negative: Overwriting an existing key with a mismatched key must be blocked
    let conflictingKeyRecord = SSHHostKeyRecord(
      rawLine: "127.0.0.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBw4ONu6jpEcSxnYb0tUI3tpRYIW8gGvrYcg1Ps1dyUa",
      keyType: "ssh-ed25519",
      keyBase64: "AAAAC3NzaC1lZDI1NTE5AAAAIBw4ONu6jpEcSxnYb0tUI3tpRYIW8gGvrYcg1Ps1dyUa",
      algorithm: "ED25519",
      fingerprintSHA256: "SHA256:conflicting"
    )
    let conflictingChallenge = SSHHostTrustChallenge(
      host: "127.0.0.1",
      port: 22,
      presentedKey: conflictingKeyRecord
    )

    XCTAssertThrowsError(try service.approveChallenge(conflictingChallenge, expectedHost: "127.0.0.1", expectedPort: 22)) { error in
      guard case SSHHostTrustError.mismatchBlocked = error else {
        XCTFail("Expected mismatchBlocked error but got \(error)")
        return
      }
    }

    // Negative: Rejecting conflicting key of different key type (e.g. RSA existing, ECDSA incoming)
    let conflictingRsaRecord = SSHHostKeyRecord(
      rawLine: "127.0.0.1 ssh-rsa AAAAB3NzaC1yc2EA...",
      keyType: "ssh-rsa",
      keyBase64: "AAAAB3NzaC1yc2EA...",
      algorithm: "RSA",
      fingerprintSHA256: "SHA256:rsa-conflicting"
    )
    let conflictingRsaChallenge = SSHHostTrustChallenge(
      host: "127.0.0.1",
      port: 22,
      presentedKey: conflictingRsaRecord
    )
    XCTAssertThrowsError(try service.approveChallenge(conflictingRsaChallenge, expectedHost: "127.0.0.1", expectedPort: 22)) { error in
      guard case SSHHostTrustError.mismatchBlocked = error else {
        XCTFail("Expected mismatchBlocked on cross-type conflict but got \(error)")
        return
      }
    }

    // Test newline preservation: existing file without trailing newline must have newline inserted cleanly
    let noNewlineURL = tempDirectory.appendingPathComponent("known_hosts_nonewline")
    let serviceNoNewline = NativeSSHHostTrustService(knownHostsFileURL: noNewlineURL)
    let existingEntry = "10.0.0.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBw4ONu6jpEcSxnYb0tUI3tpRYIW8gGvrYcg1Ps1dyUe"
    try existingEntry.write(to: noNewlineURL, atomically: true, encoding: .utf8)

    let challenge2 = SSHHostTrustChallenge(
      host: "10.0.0.2",
      port: 22,
      presentedKey: keyRecord
    )
    try serviceNoNewline.approveChallenge(challenge2, expectedHost: "10.0.0.2", expectedPort: 22)
    let combined = try String(contentsOf: noNewlineURL, encoding: .utf8)
    XCTAssertTrue(combined.contains("10.0.0.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBw4ONu6jpEcSxnYb0tUI3tpRYIW8gGvrYcg1Ps1dyUe\n10.0.0.2 ssh-ed25519"))
  }

  func testQueryRecordedKeysFailsClosedOnRevokedAndCertAuthority() throws {
    let knownHostsURL = tempDirectory.appendingPathComponent("known_hosts_revoked")
    let service = NativeSSHHostTrustService(knownHostsFileURL: knownHostsURL)

    // Revoked entry must fail closed
    let revokedContent = "@revoked 127.0.0.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBw4ONu6jpEcSxnYb0tUI3tpRYIW8gGvrYcg1Ps1dyUj\n"
    try revokedContent.write(to: knownHostsURL, atomically: true, encoding: .utf8)

    XCTAssertThrowsError(try service.queryRecordedKeys(host: "127.0.0.1", port: 22)) { error in
      guard case SSHHostTrustError.knownHostsUnparseable(let details) = error else {
        XCTFail("Expected knownHostsUnparseable for @revoked, got \(error)")
        return
      }
      XCTAssertTrue(details.contains("@revoked"))
    }

    // Cert-authority entry must fail closed
    let caContent = "@cert-authority 127.0.0.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBw4ONu6jpEcSxnYb0tUI3tpRYIW8gGvrYcg1Ps1dyUj\n"
    try caContent.write(to: knownHostsURL, atomically: true, encoding: .utf8)

    XCTAssertThrowsError(try service.queryRecordedKeys(host: "127.0.0.1", port: 22)) { error in
      guard case SSHHostTrustError.knownHostsUnparseable(let details) = error else {
        XCTFail("Expected knownHostsUnparseable for @cert-authority, got \(error)")
        return
      }
      XCTAssertTrue(details.contains("@cert-authority"))
    }
  }

  func testQueryRecordedKeysFailsClosedOnMalformedEntries() throws {
    let knownHostsURL = tempDirectory.appendingPathComponent("known_hosts_malformed")
    let service = NativeSSHHostTrustService(knownHostsFileURL: knownHostsURL)

    let malformedContent = "127.0.0.1 unparseable_single_field\n"
    try malformedContent.write(to: knownHostsURL, atomically: true, encoding: .utf8)

    XCTAssertThrowsError(try service.queryRecordedKeys(host: "127.0.0.1", port: 22)) { error in
      guard case SSHHostTrustError.knownHostsUnparseable = error else {
        XCTFail("Expected knownHostsUnparseable for malformed entry, got \(error)")
        return
      }
    }
  }

  func testClassifyAnyScannedKeyMatchOfSameTypeIsTrusted() {
    func key(_ type: String, _ b64: String) -> SSHHostKeyRecord {
      SSHHostKeyRecord(rawLine: "h \(type) \(b64)", keyType: type, keyBase64: b64, comment: nil, algorithm: type,
        bitLength: nil, fingerprintSHA256: "x", visualArt: nil)
    }
    let ed = key("ssh-ed25519", "AAA"), ecdsa = key("ecdsa-sha2-nistp256", "BBB"), rsa = key("ssh-rsa", "CCC")
    // Trusted via ecdsa only although ed25519 (preferred) is offered and not recorded.
    guard case .trusted = NativeSSHHostTrustService.classify(recordedKeys: [ecdsa], presentedKeys: [ed, ecdsa, rsa], host: "h", port: 22)
    else { return XCTFail("expected trusted") }
    // Same type, different key: mismatch.
    let rotated = key("ecdsa-sha2-nistp256", "ZZZ")
    guard case .mismatch(_, let shown) = NativeSSHHostTrustService.classify(recordedKeys: [ecdsa], presentedKeys: [ed, rotated], host: "h", port: 22)
    else { return XCTFail("expected mismatch") }
    XCTAssertEqual(shown.keyBase64, "ZZZ")
    // No type overlap: unknown, preferred key presented.
    guard case .unknown(let challenge) = NativeSSHHostTrustService.classify(recordedKeys: [rsa], presentedKeys: [ed, ecdsa], host: "h", port: 22)
    else { return XCTFail("expected unknown") }
    XCTAssertEqual(challenge.presentedKey.keyType, "ssh-ed25519")
  }

  func testQuerySecuresOwnedKnownHostsPermissions() throws {
    let directory = tempDirectory.appendingPathComponent("shared_permissions", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    let knownHostsURL = directory.appendingPathComponent("known_hosts")
    try "127.0.0.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBw4ONu6jpEcSxnYb0tUI3tpRYIW8gGvrYcg1Ps1dyUj\n"
      .write(to: knownHostsURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: knownHostsURL.path)

    let keys = try NativeSSHHostTrustService(knownHostsFileURL: knownHostsURL).queryRecordedKeys(host: "127.0.0.1", port: 22)

    XCTAssertEqual(keys.count, 1)
    // Pre-existing user files keep their permissions; only app-created ones are chmod'ed.
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o755)
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: knownHostsURL.path)[.posixPermissions] as? Int, 0o644)
  }

  func testQueryFailsClosedOnWritableDirectoryAndSymlinkedKnownHosts() throws {
    let writableDirectory = tempDirectory.appendingPathComponent("writable", isDirectory: true)
    try FileManager.default.createDirectory(at: writableDirectory, withIntermediateDirectories: true)
    let writableKnownHosts = writableDirectory.appendingPathComponent("known_hosts")
    try "127.0.0.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBw4ONu6jpEcSxnYb0tUI3tpRYIW8gGvrYcg1Ps1dyUj\n"
      .write(to: writableKnownHosts, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: writableDirectory.path)

    XCTAssertThrowsError(try NativeSSHHostTrustService(knownHostsFileURL: writableKnownHosts).queryRecordedKeys(host: "127.0.0.1", port: 22)) { error in
      guard case SSHHostTrustError.knownHostsUnparseable = error else {
        XCTFail("Expected writable trust directory to fail closed, got \(error)")
        return
      }
    }

    let writableFileDirectory = tempDirectory.appendingPathComponent("writable_file", isDirectory: true)
    try FileManager.default.createDirectory(at: writableFileDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let writableFile = writableFileDirectory.appendingPathComponent("known_hosts")
    try "127.0.0.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBw4ONu6jpEcSxnYb0tUI3tpRYIW8gGvrYcg1Ps1dyUj\n"
      .write(to: writableFile, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: writableFile.path)
    XCTAssertThrowsError(try NativeSSHHostTrustService(knownHostsFileURL: writableFile).queryRecordedKeys(host: "127.0.0.1", port: 22)) { error in
      guard case SSHHostTrustError.knownHostsUnparseable = error else {
        XCTFail("Expected group/world-writable trust file to fail closed, got \(error)")
        return
      }
    }

    let target = tempDirectory.appendingPathComponent("trusted_target")
    let symlink = tempDirectory.appendingPathComponent("known_hosts_symlink")
    try "127.0.0.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBw4ONu6jpEcSxnYb0tUI3tpRYIW8gGvrYcg1Ps1dyUj\n"
      .write(to: target, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

    // Symlinked dotfiles are resolved (owner still verified on the target).
    XCTAssertEqual(try NativeSSHHostTrustService(knownHostsFileURL: symlink).queryRecordedKeys(host: "127.0.0.1", port: 22).count, 1)

    let parentTarget = tempDirectory.appendingPathComponent("actual_parent", isDirectory: true)
    let parentSymlink = tempDirectory.appendingPathComponent("parent_symlink", isDirectory: true)
    try FileManager.default.createDirectory(at: parentTarget, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try "127.0.0.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBw4ONu6jpEcSxnYb0tUI3tpRYIW8gGvrYcg1Ps1dyUj\n"
      .write(to: parentTarget.appendingPathComponent("known_hosts"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: parentSymlink, withDestinationURL: parentTarget)

    XCTAssertEqual(
      try NativeSSHHostTrustService(knownHostsFileURL: parentSymlink.appendingPathComponent("known_hosts"))
        .queryRecordedKeys(host: "127.0.0.1", port: 22).count, 1)
  }

  func testSessionCoordinatorRejectsInvalidatedPersistence() {
    let coordinator = NativeSSHSessionCoordinator()
    let activeID = coordinator.reset()
    coordinator.invalidate()

    var persisted = false
    let authorized = coordinator.performIfValid(activeID) {
      persisted = true
    }

    XCTAssertFalse(authorized)
    XCTAssertFalse(persisted, "An invalidated session must not persist trust")
  }

  func testHostTrustSubprocessesHonorCancellationAndDeadline() throws {
    final class CancellationFlag: @unchecked Sendable {
      private let lock = NSLock()
      private var value = false

      func cancel() {
        lock.lock()
        value = true
        lock.unlock()
      }

      var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
      }
    }

    let executable = URL(fileURLWithPath: "/bin/sleep")
    let timeoutStart = Date()
    XCTAssertThrowsError(
      try NativeSSHHostTrustService.runSubprocess(
        executableURL: executable,
        arguments: ["5"],
        timeoutSeconds: 0.1
      )
    ) { error in
      guard case SSHHostTrustError.subprocessTimedOut = error else {
        XCTFail("Expected helper timeout, got \(error)")
        return
      }
    }
    XCTAssertLessThan(Date().timeIntervalSince(timeoutStart), 2)

    let cancellation = CancellationFlag()
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) {
      cancellation.cancel()
    }
    let cancelStart = Date()
    XCTAssertThrowsError(
      try NativeSSHHostTrustService.runSubprocess(
        executableURL: executable,
        arguments: ["5"],
        timeoutSeconds: 5,
        isCancelled: { cancellation.isCancelled }
      )
    ) { error in
      XCTAssertEqual(error as? SSHHostTrustError, .staleChallenge)
    }
    XCTAssertLessThan(Date().timeIntervalSince(cancelStart), 2)
  }

  func testApproveChallengeDoesNotPersistAfterAuthorizationIsCancelled() throws {
    let coordinator = NativeSSHSessionCoordinator()
    let sessionID = coordinator.reset()
    let knownHostsURL = tempDirectory.appendingPathComponent("known_hosts_cancel")
    let service = NativeSSHHostTrustService(knownHostsFileURL: knownHostsURL)

    let challenge = SSHHostTrustChallenge(
      host: "127.0.0.1",
      port: 22,
      presentedKey: SSHHostKeyRecord(
        rawLine: "127.0.0.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBw4ONu6jpEcSxnYb0tUI3tpRYIW8gGvrYcg1Ps1dyUj",
        keyType: "ssh-ed25519",
        keyBase64: "AAAAC3NzaC1lZDI1NTE5AAAAIBw4ONu6jpEcSxnYb0tUI3tpRYIW8gGvrYcg1Ps1dyUj",
        algorithm: "ED25519",
        fingerprintSHA256: "SHA256:W7zNAzTYnHa7SFG9ZwdzSk/U5nWSWHn6d0TLEAxEGas"
      )
    )

    XCTAssertThrowsError(
      try service.approveChallenge(
        challenge,
        expectedHost: "127.0.0.1",
        expectedPort: 22,
        authorizePersistence: { persist in
          coordinator.invalidate()
          return try coordinator.performIfValid(sessionID, operation: persist)
        }
      )
    ) { error in
      XCTAssertEqual(error as? SSHHostTrustError, .staleChallenge)
    }
    XCTAssertEqual(try String(contentsOf: knownHostsURL, encoding: .utf8), "", "Canceled challenge must not persist a key")
    let activeID = coordinator.reset()
    try service.approveChallenge(
      challenge, expectedHost: "127.0.0.1", expectedPort: 22,
      isCancelled: { !coordinator.isValid(activeID) },
      authorizePersistence: { persist in
        try coordinator.performIfValid(activeID, operation: persist)
      }
    )
    XCTAssertTrue(try String(contentsOf: knownHostsURL, encoding: .utf8).contains(challenge.presentedKey.keyBase64))
  }

  // MARK: - Disposable Loopback Fixture Integration

  func testNativeHostTrustWorkflowWithDisposableFixtureIfAvailable() throws {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["MRW_NATIVE_SSH_HOST"],
          let port = env["MRW_NATIVE_SSH_PORT"].flatMap(Int.init),
          let root = env["MRW_NATIVE_FIXTURE_ROOT"] else {
      throw XCTSkip("MRW_NATIVE_SSH fixture environment not configured; skipping lifecycle tests.")
    }

    let rootURL = URL(fileURLWithPath: root, isDirectory: true)
    let serverLogURL = rootURL.appendingPathComponent("sshd.log")
    let testKnownHostsURL = tempDirectory.appendingPathComponent("fixture_test_known_hosts")
    let service = NativeSSHHostTrustService(knownHostsFileURL: testKnownHostsURL)

    let serverLogOffset: () throws -> UInt64 = {
      guard FileManager.default.fileExists(atPath: serverLogURL.path) else {
        XCTFail("Server log file missing at \(serverLogURL.path)")
        throw NativeSSHError.connectionFailed(details: "Missing server log")
      }
      let attrs = try FileManager.default.attributesOfItem(atPath: serverLogURL.path)
      return (attrs[.size] as? NSNumber)?.uint64Value ?? 0
    }

    let assertNoAuthSince: (UInt64) -> Void = { offset in
      guard FileManager.default.fileExists(atPath: serverLogURL.path),
            let data = try? Data(contentsOf: serverLogURL) else {
        XCTFail("Server log unreadable or missing for assertNoAuthSince")
        return
      }
      let start = min(Int(offset), data.count)
      let suffix = String(decoding: data.dropFirst(start), as: UTF8.self)
      XCTAssertFalse(suffix.contains("userauth-request"), "Server saw userauth-request on rejected host key")
      XCTAssertFalse(suffix.contains("Accepted publickey"), "Server accepted key on rejected host key")
    }

    // Step 1: Evaluate empty known_hosts -> must yield .unknown with challenge
    let offset1 = try serverLogOffset()
    let initialStatus = try service.evaluateEndpoint(host: host, port: port)
    guard case .unknown(let challenge) = initialStatus else {
      XCTFail("Expected .unknown status for fresh endpoint but got \(initialStatus)")
      return
    }
    XCTAssertEqual(challenge.host, host)
    XCTAssertEqual(challenge.port, port)
    XCTAssertEqual(challenge.presentedKey.algorithm, "ED25519")
    XCTAssertFalse(challenge.presentedKey.fingerprintSHA256.isEmpty)
    // Keyscan does not authenticate: verify no userauth occurred
    assertNoAuthSince(offset1)

    // Step 2: Simulate User Rejection / Cancel: verify known_hosts remains empty
    XCTAssertFalse(FileManager.default.fileExists(atPath: testKnownHostsURL.path))
    assertNoAuthSince(offset1)

    // Step 3: Simulate User Approval: approveChallenge writes entry
    try service.approveChallenge(challenge, expectedHost: host, expectedPort: port)
    XCTAssertTrue(FileManager.default.fileExists(atPath: testKnownHostsURL.path))

    // Step 4: Re-evaluate -> must now yield .trusted
    let offset2 = try serverLogOffset()
    let secondStatus = try service.evaluateEndpoint(host: host, port: port)
    guard case .trusted(let matchedKey) = secondStatus else {
      XCTFail("Expected .trusted status after approval but got \(secondStatus)")
      return
    }
    XCTAssertEqual(matchedKey.fingerprintSHA256, challenge.presentedKey.fingerprintSHA256)
    assertNoAuthSince(offset2)

    // Step 5: Test Key Rotation / Mismatch -> replace known_hosts entry with wrong key
    let wrongHostKeyURL = rootURL.appendingPathComponent("wrong_host_key.pub")
    guard let wrongPub = try? String(contentsOf: wrongHostKeyURL, encoding: .utf8) else {
      XCTFail("Missing wrong_host_key.pub in fixture directory")
      return
    }
    let parts = wrongPub.split(whereSeparator: { $0.isWhitespace })
    let pattern = NativeSSHHostTrustService.formatHostPattern(host: host, port: port)
    let poisonedEntry = "\(pattern) \(parts[0]) \(parts[1])\n"
    try poisonedEntry.write(to: testKnownHostsURL, atomically: true, encoding: .utf8)

    // Step 6: Evaluate modified endpoint -> must yield .mismatch
    let offset3 = try serverLogOffset()
    let mismatchStatus = try service.evaluateEndpoint(host: host, port: port)
    guard case .mismatch(let recorded, let presented) = mismatchStatus else {
      XCTFail("Expected .mismatch status on modified host key but got \(mismatchStatus)")
      return
    }
    XCTAssertEqual(recorded.count, 1)
    XCTAssertNotEqual(recorded[0].keyBase64, presented.keyBase64)
    // No auth occurred during mismatch evaluation
    assertNoAuthSince(offset3)
  }
}
