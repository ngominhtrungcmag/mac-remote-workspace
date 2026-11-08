import Foundation
import SQLite3
import XCTest
@testable import AppCore

/// Covers the SQLite credential-reference metadata slice (FR-004 / TC-003 /
/// TC-023). Secrets live only in the Keychain; SQLite holds opaque references.
final class CredentialRefMetadataTests: XCTestCase {
  private func makeTemporaryDatabase() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("mrw-cred-meta-\(UUID().uuidString).sqlite")
    // Initialize schema with a single connection that is closed immediately.
    let repository = try SQLiteHostRepository(databaseURL: url)
    try repository.close()
    return url
  }

  func testCreateListUpdateDeleteCredentialRefLifecycle() throws {
    let databaseURL = try makeTemporaryDatabase()
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    let repository = try SQLiteHostRepository(databaseURL: databaseURL)
    defer { try? repository.close() }

    XCTAssertTrue(try repository.listCredentialRefs().isEmpty)

    let reference = KeychainCredentialStore.freshReference()
    let created = try repository.createCredentialRef(
      label: "  staging ssh  ", kind: .keyPassphrase, keychainItemID: reference.encoded)
    XCTAssertNotEqual(created.id, "")
    XCTAssertNotEqual(created.id, reference.encoded, "Reference id must not carry the secret handle as its id.")
    XCTAssertEqual(created.label, "staging ssh")
    XCTAssertEqual(created.kind, .keyPassphrase)
    XCTAssertEqual(created.keychainItemID, reference.encoded)

    let listed = try repository.listCredentialRefs()
    XCTAssertEqual(listed, [created])

    let renamed = try repository.updateCredentialRef(
      id: created.id, expectedLabel: "staging ssh", label: "staging ssh admin")
    XCTAssertEqual(renamed.label, "staging ssh admin")

    // Stale optimistic label blocks the update.
    XCTAssertThrowsError(
      try repository.updateCredentialRef(id: created.id, expectedLabel: "staging ssh", label: "other")
    ) { error in
      XCTAssertEqual(error as? SQLiteRepositoryError, .credentialRefChanged)
    }

    XCTAssertThrowsError(try repository.deleteCredentialRef(id: "missing")) { error in
      XCTAssertEqual(error as? SQLiteRepositoryError, .credentialRefNotFound)
    }

    try repository.deleteCredentialRef(id: created.id)
    XCTAssertTrue(try repository.listCredentialRefs().isEmpty)
  }

  func testLabelValidationRules() throws {
    let databaseURL = try makeTemporaryDatabase()
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    let repository = try SQLiteHostRepository(databaseURL: databaseURL)
    defer { try? repository.close() }

    let reference = KeychainCredentialStore.freshReference()

    XCTAssertThrowsError(try repository.createCredentialRef(
      label: "   ", kind: .password, keychainItemID: reference.encoded
    )) { error in
      XCTAssertEqual(error as? CredentialRefValidationError, .emptyLabel)
    }
    XCTAssertThrowsError(try repository.createCredentialRef(
      label: String(repeating: "a", count: 121), kind: .password, keychainItemID: reference.encoded
    )) { error in
      XCTAssertEqual(error as? CredentialRefValidationError, .labelTooLong)
    }
    XCTAssertThrowsError(try repository.createCredentialRef(
      label: "bad\u{0007}label", kind: .password, keychainItemID: reference.encoded
    )) { error in
      XCTAssertEqual(error as? CredentialRefValidationError, .invalidLabel)
    }
    XCTAssertThrowsError(try repository.createCredentialRef(
      label: "label", kind: .password, keychainItemID: secretHandle()
    )) { error in
      XCTAssertEqual(error as? CredentialRefValidationError, .invalidLabel)
    }

    XCTAssertEqual(try repository.listCredentialRefs().count, 0)
  }

  func testCreateRdpPasswordCredentialRef() throws {
    let databaseURL = try makeTemporaryDatabase()
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    let repository = try SQLiteHostRepository(databaseURL: databaseURL)
    defer { try? repository.close() }

    let reference = KeychainCredentialStore.freshReference()
    let record = try repository.createCredentialRef(
      label: "Domain Admin (AD)", kind: .rdpPassword, keychainItemID: reference.encoded)
    XCTAssertEqual(record.label, "Domain Admin (AD)")
    XCTAssertEqual(record.kind, .rdpPassword)
    XCTAssertEqual(record.kind.title, "Windows / RDP password")

    let fetched = try repository.listCredentialRefs()
    XCTAssertEqual(fetched.count, 1)
    XCTAssertEqual(fetched.first?.kind, .rdpPassword)
  }

  func testUsageCountTracksConnectionProfilesAndSharedDeleteIsBlocked() throws {
    let databaseURL = try makeTemporaryDatabase()
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    let repository = try SQLiteHostRepository(databaseURL: databaseURL)

    let reference = KeychainCredentialStore.freshReference()
    let record = try repository.createCredentialRef(
      label: "shared ssh", kind: .password, keychainItemID: reference.encoded)
    XCTAssertEqual(try repository.credentialRefUsageCount(id: record.id), 0)

    let workspace = try repository.createWorkspace(name: "Default")
    let host = try repository.createHost(
      HostDraft(
        displayName: "loopback host",
        address: "127.0.0.1",
        environment: .staging,
        workspaceID: workspace.id
      ))

    // Simulate a saved connection profile referencing the credential.
    try withSeparateConnection(databaseURL: databaseURL) { database in
      try exec(
        database,
        "INSERT INTO connection_profiles (id, host_id, protocol, port, username, auth_method, credential_ref_id) "
          + "VALUES ('profile-1', ?, 'ssh', 22, 'fixture-user', 'password', ?)",
      [host.id, record.id])
    }

    XCTAssertEqual(try repository.credentialRefUsageCount(id: record.id), 1)

    XCTAssertThrowsError(try repository.deleteCredentialRef(id: record.id)) { error in
      XCTAssertEqual(error as? SQLiteRepositoryError, .credentialRefInUse)
    }

    try withSeparateConnection(databaseURL: databaseURL) { database in
      try exec(database, "DELETE FROM connection_profiles WHERE id = 'profile-1'")
    }
    try repository.deleteCredentialRef(id: record.id)
    XCTAssertTrue(try repository.listCredentialRefs().isEmpty)
    try repository.close()
  }

  func testSQLiteFileContainsReferenceButNotSecretCanary() throws {
    // TC-003: after saving a credential, inspect the SQLite file for a
    // secret canary. Only the opaque reference may appear in the file.
    let databaseURL = try makeTemporaryDatabase()
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    let repository = try SQLiteHostRepository(databaseURL: databaseURL)

    let canarySecret = "mrw-sqlite-canary-\(UUID().uuidString)"
    let reference = try KeychainCredentialStore().create(
      secret: ProtectedSecret(data: Data(canarySecret.utf8)))
    defer { try? KeychainCredentialStore().delete(reference) }

    _ = try repository.createCredentialRef(
      label: "canary holder", kind: .password, keychainItemID: reference.encoded)
    try repository.close()

    let contents = try Data(contentsOf: databaseURL)
    XCTAssertFalse(
      contents.contains(Data(canarySecret.utf8)),
      "The secret canary must never reach SQLite (FR-004 / SEC-T07).")
    XCTAssertTrue(
      contents.contains(Data(reference.account.utf8)),
      "The opaque reference is expected in metadata records.")
  }

  // MARK: - Helpers

  func secretHandle() -> String {
    "not-a-valid-reference"
  }

  private func withSeparateConnection(
    databaseURL: URL, _ body: (OpaquePointer) throws -> Void
  ) throws {
    var database: OpaquePointer?
    let openStatus = sqlite3_open_v2(
      databaseURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
    guard openStatus == SQLITE_OK, let database else {
      if let database { sqlite3_close_v2(database) }
      throw SQLiteRepositoryError.sqlite(code: openStatus, message: "test connection failed")
    }
    defer { sqlite3_close_v2(database) }
    try exec(database, "PRAGMA foreign_keys = ON")
    try body(database)
  }

  @discardableResult
  private func exec(_ database: OpaquePointer, _ sql: String, _ values: [String] = []) throws -> Int32 {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw SQLiteRepositoryError.sqlite(
        code: sqlite3_errcode(database), message: String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    for (index, value) in values.enumerated() {
      _ = value.withCString {
        sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
      }
    }
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw SQLiteRepositoryError.sqlite(
        code: sqlite3_errcode(database), message: String(cString: sqlite3_errmsg(database)))
    }
    return sqlite3_changes(database)
  }
}
