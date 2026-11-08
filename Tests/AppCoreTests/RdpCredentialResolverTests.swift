import Foundation
import XCTest

@testable import AppCore

private final class MockCredentialSecretStore: CredentialSecretStore, @unchecked Sendable {
  var storage: [KeychainCredentialReference: ProtectedSecret] = [:]

  func create(secret: ProtectedSecret) throws -> KeychainCredentialReference {
    let ref = KeychainCredentialStore.freshReference()
    storage[ref] = secret
    return ref
  }

  func create(reference: KeychainCredentialReference, secret: ProtectedSecret) throws {
    storage[reference] = secret
  }

  func read(_ reference: KeychainCredentialReference) throws -> ProtectedSecret {
    guard let secret = storage[reference] else {
      throw CredentialStoreError.notFound
    }
    return secret
  }

  func delete(_ reference: KeychainCredentialReference) throws {
    storage.removeValue(forKey: reference)
  }

  func contains(_ reference: KeychainCredentialReference) -> Bool {
    storage[reference] != nil
  }

  func update(_ reference: KeychainCredentialReference, secret: ProtectedSecret) throws {
    storage[reference] = secret
  }
}

final class RdpCredentialResolverTests: XCTestCase {
  func testParseUsernameAndDomain() {
    let resolver = RdpCredentialResolver(keychainStore: MockCredentialSecretStore()) { _ in nil }

    // DOMAIN\user format
    let result1 = resolver.parseUsernameAndDomain(from: #"CORP\Administrator"#)
    XCTAssertEqual(result1.username, "Administrator")
    XCTAssertEqual(result1.domain, "CORP")

    // user@domain format
    let result2 = resolver.parseUsernameAndDomain(from: "admin@corp.example.com")
    XCTAssertEqual(result2.username, "admin")
    XCTAssertEqual(result2.domain, "corp.example.com")

    // simple username
    let result3 = resolver.parseUsernameAndDomain(from: "Administrator")
    XCTAssertEqual(result3.username, "Administrator")
    XCTAssertNil(result3.domain)

    // whitespace trimming
    let result4 = resolver.parseUsernameAndDomain(from: #"  MYDOMAIN\jdoe  "#)
    XCTAssertEqual(result4.username, "jdoe")
    XCTAssertEqual(result4.domain, "MYDOMAIN")
  }

  func testResolvesCredentialsSecurelyFromKeychain() throws {
    let mockKeychain = MockCredentialSecretStore()
    let secret = ProtectedSecret(data: Data("SuperSecretPassword123!".utf8))
    let keychainRef = try mockKeychain.create(secret: secret)

    let refRecord = CredentialRefRecord(
      id: "cred-01",
      label: "Win Password",
      kind: .password,
      keychainItemID: keychainRef.encoded
    )

    let resolver = RdpCredentialResolver(keychainStore: mockKeychain) { id in
      id == "cred-01" ? refRecord : nil
    }

    let resolved = try resolver.resolveCredentials(
      rawUsername: #"CORP\Administrator"#,
      credentialRefID: "cred-01"
    )

    XCTAssertEqual(resolved.username, "Administrator")
    XCTAssertEqual(resolved.domain, "CORP")
    XCTAssertEqual(resolved.password, "SuperSecretPassword123!")

    // Verify Password Redaction in CustomStringConvertible (Confidentiality)
    let desc = resolved.description
    XCTAssertFalse(desc.contains("SuperSecretPassword123!"))
    XCTAssertTrue(desc.contains("<REDACTED>"))
    XCTAssertEqual(resolved.debugDescription, desc)
  }

  func testMissingOrInvalidCredentialThrows() throws {
    let resolver = RdpCredentialResolver(keychainStore: MockCredentialSecretStore()) { _ in nil }

    // Missing credential ref ID
    XCTAssertThrowsError(try resolver.resolveCredentials(rawUsername: "admin", credentialRefID: nil)) { error in
      XCTAssertEqual(error as? RdpCredentialError, .missingCredentialReference)
    }

    // Unfound credential ref
    XCTAssertThrowsError(try resolver.resolveCredentials(rawUsername: "admin", credentialRefID: "unknown-id")) { error in
      XCTAssertEqual(error as? RdpCredentialError, .invalidCredentialReference("unknown-id"))
    }
  }
}
