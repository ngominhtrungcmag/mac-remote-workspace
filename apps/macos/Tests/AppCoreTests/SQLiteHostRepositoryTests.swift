import Foundation
import SQLite3
import XCTest

@testable import AppCore

final class SQLiteHostRepositoryTests: XCTestCase {
  func testDatabaseAndSidecarsArePrivate() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("metadata.sqlite")
    let repository = try SQLiteHostRepository(databaseURL: url)
    defer { try? repository.close() }
    for path in [url.path, url.path + "-wal", url.path + "-shm"] {
      let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
      XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }
  }

  func testMigrationKeepsOnlyThreeNewestBackups() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("metadata.sqlite")
    try createFixture(at: url, version: 1)
    for index in 0..<4 {
      let backup = directory.appendingPathComponent("metadata.sqlite.bak-v1-old\(index)")
      try Data("old".utf8).write(to: backup)
      try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index + 1))], ofItemAtPath: backup.path)
    }
    let repository = try SQLiteHostRepository(databaseURL: url)
    defer { try? repository.close() }
    let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("metadata.sqlite.bak-v") }
    XCTAssertEqual(backups.count, 3)
    XCTAssertTrue(backups.contains("metadata.sqlite.bak-v1-old3"))
    XCTAssertFalse(backups.contains("metadata.sqlite.bak-v1-old0"))
  }

  func testHostCreateUpdateDeletePersistsAndUsesSelectedWorkspace() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("metadata.sqlite")
    let repository = try SQLiteHostRepository(databaseURL: databaseURL)
    defer { try? repository.close() }

    try execute(
      "INSERT INTO workspaces (id, name) VALUES ('workspace-a', 'Alpha'), ('workspace-b', 'Beta')",
      at: databaseURL
    )
    XCTAssertThrowsError(
      try repository.createHost(
        HostDraft(displayName: "Unscoped", address: "host.example", environment: .development))
    ) { error in
      XCTAssertEqual(error as? SQLiteRepositoryError, .workspaceRequired)
    }
    let created = try repository.createHost(
      HostDraft(
        displayName: "  Build host  ", address: " 127.0.0.1 ", environment: .development,
        workspaceID: "workspace-b"
      ))
    XCTAssertEqual(created.displayName, "Build host")
    XCTAssertEqual(created.address, "127.0.0.1")
    XCTAssertEqual(created.workspaceID, "workspace-b")
    XCTAssertEqual(try repository.listHosts(), [created])

    let updated = try repository.updateHost(
      id: created.id,
      expectedVersion: created.version,
      draft: HostDraft(displayName: "Production API", address: "api.example.net", environment: .production)
    )
    XCTAssertEqual(updated.displayName, "Production API")
    XCTAssertEqual(updated.address, "api.example.net")
    XCTAssertEqual(updated.environment, .production)
    XCTAssertEqual(updated.workspaceID, "workspace-b")
    XCTAssertEqual(updated.version, created.version + 1)
    XCTAssertThrowsError(
      try repository.updateHost(
        id: created.id,
        expectedVersion: created.version,
        draft: HostDraft(displayName: "Stale update", address: "api.example.net", environment: .production)
      )
    ) { error in
      XCTAssertEqual(error as? SQLiteRepositoryError, .hostChanged)
    }
    XCTAssertEqual(try repository.listHosts(), [updated])

    try repository.close()
    let reopened = try SQLiteHostRepository(databaseURL: databaseURL)
    defer { try? reopened.close() }
    XCTAssertEqual(try reopened.listHosts(), [updated])

    try reopened.deleteHost(id: updated.id)
    XCTAssertTrue(try reopened.listHosts().isEmpty)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM workspaces", at: databaseURL), 2)
  }

  func testInvalidHostInputDoesNotCreateRowsOrDefaultWorkspace() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("metadata.sqlite")
    let repository = try SQLiteHostRepository(databaseURL: databaseURL)
    defer { try? repository.close() }
    let invalidDrafts = [
      HostDraft(displayName: "  ", address: "valid.example", environment: .development),
      HostDraft(displayName: String(repeating: "x", count: 121), address: "valid.example", environment: .development),
      HostDraft(displayName: "Bad\u{0001}Name", address: "valid.example", environment: .development),
      HostDraft(displayName: "Host", address: "bad host", environment: .development),
      HostDraft(displayName: "Host", address: String(repeating: "a", count: 254), environment: .development),
    ]

    for draft in invalidDrafts {
      XCTAssertThrowsError(try repository.createHost(draft)) { error in
        XCTAssertTrue(error is HostValidationError)
      }
    }
    XCTAssertTrue(try repository.listHosts().isEmpty)
    XCTAssertTrue(try repository.listWorkspaces().isEmpty)
  }

  func testFirstHostCreatesOnlyTheLocalWorkspace() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try SQLiteHostRepository(databaseURL: directory.appendingPathComponent("metadata.sqlite"))
    defer { try? repository.close() }

    let host = try repository.createHost(
      HostDraft(displayName: "Local host", address: "localhost", environment: .development))
    let workspace = try XCTUnwrap(repository.listWorkspaces().first)
    XCTAssertEqual(workspace.name, "Local")
    XCTAssertEqual(host.workspaceID, workspace.id)
    XCTAssertEqual(try repository.listWorkspaces().count, 1)
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: directory.path).contains {
        $0.hasPrefix("metadata.sqlite.bak-v0-")
      })
  }

  func testEditHostMovesWorkspaceAndPersistsTagsAndProtocols() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try SQLiteHostRepository(databaseURL: directory.appendingPathComponent("metadata.sqlite"))
    defer { try? repository.close() }
    let a = try repository.createWorkspace(name: "A")
    let b = try repository.createWorkspace(name: "B")
    let group = try repository.createGroup(workspaceID: b.id, name: "Ops")
    let created = try repository.createHost(HostDraft(displayName: "Host", address: "host.test", environment: .development,
      workspaceID: a.id, tags: ["prod"], protocols: ["ssh", "rdp"]))
    XCTAssertEqual(Set(created.protocols), Set(["ssh", "rdp"]))
    let moved = try repository.updateHost(id: created.id, expectedVersion: created.version,
      draft: HostDraft(displayName: "Host", address: "host.test", environment: .staging,
        workspaceID: b.id, groupID: group.id, tags: ["web", "critical"], protocols: ["rdp"]))
    XCTAssertEqual(moved.workspaceID, b.id)
    XCTAssertEqual(moved.groupID, group.id)
    XCTAssertEqual(Set(moved.tags), Set(["web", "critical"]))
    XCTAssertEqual(moved.protocols, ["rdp"])
    XCTAssertThrowsError(try repository.updateHost(id: moved.id, expectedVersion: moved.version,
      draft: HostDraft(displayName: "Invalid", address: "host.test", environment: .development,
        workspaceID: a.id, groupID: group.id, tags: ["bad"], protocols: ["ssh"])))
    XCTAssertEqual(try repository.listHosts().first, moved)
  }

  func testVersionSevenUpgradeAndDisablePreserveProfilesAndHistory() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("metadata.sqlite")
    try createFixture(at: url, version: 5)
    let initial = try SQLiteHostRepository(databaseURL: url)
    try initial.close()
    try execute("DROP TRIGGER host_protocols_after_host_insert; DROP TABLE host_protocols; PRAGMA user_version = 7;", at: url)
    let repository = try SQLiteHostRepository(databaseURL: url)
    defer { try? repository.close() }
    let host = try XCTUnwrap(repository.listHosts().first)
    XCTAssertEqual(host.protocols, ["ssh"])
    _ = try repository.updateHost(id: host.id, expectedVersion: host.version,
      draft: HostDraft(displayName: host.displayName, address: host.address, environment: host.environment,
        workspaceID: host.workspaceID, groupID: host.groupID, protocols: []))
    XCTAssertTrue(try XCTUnwrap(repository.listHosts().first).protocols.isEmpty)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM connection_profiles", at: url), 1)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM recent_sessions", at: url), 1)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM transfer_jobs", at: url), 1)
  }

  func testVersionSixUpgradePreservesSettings() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("metadata.sqlite")
    let initial = try SQLiteHostRepository(databaseURL: url)
    let host = try initial.createHost(HostDraft(displayName: "host", address: "example.test", environment: .development))
    let settings = SSHConnectionSettings(username: "user", port: 22)
    try initial.upsertSSHConnectionSettings(hostID: host.id, settings: settings)
    try initial.close()
    try execute("DROP TRIGGER host_protocols_after_host_insert; DROP TABLE host_protocols; ALTER TABLE host_connection_settings DROP COLUMN proxy_jump; PRAGMA user_version = 6;", at: url)
    let upgraded = try SQLiteHostRepository(databaseURL: url)
    defer { try? upgraded.close() }
    XCTAssertEqual(try upgraded.schemaVersion, 8)
    XCTAssertEqual(try upgraded.sshConnectionSettings(hostID: host.id), settings)
    var changed = settings
    changed.proxyJump = "jumpuser@jump.example:2222"
    try upgraded.upsertSSHConnectionSettings(hostID: host.id, settings: changed)
    XCTAssertEqual(try upgraded.sshConnectionSettings(hostID: host.id), changed)
    changed.proxyJump = "jump@[::1]:2222"
    try upgraded.upsertSSHConnectionSettings(hostID: host.id, settings: changed)
    XCTAssertEqual(try upgraded.sshConnectionSettings(hostID: host.id), changed)
    changed.proxyJump = "evil;command"
    XCTAssertThrowsError(try upgraded.upsertSSHConnectionSettings(hostID: host.id, settings: changed))
  }

  func testVersionFiveImportsLegacySettingsWithoutLosingData() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("metadata.sqlite")
    try createFixture(at: url, version: 5)
    let suite = "ssh-settings-test-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = SSHConnectionSettings(username: "alice", port: 2222, auth: .keychainCredential,
      credentialID: "credential-ref", keyFilePath: "~/.ssh/id_ed25519")
    let key = "ssh.preset.legacy-host"
    defaults.set(try JSONEncoder().encode(settings), forKey: key)
    defaults.set(Data("invalid".utf8), forKey: "ssh.preset.broken")
    let repository = try SQLiteHostRepository(databaseURL: url)
    defer { try? repository.close() }
    try repository.importLegacySSHConnectionSettings(from: defaults)
    XCTAssertEqual(try repository.schemaVersion, 8)
    XCTAssertEqual(try repository.listHosts().first?.displayName, "Existing host")
    XCTAssertEqual(try repository.sshConnectionSettings(hostID: "legacy-host"), settings)
    XCTAssertNil(defaults.object(forKey: key))
    XCTAssertNotNil(defaults.object(forKey: "ssh.preset.broken"))
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM connection_profiles", at: url), 1)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM pragma_foreign_key_check", at: url), 0)
    var updated = settings
    updated.port = 2200
    try repository.upsertSSHConnectionSettings(hostID: "legacy-host", settings: updated)
    defaults.set(try JSONEncoder().encode(settings), forKey: key)
    try repository.importLegacySSHConnectionSettings(from: defaults)
    XCTAssertNil(defaults.object(forKey: key))
    XCTAssertEqual(try repository.sshConnectionSettings(hostID: "legacy-host"), updated)
    var invalid = settings
    invalid.port = 0
    XCTAssertThrowsError(try repository.upsertSSHConnectionSettings(hostID: "legacy-host", settings: invalid))
    XCTAssertEqual(try repository.sshConnectionSettings(hostID: "legacy-host"), updated)
    XCTAssertThrowsError(try repository.upsertSSHConnectionSettings(hostID: "missing", settings: settings))
    try repository.deleteSSHConnectionSettings(hostID: "legacy-host")
    XCTAssertNil(try repository.sshConnectionSettings(hostID: "legacy-host"))
    try repository.upsertSSHConnectionSettings(hostID: "legacy-host", settings: settings)
    try repository.deleteHost(id: "legacy-host")
    XCTAssertNil(try repository.sshConnectionSettings(hostID: "legacy-host"))
  }

  func testVersionOneUpgradePreservesRelatedRowsAndCreatesBackup() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("metadata.sqlite")
    try createFixture(at: databaseURL, version: 1)

    let repository = try SQLiteHostRepository(databaseURL: databaseURL)
    defer { try? repository.close() }
    XCTAssertEqual(try repository.schemaVersion, 8)
    XCTAssertEqual(try repository.listHosts().first?.displayName, "Existing host")
    XCTAssertEqual(try repository.listWorkspaces().first?.id, "legacy-workspace")
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM connection_profiles", at: databaseURL), 1)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM credential_refs", at: databaseURL), 1)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM recent_sessions", at: databaseURL), 1)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM transfer_jobs", at: databaseURL), 1)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM pragma_foreign_key_check", at: databaseURL), 0)
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(atPath: directory.path).contains {
        $0.hasPrefix("metadata.sqlite.bak-v1-")
      })
  }

  func testVersionTwoDatabaseUpgradesWithoutChangingExistingData() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("metadata.sqlite")
    try createFixture(at: databaseURL, version: 2)

    let repository = try SQLiteHostRepository(databaseURL: databaseURL)
    defer { try? repository.close() }
    XCTAssertEqual(try repository.schemaVersion, 8)
    XCTAssertEqual(try repository.listHosts().first?.id, "legacy-host")
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM connection_profiles", at: databaseURL), 1)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM recent_sessions", at: databaseURL), 1)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM transfer_jobs", at: databaseURL), 1)
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(atPath: directory.path).contains {
        $0.hasPrefix("metadata.sqlite.bak-v2-")
      })
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM command_snippets", at: databaseURL), 0)
    try repository.deleteHost(id: "legacy-host")
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM connection_profiles", at: databaseURL), 0)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM recent_sessions", at: databaseURL), 0)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM transfer_jobs", at: databaseURL), 0)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM credential_refs", at: databaseURL), 1)
  }

  func testVersionThreeDatabaseUpgradesToVersionFourAndCreatesRdpHostTrustTable() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("metadata.sqlite")
    try createFixture(at: databaseURL, version: 3)

    let repository = try SQLiteHostRepository(databaseURL: databaseURL)
    defer { try? repository.close() }
    XCTAssertEqual(try repository.schemaVersion, 8)
    XCTAssertEqual(try repository.listHosts().first?.id, "legacy-host")
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM connection_profiles", at: databaseURL), 1)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM rdp_host_trust", at: databaseURL), 0)
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(atPath: directory.path).contains {
        $0.hasPrefix("metadata.sqlite.bak-v3-")
      })

    // Test inserting and querying RDP host trust
    let cert = RdpCertificateRecord(
      host: "win-test.local",
      port: 3389,
      sha256Fingerprint: "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF",
      subjectCN: "win-test",
      issuerCN: "Test CA"
    )
    try repository.recordRdpHostTrust(record: cert)
    let fetched = try repository.getRdpHostTrust(host: "win-test.local", port: 3389)
    XCTAssertEqual(fetched?.sha256Fingerprint, cert.sha256Fingerprint)
    XCTAssertEqual(try repository.listRdpHostTrust().count, 1)

    try repository.deleteRdpHostTrust(host: "win-test.local", port: 3389)
    XCTAssertNil(try repository.getRdpHostTrust(host: "win-test.local", port: 3389))
  }

  func testVersionFourDatabaseUpgradesToVersionFiveAndSupportsRdpPassword() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("metadata.sqlite")
    try createFixture(at: databaseURL, version: 4)

    let repository = try SQLiteHostRepository(databaseURL: databaseURL)
    defer { try? repository.close() }
    XCTAssertEqual(try repository.schemaVersion, 8)
    XCTAssertEqual(try repository.listHosts().first?.id, "legacy-host")
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM connection_profiles", at: databaseURL), 1)
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(atPath: directory.path).contains {
        $0.hasPrefix("metadata.sqlite.bak-v4-")
      })

    let ref = KeychainCredentialStore.freshReference()
    let rdpCred = try repository.createCredentialRef(
      label: "Windows Server 2022",
      kind: .rdpPassword,
      keychainItemID: ref.encoded
    )
    XCTAssertEqual(rdpCred.kind, .rdpPassword)
    XCTAssertEqual(rdpCred.label, "Windows Server 2022")

    let listed = try repository.listCredentialRefs()
    XCTAssertTrue(listed.contains { $0.id == rdpCred.id && $0.kind == .rdpPassword })
  }

  func testRdpProfileDefaultsReturnsUsernameAndCredentialRef() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("metadata.sqlite")
    let repository = try SQLiteHostRepository(databaseURL: databaseURL)
    let host = try repository.createHost(HostDraft(
      displayName: "Win", address: "win.example", environment: .development))
    XCTAssertNil(try repository.rdpProfileDefaults(hostID: host.id))
    try execute(
      "INSERT INTO credential_refs (id, label, kind, keychain_item_id) "
        + "VALUES ('cr1', 'Saved', 'password', 'mrw.cred.saved'); "
        + "INSERT INTO connection_profiles (id, host_id, protocol, port, username, auth_method, credential_ref_id) "
        + "VALUES ('p1', '\(host.id)', 'rdp', 3389, 'DOM\\alice', 'password', 'cr1');",
      at: databaseURL)
    let defaults = try XCTUnwrap(try repository.rdpProfileDefaults(hostID: host.id))
    XCTAssertEqual(defaults.username, "DOM\\alice")
    XCTAssertEqual(defaults.credentialRefID, "cr1")
    try repository.close()
  }

  func testUpsertRdpProfileInsertsThenUpdatesWithoutDuplicates() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("metadata.sqlite")
    let repository = try SQLiteHostRepository(databaseURL: databaseURL)
    let host = try repository.createHost(HostDraft(
      displayName: "Win", address: "win.example", environment: .development))
    try execute(
      "INSERT INTO credential_refs (id, label, kind, keychain_item_id) "
        + "VALUES ('cr1', 'Saved', 'password', 'mrw.cred.saved');",
      at: databaseURL)
    try repository.upsertRdpProfile(hostID: host.id, port: 3389, username: " alice ", credentialRefID: nil)
    var d = try XCTUnwrap(try repository.rdpProfileDefaults(hostID: host.id))
    XCTAssertEqual(d.port, 3389)
    XCTAssertEqual(d.username, "alice")
    XCTAssertNil(d.credentialRefID)
    try repository.upsertRdpProfile(hostID: host.id, port: 3390, username: "bob", credentialRefID: "cr1")
    d = try XCTUnwrap(try repository.rdpProfileDefaults(hostID: host.id))
    XCTAssertEqual(d.port, 3390)
    XCTAssertEqual(d.username, "bob")
    XCTAssertEqual(d.credentialRefID, "cr1")
    XCTAssertEqual(try repository.credentialRefUsageCount(id: "cr1"), 1)
    try repository.upsertRdpProfile(hostID: host.id, port: 3390, username: "bob", credentialRefID: nil)
    d = try XCTUnwrap(try repository.rdpProfileDefaults(hostID: host.id))
    XCTAssertEqual(d.port, 3390)
    XCTAssertNil(d.credentialRefID)
    try repository.close()
  }

  func testDeleteWithActiveSessionPreservesHostAndSession() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("metadata.sqlite")
    let initial = try SQLiteHostRepository(databaseURL: databaseURL)
    let host = try initial.createHost(
      HostDraft(displayName: "Active host", address: "localhost", environment: .development))
    try initial.close()

    try execute(
      "INSERT INTO connection_profiles (id, host_id, protocol, port, username, auth_method, options_json) "
        + "VALUES ('active-profile', '\(host.id)', 'ssh', 22, 'tester', 'ssh_agent', '{}'); "
        + "INSERT INTO recent_sessions (id, connection_profile_id, status) "
        + "VALUES ('active-session', 'active-profile', 'connected');",
      at: databaseURL
    )
    let repository = try SQLiteHostRepository(databaseURL: databaseURL)
    defer { try? repository.close() }

    XCTAssertThrowsError(try repository.deleteHost(id: host.id)) { error in
      XCTAssertEqual(error as? SQLiteRepositoryError, .hostInUse)
    }
    XCTAssertEqual(try repository.listHosts().map(\.id), [host.id])
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM recent_sessions WHERE id = 'active-session'", at: databaseURL), 1)
  }

  func testDeleteWithActiveTransferPreservesHostAndTransfer() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("metadata.sqlite")
    let initial = try SQLiteHostRepository(databaseURL: databaseURL)
    let host = try initial.createHost(
      HostDraft(displayName: "Transferring host", address: "localhost", environment: .development))
    try initial.close()

    try execute(
      "INSERT INTO connection_profiles (id, host_id, protocol, port, username, auth_method, options_json) "
        + "VALUES ('transfer-profile', '\(host.id)', 'ssh', 22, 'tester', 'ssh_agent', '{}'); "
        + "INSERT INTO transfer_jobs (id, connection_profile_id, direction, local_path, remote_path, "
        + "conflict_policy, status) VALUES ('active-transfer', 'transfer-profile', 'upload', "
        + "'/tmp/local-fixture', '/tmp/remote-fixture', 'skip', 'running');",
      at: databaseURL
    )
    let repository = try SQLiteHostRepository(databaseURL: databaseURL)
    defer { try? repository.close() }

    XCTAssertThrowsError(try repository.deleteHost(id: host.id)) { error in
      XCTAssertEqual(error as? SQLiteRepositoryError, .hostInUse)
    }
    XCTAssertEqual(try repository.listHosts().map(\.id), [host.id])
    XCTAssertEqual(
      try scalar("SELECT COUNT(*) FROM transfer_jobs WHERE id = 'active-transfer'", at: databaseURL), 1)
  }

  func testFutureSchemaVersionIsRejectedWithoutChangingIt() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("metadata.sqlite")
    try execute(
      "CREATE TABLE keep_me (value TEXT); INSERT INTO keep_me VALUES ('preserved'); PRAGMA user_version = 9;",
      at: databaseURL
    )

    XCTAssertThrowsError(try SQLiteHostRepository(databaseURL: databaseURL)) { error in
      XCTAssertEqual(error as? SQLiteRepositoryError, .unsupportedSchemaVersion(9))
    }
    XCTAssertEqual(try scalar("PRAGMA user_version", at: databaseURL), 9)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM keep_me", at: databaseURL), 1)
  }

  func testAppDatabaseURLMatchesExistingAppDataDirectory() throws {
    let supportDirectory = URL(fileURLWithPath: "/temporary/support", isDirectory: true)
    XCTAssertEqual(
      SQLiteHostRepository.applicationDatabaseURL(applicationSupportDirectory: supportDirectory).path,
      "/temporary/support/org.macremoteworkspace.desktop/metadata.sqlite"
    )
  }

  func testWorkspaceAndGroupCRUDValidatesNamesAndRejectsStaleVersions() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try SQLiteHostRepository(databaseURL: directory.appendingPathComponent("metadata.sqlite"))
    defer { try? repository.close() }

    XCTAssertThrowsError(try repository.createWorkspace(name: " \n ")) { error in
      XCTAssertEqual(error as? OrganizationNameValidationError, .emptyName)
    }
    let workspace = try repository.createWorkspace(name: "  Build  ")
    XCTAssertEqual(workspace.name, "Build")
    let renamed = try repository.updateWorkspace(id: workspace.id, expectedVersion: workspace.version, name: "Build 2")
    XCTAssertEqual(renamed.name, "Build 2")
    XCTAssertEqual(renamed.version, workspace.version + 1)
    XCTAssertThrowsError(try repository.updateWorkspace(id: workspace.id, expectedVersion: workspace.version, name: "Stale")) { error in
      XCTAssertEqual(error as? SQLiteRepositoryError, .workspaceChanged)
    }
    XCTAssertThrowsError(try repository.deleteWorkspace(id: workspace.id, expectedVersion: workspace.version)) { error in
      XCTAssertEqual(error as? SQLiteRepositoryError, .workspaceChanged)
    }

    let group = try repository.createGroup(workspaceID: workspace.id, name: "Tools")
    XCTAssertEqual(group.workspaceID, workspace.id)
    XCTAssertThrowsError(try repository.createGroup(workspaceID: workspace.id, name: "tools")) { error in
      XCTAssertEqual(error as? SQLiteRepositoryError, .groupNameAlreadyExists)
    }
    let renamedGroup = try repository.updateGroup(id: group.id, expectedVersion: group.version, name: "Runtime")
    XCTAssertEqual(renamedGroup.name, "Runtime")
    XCTAssertEqual(renamedGroup.version, group.version + 1)
    XCTAssertThrowsError(try repository.updateGroup(id: group.id, expectedVersion: group.version, name: "Stale")) { error in
      XCTAssertEqual(error as? SQLiteRepositoryError, .groupChanged)
    }
    let otherGroup = try repository.createGroup(workspaceID: workspace.id, name: "Other")
    XCTAssertThrowsError(try repository.updateGroup(id: otherGroup.id, expectedVersion: otherGroup.version, name: "runtime")) { error in
      XCTAssertEqual(error as? SQLiteRepositoryError, .groupNameAlreadyExists)
    }
    XCTAssertEqual(try repository.listGroups(workspaceID: workspace.id).map(\.name), ["Runtime", "Other"])
  }

  func testGroupedHostCreateAndMoveRejectsMismatchedWorkspaceAndStaleVersion() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("metadata.sqlite")
    let repository = try SQLiteHostRepository(databaseURL: databaseURL)
    defer { try? repository.close() }
    try execute(
      "INSERT INTO workspaces (id, name) VALUES ('workspace-a', 'Alpha'), ('workspace-b', 'Beta'); "
        + "INSERT INTO host_groups (id, workspace_id, name) VALUES ('group-a', 'workspace-a', 'Build'), "
        + "('group-b', 'workspace-b', 'Ops');",
      at: databaseURL
    )

    XCTAssertThrowsError(try repository.createHost(HostDraft(
      displayName: "Host", address: "host.example", environment: .development,
      workspaceID: "workspace-a", groupID: "group-b"
    ))) { error in
      XCTAssertEqual(error as? SQLiteRepositoryError, .groupWorkspaceMismatch)
    }

    let host = try repository.createHost(HostDraft(
      displayName: "Host", address: "host.example", environment: .development,
      workspaceID: "workspace-a", groupID: "group-a"
    ))
    XCTAssertEqual(host.groupID, "group-a")
    let moved = try repository.moveHost(
      id: host.id, expectedVersion: host.version, toWorkspaceID: "workspace-b", groupID: "group-b")
    XCTAssertEqual(moved.workspaceID, "workspace-b")
    XCTAssertEqual(moved.groupID, "group-b")
    XCTAssertEqual(moved.version, host.version + 1)
    XCTAssertThrowsError(try repository.moveHost(
      id: host.id, expectedVersion: host.version, toWorkspaceID: "workspace-a", groupID: nil)) { error in
      XCTAssertEqual(error as? SQLiteRepositoryError, .hostChanged)
    }
    XCTAssertThrowsError(try repository.moveHost(
      id: host.id, expectedVersion: moved.version, toWorkspaceID: "workspace-a", groupID: "group-b")) { error in
      XCTAssertEqual(error as? SQLiteRepositoryError, .groupWorkspaceMismatch)
    }
  }

  func testDeletingGroupKeepsHostAndDetachesIt() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try SQLiteHostRepository(databaseURL: directory.appendingPathComponent("metadata.sqlite"))
    defer { try? repository.close() }
    let workspace = try repository.createWorkspace(name: "Build")
    let group = try repository.createGroup(workspaceID: workspace.id, name: "CI")
    let host = try repository.createHost(HostDraft(
      displayName: "Runner", address: "runner.example", environment: .staging,
      workspaceID: workspace.id, groupID: group.id
    ))

    try repository.deleteGroup(id: group.id, expectedVersion: group.version)
    XCTAssertEqual(try repository.listGroups(workspaceID: workspace.id), [])
    XCTAssertEqual(try repository.listHosts(), [HostRecord(
      id: host.id, workspaceID: workspace.id, displayName: host.displayName,
      address: host.address, environment: host.environment, version: host.version
    )])
  }

  func testWorkspaceDeleteCascadesMetadataPreservesCredentialReferenceAndBlocksLiveActivity() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("metadata.sqlite")
    let repository = try SQLiteHostRepository(databaseURL: databaseURL)
    let workspace = try repository.createWorkspace(name: "Disposable")
    let group = try repository.createGroup(workspaceID: workspace.id, name: "Ops")
    let host = try repository.createHost(HostDraft(
      displayName: "Node", address: "node.example", environment: .development,
      workspaceID: workspace.id, groupID: group.id
    ))
    try repository.close()
    try execute(
      "INSERT INTO credential_refs (id, label, kind, keychain_item_id) "
        + "VALUES ('credential-ref', 'Saved', 'password', 'mrw.cred.saved'); "
        + "INSERT INTO connection_profiles (id, host_id, protocol, port, username, auth_method, credential_ref_id, options_json) "
        + "VALUES ('profile', '\(host.id)', 'ssh', 22, 'tester', 'password', 'credential-ref', '{}'); "
        + "INSERT INTO recent_sessions (id, connection_profile_id, status) VALUES ('session', 'profile', 'connected');",
      at: databaseURL
    )
    let active = try SQLiteHostRepository(databaseURL: databaseURL)
    XCTAssertThrowsError(try active.deleteWorkspace(id: workspace.id, expectedVersion: workspace.version)) { error in
      XCTAssertEqual(error as? SQLiteRepositoryError, .workspaceInUse)
    }
    XCTAssertEqual(try active.listHosts().map(\.id), [host.id])
    try execute(
      "UPDATE recent_sessions SET status = 'closed' WHERE id = 'session'; "
        + "INSERT INTO transfer_jobs (id, connection_profile_id, direction, local_path, remote_path, conflict_policy, status) "
        + "VALUES ('active-transfer', 'profile', 'upload', '/tmp/local-fixture', '/tmp/remote-fixture', 'skip', 'running');",
      at: databaseURL
    )
    XCTAssertThrowsError(try active.deleteWorkspace(id: workspace.id, expectedVersion: workspace.version)) { error in
      XCTAssertEqual(error as? SQLiteRepositoryError, .workspaceInUse)
    }
    XCTAssertEqual(try active.listHosts().map(\.id), [host.id])
    try execute("UPDATE transfer_jobs SET status = 'completed' WHERE id = 'active-transfer'", at: databaseURL)
    try active.deleteWorkspace(id: workspace.id, expectedVersion: workspace.version)
    XCTAssertTrue(try active.listHosts().isEmpty)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM connection_profiles", at: databaseURL), 0)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM recent_sessions", at: databaseURL), 0)
    XCTAssertEqual(try scalar("SELECT COUNT(*) FROM credential_refs", at: databaseURL), 1)
    try active.close()
  }

  func testVersionOneMigrationPreservesWorkspaceGroupHostLink() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("metadata.sqlite")
    try createFixture(at: databaseURL, version: 1, includeGroup: true)
    let repository = try SQLiteHostRepository(databaseURL: databaseURL)
    defer { try? repository.close() }
    XCTAssertEqual(try repository.listHosts().first?.groupID, "legacy-group")
    XCTAssertEqual(try repository.listGroups(workspaceID: "legacy-workspace").first?.name, "Legacy group")
  }

  func testDatabaseFilePermissionsAreRestricted() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("metadata.sqlite")
    let repository = try SQLiteHostRepository(databaseURL: databaseURL)
    defer { try? repository.close() }
    let attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("mrw-native-hosts-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func createFixture(at url: URL, version: Int, includeGroup: Bool = false) throws {
    let migrationDirectory = try SQLiteHostRepository.migrationDirectory
    let initial = try String(
      contentsOf: migrationDirectory.appendingPathComponent("0001_initial.sql"), encoding: .utf8)
    let rdpProfiles = try String(
      contentsOf: migrationDirectory.appendingPathComponent("0002_rdp_profiles.sql"), encoding: .utf8)
    let commandSnippets = try String(
      contentsOf: migrationDirectory.appendingPathComponent("0003_command_snippets.sql"), encoding: .utf8)
    let rdpHostTrust = try String(
      contentsOf: migrationDirectory.appendingPathComponent("0004_rdp_embedded_and_host_trust.sql"), encoding: .utf8)
    let rdpCredentialKind = try String(
      contentsOf: migrationDirectory.appendingPathComponent("0005_rdp_credential_kind.sql"), encoding: .utf8)
    let groupSeed = includeGroup
      ? "INSERT INTO host_groups (id, workspace_id, name) VALUES ('legacy-group', 'legacy-workspace', 'Legacy group');\n"
      : ""
    let hostGroupColumns = includeGroup ? "group_id, " : ""
    let hostGroupValues = includeGroup ? "'legacy-group', " : ""
    let seed = """
      INSERT INTO workspaces (id, name) VALUES ('legacy-workspace', 'Legacy');
      \(groupSeed)INSERT INTO hosts (id, workspace_id, \(hostGroupColumns)display_name, address, environment)
        VALUES ('legacy-host', 'legacy-workspace', \(hostGroupValues)'Existing host', 'legacy.example', 'staging');
      INSERT INTO credential_refs (id, label, kind, keychain_item_id)
        VALUES ('credential-ref', 'Existing reference', 'password', 'mrw.cred/existing');
      INSERT INTO connection_profiles (id, host_id, protocol, port, username, auth_method,
        private_key_path, credential_ref_id, options_json)
        VALUES ('profile', 'legacy-host', 'ssh', 22, 'tester', 'password', NULL, 'credential-ref', '{}');
      INSERT INTO recent_sessions (id, connection_profile_id, status)
        VALUES ('session', 'profile', 'closed');
      INSERT INTO transfer_jobs (id, connection_profile_id, direction, local_path, remote_path,
        conflict_policy, status)
        VALUES ('transfer', 'profile', 'upload', '/tmp/local-fixture', '/tmp/remote-fixture', 'skip', 'completed');
      PRAGMA user_version = \(version);
      """
    let sql = switch version {
    case 1: "\(initial)\n\(seed)"
    case 2: "\(initial)\n\(rdpProfiles)\n\(seed)"
    case 3: "\(initial)\n\(rdpProfiles)\n\(commandSnippets)\n\(seed)"
    case 4: "\(initial)\n\(rdpProfiles)\n\(commandSnippets)\n\(rdpHostTrust)\n\(seed)"
    default: "\(initial)\n\(rdpProfiles)\n\(commandSnippets)\n\(rdpHostTrust)\n\(rdpCredentialKind)\n\(seed)"
    }
    try execute(sql, at: url)
  }

  private func execute(_ sql: String, at url: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
      let database
    else {
      throw NSError(domain: "SQLiteHostRepositoryTests", code: 1)
    }
    defer { sqlite3_close_v2(database) }
    var message: UnsafeMutablePointer<CChar>?
    let status = sql.withCString { sqlite3_exec(database, $0, nil, nil, &message) }
    guard status == SQLITE_OK else {
      let description = message.map { String(cString: $0) } ?? "SQLite fixture failed"
      sqlite3_free(message)
      throw NSError(
        domain: "SQLiteHostRepositoryTests", code: Int(status),
        userInfo: [NSLocalizedDescriptionKey: description])
    }
  }

  private func scalar(_ sql: String, at url: URL) throws -> Int {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database
    else {
      throw NSError(domain: "SQLiteHostRepositoryTests", code: 2)
    }
    defer { sqlite3_close_v2(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw NSError(domain: "SQLiteHostRepositoryTests", code: 3)
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw NSError(domain: "SQLiteHostRepositoryTests", code: 4)
    }
    return Int(sqlite3_column_int(statement, 0))
  }
}
