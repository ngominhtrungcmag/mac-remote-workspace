import Foundation
import XCTest
@testable import AppCore

final class KeychainCredentialStoreTests: XCTestCase {
  private func makeCanary() -> ProtectedSecret {
    ProtectedSecret(data: Data("mrw-canary-\(UUID().uuidString)".utf8))
  }

  private func bytes(_ secret: ProtectedSecret) -> [UInt8] {
    secret.withBytes { $0 } ?? []
  }

  func testCreateReadRoundTripUsesOpaqueReference() throws {
    let store = KeychainCredentialStore()
    let canary = makeCanary()
    let expected = bytes(canary)

    let reference = try store.create(secret: canary)
    defer { try? store.delete(reference) }

    XCTAssertEqual(reference.service, "com.macremoteworkspace.credentials")
    XCTAssertTrue(KeychainCredentialReference.isValid(service: reference.service, account: reference.account))
    XCTAssertTrue(store.contains(reference))

    let readBack = try store.read(reference)
    XCTAssertEqual(bytes(readBack), expected, "Keychain round trip must preserve the secret bytes.")
  }

  func testDeleteRemovesTheSecretAndThenReportsNotFound() throws {
    let store = KeychainCredentialStore()
    let reference = try store.create(secret: makeCanary())
    XCTAssertTrue(store.contains(reference))
    try store.delete(reference)
    XCTAssertFalse(store.contains(reference))
    XCTAssertThrowsError(try store.read(reference)) { error in
      XCTAssertEqual(error as? CredentialStoreError, .notFound)
    }
    XCTAssertThrowsError(try store.delete(reference)) { error in
      XCTAssertEqual(error as? CredentialStoreError, .notFound)
    }
  }

  func testReplaceSecretThenReadNewValueOnly() throws {
    let store = KeychainCredentialStore()
    let reference = try store.create(secret: makeCanary())
    defer { try? store.delete(reference) }

    let replacement = makeCanary()
    let expectedReplacement = bytes(replacement)
    try store.update(reference, secret: replacement)

    let readBack = try store.read(reference)
    XCTAssertEqual(bytes(readBack), expectedReplacement)

    let referenceAgain = try store.create(secret: makeCanary())
    defer { try? store.delete(referenceAgain) }
    XCTAssertNotEqual(reference.account, referenceAgain.account)
  }

  func testInvalidSecretsAndReferencesAreRejectedWithoutKeychainWrites() throws {
    let store = KeychainCredentialStore()
    XCTAssertThrowsError(try store.create(secret: ProtectedSecret(bytes: []))) { error in
      XCTAssertEqual(error as? CredentialStoreError, .invalidSecret)
    }
    XCTAssertThrowsError(
      try store.create(secret: ProtectedSecret(bytes: [UInt8](repeating: 0x41, count: 5000)))
    ) { error in
      XCTAssertEqual(error as? CredentialStoreError, .invalidSecret)
    }
    let invalid = KeychainCredentialReference(service: "svc", account: "with space")
    XCTAssertThrowsError(try store.read(invalid)) { error in
      XCTAssertEqual(error as? CredentialStoreError, .invalidReference)
    }
    XCTAssertFalse(store.contains(invalid))
  }

  func testReferenceEncodingRoundTripRejectsDamagedMetadata() {
    let reference = KeychainCredentialStore.freshReference()
    let encoded = reference.encoded
    XCTAssertEqual(KeychainCredentialReference.decode(encoded), reference)

    XCTAssertNil(KeychainCredentialReference.decode("no-separator"))
    XCTAssertNil(KeychainCredentialReference.decode("svc/"))
    XCTAssertNil(KeychainCredentialReference.decode("/account"))
    XCTAssertNil(KeychainCredentialReference.decode("svc /account"))
    XCTAssertNil(KeychainCredentialReference.decode("svc/\naccount"))
  }

  func testProtectedSecretAllowsRepeatedScopedReadsAndNeedsExplicitScope() throws {
    let secret = ProtectedSecret(data: Data("short-lived".utf8))
    let firstRead = secret.withBytes { bytes -> [UInt8] in
      XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "short-lived")
      return bytes
    }
    XCTAssertNotNil(firstRead)
    // Repeated reads inside one authentication operation are supported;
    // zeroing happens best-effort when the operation scope drops ownership.
    let secondRead = secret.withBytes { bytes -> [UInt8] in bytes }
    XCTAssertEqual(firstRead, secondRead)
  }

  func testKeychainReferenceValidationGuardsMetadataOnlyValues() {
    XCTAssertTrue(KeychainCredentialReference.isValid(
      service: "com.macremoteworkspace.credentials", account: "70ED860A-6D32-4326-9D42-B6E5B2E9411C"))
    XCTAssertFalse(KeychainCredentialReference.isValid(service: "", account: "x"))
    XCTAssertFalse(KeychainCredentialReference.isValid(service: "svc", account: ""))
    XCTAssertFalse(KeychainCredentialReference.isValid(service: "svc", account: "a\nb"))
    XCTAssertFalse(KeychainCredentialReference.isValid(service: " svc", account: "a"))
    XCTAssertFalse(KeychainCredentialReference.isValid(service: "svc ", account: "a"))
    XCTAssertFalse(KeychainCredentialReference.isValid(
      service: String(repeating: "a", count: 300), account: "a"))
  }
}

final class KeychainFailureHandlingTests: XCTestCase {
  func testOSStatusMapsToTypedErrors() {
    XCTAssertNil(KeychainCredentialStore.map(status: errSecSuccess))
    XCTAssertEqual(KeychainCredentialStore.map(status: errSecItemNotFound), .notFound)
    for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled] {
      XCTAssertEqual(KeychainCredentialStore.map(status: status), .deniedOrLocked(status))
    }
    XCTAssertEqual(KeychainCredentialStore.map(status: errSecParam), .unexpected(errSecParam))
  }

  func testUserFacingMessagesDistinguishCancelLockedDenied() {
    let msgs = [errSecUserCanceled, errSecInteractionNotAllowed, errSecAuthFailed].map {
      CredentialStoreError.deniedOrLocked($0).errorDescription ?? ""
    }
    XCTAssertEqual(Set(msgs).count, 3)
    XCTAssertTrue(msgs[0].contains("cancelled"))
    XCTAssertTrue(msgs[1].contains("locked"))
  }

  func testMissingFIFOThroughAskpassScriptExitsNonZeroWithEmptyStdout() throws {
    // Same command the askpass helper execs; ssh treats non-zero as aborted prompt (no empty password).
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", KeychainAskpassHelper.scriptContents]
    p.environment = [
      "MRW_ASKPASS_FIFO": "/tmp/mrw-missing-\(UUID().uuidString)",
    ]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    try p.run()
    p.waitUntilExit()
    XCTAssertNotEqual(p.terminationStatus, 0)
    XCTAssertTrue(out.fileHandleForReading.readDataToEndOfFile().isEmpty)
  }
}
