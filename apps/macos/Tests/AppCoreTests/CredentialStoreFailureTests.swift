import Foundation
import XCTest
@testable import AppCore

private final class FailingStore: CredentialSecretStore, @unchecked Sendable {
  let error: CredentialStoreError
  private(set) var createCalls = 0
  init(_ error: CredentialStoreError) { self.error = error }
  func create(secret: ProtectedSecret) throws -> KeychainCredentialReference { createCalls += 1; throw error }
  func create(reference: KeychainCredentialReference, secret: ProtectedSecret) throws { createCalls += 1; throw error }
  func read(_ r: KeychainCredentialReference) throws -> ProtectedSecret { throw error }
  func update(_ r: KeychainCredentialReference, secret: ProtectedSecret) throws { throw error }
  func delete(_ r: KeychainCredentialReference) throws { throw error }
  func contains(_ r: KeychainCredentialReference) -> Bool { false }
}

final class CredentialStoreFailureTests: XCTestCase {
  func testSaveAbortsWithTypedErrorAndNeverOpensRepository() {
    for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled] {
      let store = FailingStore(.deniedOrLocked(status))
      let opened = NSLock()
      nonisolated(unsafe) var repoOpened = false
      let service = SSHPasswordAuthenticationService(credentialStore: store) {
        opened.lock(); repoOpened = true; opened.unlock()
        throw CredentialStoreError.unexpected(0)
      }
      XCTAssertThrowsError(
        try service.preparePasswordAuthentication(
          secret: ProtectedSecret(bytes: Array("pw".utf8)), saveToKeychain: true, label: "x", defaultLabel: "d")
      ) { XCTAssertEqual($0 as? CredentialStoreError, .deniedOrLocked(status)) }
      XCTAssertEqual(store.createCalls, 1)
      XCTAssertFalse(repoOpened, "No metadata may be written when Keychain denies access.")
    }
  }

  func testEphemeralPathAbortsOnDeniedLockedCancelledWithoutLeak() {
    for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled] {
      let store = FailingStore(.deniedOrLocked(status))
      let service = SSHPasswordAuthenticationService(credentialStore: store) {
        XCTFail("Repository must not be opened on the ephemeral path")
        throw CredentialStoreError.unexpected(0)
      }
      let marker = "s3cr3t-marker"
      XCTAssertThrowsError(
        try service.preparePasswordAuthentication(
          secret: ProtectedSecret(bytes: Array(marker.utf8)), saveToKeychain: false, label: nil, defaultLabel: "d")
      ) { error in
        XCTAssertEqual(error as? CredentialStoreError, .deniedOrLocked(status))
        XCTAssertFalse("\(error) \(error.localizedDescription)".contains(marker))
      }
      XCTAssertEqual(store.createCalls, 1, "Must route through the injected store, once, with no retry.")
    }
  }

  func testMissingItemSurfacesNotFound() {
    XCTAssertThrowsError(try FailingStore(.notFound).read(KeychainCredentialReference(service: "s", account: "a"))) {
      XCTAssertEqual($0 as? CredentialStoreError, .notFound)
    }
  }
}
