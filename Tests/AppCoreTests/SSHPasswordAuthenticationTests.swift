import Foundation
import XCTest
@testable import AppCore

/// Tests SSH password authentication preparation, ephemeral and permanent Keychain lifecycle,
/// security bounds, and actionable failure reporting (US-005, US-008, FR-004, FR-005, SEC-T03, TC-006).
final class SSHPasswordAuthenticationTests: XCTestCase {

  private func makeCanary() -> ProtectedSecret {
    ProtectedSecret(data: Data("mrw-pass-canary-\(UUID().uuidString)".utf8))
  }

  private func bytes(_ secret: ProtectedSecret) -> [UInt8] {
    secret.withBytes { $0 } ?? []
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mrw-pass-test-\(UUID().uuidString)"
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  // MARK: - Ephemeral Password Lifecycle (US-008, FR-005, SEC-T03)

  func testEphemeralPasswordAuthenticationCreatesAndCleansUpKeychainItem() throws {
    let canary = makeCanary()
    let expectedBytes = bytes(canary)
    let keychainStore = KeychainCredentialStore()
    let service = SSHPasswordAuthenticationService(credentialStore: keychainStore)

    let prepared = try service.preparePasswordAuthentication(
      secret: canary,
      saveToKeychain: false,
      label: nil,
      defaultLabel: "test-host (testuser)"
    )

    XCTAssertNil(prepared.savedRecord, "Ephemeral mode must not produce a saved SQLite record.")
    guard let ephemeralRef = prepared.ephemeralReference else {
      XCTFail("Expected ephemeralReference to be created.")
      return
    }

    XCTAssertEqual(ephemeralRef.service, SSHPasswordAuthenticationService.ephemeralService)
    XCTAssertTrue(keychainStore.contains(ephemeralRef), "Ephemeral secret must exist in Keychain during session.")

    // Verify authentication configuration
    guard case .keychainAskpass(let svc, let acc, let identityFile) = prepared.authentication else {
      XCTFail("Expected keychainAskpass authentication.")
      return
    }
    XCTAssertEqual(svc, ephemeralRef.service)
    XCTAssertEqual(acc, ephemeralRef.account)
    XCTAssertNil(identityFile, "Password auth must not specify an identity file.")

    // Verify secret content is readable by reference
    let readSecret = try keychainStore.read(ephemeralRef)
    XCTAssertEqual(bytes(readSecret), expectedBytes)

    // Cleanup: must remove the ephemeral secret completely
    service.cleanupEphemeralCredential(ephemeralRef)
    XCTAssertFalse(keychainStore.contains(ephemeralRef), "Ephemeral secret must be deleted from Keychain on cleanup.")
    XCTAssertThrowsError(try keychainStore.read(ephemeralRef)) { error in
      XCTAssertEqual(error as? CredentialStoreError, .notFound)
    }
  }

  func testPurgeRemovesOnlyCredentialsInSelectedService() throws {
    let store = KeychainCredentialStore()
    let service = "com.macremoteworkspace.test.purge.\(UUID().uuidString)"
    let other = "\(service).other"
    let first = KeychainCredentialReference(service: service, account: "one")
    let second = KeychainCredentialReference(service: service, account: "two")
    let retained = KeychainCredentialReference(service: other, account: "one")
    defer { try? store.delete(first); try? store.delete(second); try? store.delete(retained) }
    try store.create(reference: first, secret: makeCanary())
    try store.create(reference: second, secret: makeCanary())
    try store.create(reference: retained, secret: makeCanary())
    try SSHPasswordAuthenticationService.purgeCredentials(service: service)
    XCTAssertFalse(store.contains(first))
    XCTAssertFalse(store.contains(second))
    XCTAssertTrue(store.contains(retained))
    try SSHPasswordAuthenticationService.purgeCredentials(service: service)
  }

  // MARK: - Permanent Password Storage (US-005, FR-004)

  func testPermanentPasswordAuthenticationPersistsToKeychainAndSQLite() throws {
    let tempDir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let dbURL = tempDir.appendingPathComponent("metadata.sqlite")

    let canary = makeCanary()
    let expectedBytes = bytes(canary)
    let keychainStore = KeychainCredentialStore()
    let service = SSHPasswordAuthenticationService(
      credentialStore: keychainStore,
      repositoryOpener: { try SQLiteHostRepository(databaseURL: dbURL) }
    )

    let prepared = try service.preparePasswordAuthentication(
      secret: canary,
      saveToKeychain: true,
      label: "Custom Prod Password",
      defaultLabel: "fallback-label"
    )

    XCTAssertNil(prepared.ephemeralReference, "Permanent mode must not produce an ephemeral reference.")
    guard let savedRecord = prepared.savedRecord else {
      XCTFail("Expected saved SQLite record.")
      return
    }

    XCTAssertEqual(savedRecord.label, "Custom Prod Password")
    XCTAssertEqual(savedRecord.kind, .password)

    guard let decodedRef = KeychainCredentialReference.decode(savedRecord.keychainItemID) else {
      XCTFail("Damaged keychain item id in saved record.")
      return
    }
    defer { try? keychainStore.delete(decodedRef) }

    XCTAssertTrue(keychainStore.contains(decodedRef), "Saved secret must exist in Keychain.")
    let readSecret = try keychainStore.read(decodedRef)
    XCTAssertEqual(bytes(readSecret), expectedBytes)

    // Verify record exists in SQLite repository
    let repo = try SQLiteHostRepository(databaseURL: dbURL)
    defer { try? repo.close() }
    let refs = try repo.listCredentialRefs()
    XCTAssertEqual(refs.count, 1)
    XCTAssertEqual(refs.first?.id, savedRecord.id)
    XCTAssertEqual(refs.first?.label, "Custom Prod Password")
  }

  func testPermanentPasswordRollsBackKeychainWhenSQLiteRegistrationFails() throws {
    let canary = makeCanary()
    let keychainStore = KeychainCredentialStore()

    struct TestError: Error, Equatable {}
    let failingService = SSHPasswordAuthenticationService(
      credentialStore: keychainStore,
      repositoryOpener: { throw TestError() }
    )

    XCTAssertThrowsError(
      try failingService.preparePasswordAuthentication(
        secret: canary,
        saveToKeychain: true,
        label: "Should Roll Back",
        defaultLabel: "default"
      )
    ) { error in
      XCTAssertTrue(error is TestError)
    }
  }

  // MARK: - Validation & Negative Cases (SEC-T03, TC-006)

  func testEmptyPasswordThrowsInvalidSecret() {
    let emptySecret = ProtectedSecret(data: Data())
    let service = SSHPasswordAuthenticationService()

    XCTAssertThrowsError(
      try service.preparePasswordAuthentication(
        secret: emptySecret,
        saveToKeychain: false,
        label: nil,
        defaultLabel: "default"
      )
    ) { error in
      XCTAssertEqual(error as? CredentialStoreError, .invalidSecret)
    }
  }

  func testPasswordAuthenticationBuildsStrictSSHArgumentsWithoutBatchMode() {
    let dummyKnownHosts = URL(fileURLWithPath: "/dev/null")
    let config = NativeSSHConfiguration(
      host: "127.0.0.1",
      port: 22,
      username: "deployer",
      knownHostsFileURL: dummyKnownHosts,
      authentication: .keychainAskpass(
        service: "com.macremoteworkspace.ephemeral",
        account: UUID().uuidString.lowercased(),
        identityFile: nil
      )
    )

    let args = NativeSSHSession.buildSSHArguments(for: config)
    let joined = args.joined(separator: " ")

    XCTAssertFalse(args.contains("BatchMode=yes"), "BatchMode would prevent askpass password prompting.")
    XCTAssertTrue(joined.contains("-o PasswordAuthentication=yes"))
    XCTAssertTrue(joined.contains("-o KbdInteractiveAuthentication=yes"))
    XCTAssertTrue(joined.contains("-o PreferredAuthentications=publickey,password,keyboard-interactive"))
    XCTAssertTrue(joined.contains("-o NumberOfPasswordPrompts=1"))
    XCTAssertTrue(joined.contains("-o IdentityFile=none"))
    XCTAssertTrue(joined.contains("-o IdentityAgent=none"))
    XCTAssertTrue(joined.contains("-o StrictHostKeyChecking=yes"))
  }

  // MARK: - Actionable Failure Reporting (FR-005, FR-008)

  func testEvaluateTerminationDetectsPermissionDeniedAsAuthFailure() {
    let output = "Permission denied (publickey,password,keyboard-interactive).\r\n"
    let result = SSHPasswordAuthenticationService.evaluateTermination(
      exitCode: 255,
      terminalOutput: output
    )
    XCTAssertTrue(result.isAuthFailure)
    XCTAssertTrue(result.userFacingMessage.contains("Authentication failed"))
    XCTAssertTrue(result.userFacingMessage.contains("Check your username and password, then retry."))
  }

  func testEvaluateTerminationDetectsAuthenticationFailedString() {
    let output = "ssh: Authentication failed for deployer\n"
    let result = SSHPasswordAuthenticationService.evaluateTermination(
      exitCode: 255,
      terminalOutput: output
    )
    XCTAssertTrue(result.isAuthFailure)
    XCTAssertTrue(result.userFacingMessage.contains("Authentication failed"))
  }

  func testEvaluateTerminationTreatsNormalDisconnectsAsNonAuth() {
    let resultNormal = SSHPasswordAuthenticationService.evaluateTermination(
      exitCode: 0,
      terminalOutput: "Connection to 127.0.0.1 closed.\n"
    )
    XCTAssertFalse(resultNormal.isAuthFailure)
    XCTAssertEqual(resultNormal.userFacingMessage, "Disconnected (exit code: 0)")

    let resultSigint = SSHPasswordAuthenticationService.evaluateTermination(
      exitCode: 130,
      terminalOutput: ""
    )
    XCTAssertFalse(resultSigint.isAuthFailure)
    XCTAssertEqual(resultSigint.userFacingMessage, "Disconnected (exit code: 130)")
  }
}
