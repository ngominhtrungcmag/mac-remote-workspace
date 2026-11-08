import Foundation
import Security

/// Result of preparing password authentication for an SSH connection.
public struct PreparedPasswordAuthentication: Sendable, Equatable {
  public let authentication: NativeSSHAuthentication
  public let ephemeralReference: KeychainCredentialReference?
  public let savedRecord: CredentialRefRecord?

  public init(
    authentication: NativeSSHAuthentication,
    ephemeralReference: KeychainCredentialReference? = nil,
    savedRecord: CredentialRefRecord? = nil
  ) {
    self.authentication = authentication
    self.ephemeralReference = ephemeralReference
    self.savedRecord = savedRecord
  }
}

/// Typed service protocol managing password preparation, ephemeral Keychain items,
/// and persistent credential storage for SSH sessions (US-005, US-008, FR-004, FR-005, SEC-T03).
public protocol SSHPasswordAuthenticationServiceProtocol: AnyObject, Sendable {
  /// Prepares an authentication credential for an SSH session.
  /// If saveToKeychain is true, persists to Keychain and registers reference in SQLite repository.
  /// If saveToKeychain is false, creates a short-lived ephemeral Keychain item.
  func preparePasswordAuthentication(
    secret: ProtectedSecret,
    saveToKeychain: Bool,
    label: String?,
    defaultLabel: String
  ) throws -> PreparedPasswordAuthentication

  /// Deletes an ephemeral Keychain item previously created for a session.
  func cleanupEphemeralCredential(_ reference: KeychainCredentialReference)
}

/// Concrete implementation of SSHPasswordAuthenticationServiceProtocol.
public final class SSHPasswordAuthenticationService: SSHPasswordAuthenticationServiceProtocol, @unchecked Sendable {
  public static let ephemeralService = "com.macremoteworkspace.ephemeral"
  private let credentialStore: CredentialSecretStore
  private let repositoryOpener: @Sendable () throws -> SQLiteHostRepository

  public init(
    credentialStore: CredentialSecretStore = KeychainCredentialStore(),
    repositoryOpener: @escaping @Sendable () throws -> SQLiteHostRepository = { try SQLiteHostRepository.openApplicationRepository() }
  ) {
    self.credentialStore = credentialStore
    self.repositoryOpener = repositoryOpener
  }

  public static func purgeEphemeralCredentials() throws {
    try purgeCredentials(service: ephemeralService)
  }

  static func purgeCredentials(service: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CredentialStoreError.unexpected(status)
    }
  }

  public func preparePasswordAuthentication(
    secret: ProtectedSecret,
    saveToKeychain: Bool,
    label: String?,
    defaultLabel: String
  ) throws -> PreparedPasswordAuthentication {
    guard let bytes = secret.withBytes({ $0 }), !bytes.isEmpty else {
      throw CredentialStoreError.invalidSecret
    }

    if saveToKeychain {
      // 1. Save permanently to Keychain
      let reference = try credentialStore.create(secret: secret)

      // 2. Register metadata in SQLite repository
      let effectiveLabel: String
      let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !trimmed.isEmpty {
        effectiveLabel = trimmed
      } else {
        effectiveLabel = defaultLabel
      }

      do {
        let repository = try repositoryOpener()
        defer { try? repository.close() }
        let record = try repository.createCredentialRef(
          label: effectiveLabel,
          kind: .password,
          keychainItemID: reference.encoded
        )
        return PreparedPasswordAuthentication(
          authentication: .keychainAskpass(
            service: reference.service,
            account: reference.account,
            identityFile: nil
          ),
          ephemeralReference: nil,
          savedRecord: record
        )
      } catch {
        // Roll back Keychain item if SQLite registration fails to avoid orphaned secrets
        try? credentialStore.delete(reference)
        throw error
      }
    } else {
      // Ephemeral session-scoped item: unique UUID account under ephemeral service namespace
      let ephemeralRef = KeychainCredentialReference(
        service: Self.ephemeralService,
        account: UUID().uuidString.lowercased()
      )
      try credentialStore.create(reference: ephemeralRef, secret: secret)
      return PreparedPasswordAuthentication(
        authentication: .keychainAskpass(
          service: ephemeralRef.service,
          account: ephemeralRef.account,
          identityFile: nil
        ),
        ephemeralReference: ephemeralRef,
        savedRecord: nil
      )
    }
  }

  public func cleanupEphemeralCredential(_ reference: KeychainCredentialReference) {
    guard reference.service == Self.ephemeralService else { return }
    try? credentialStore.delete(reference)
  }

  /// Evaluates process termination status and output to provide actionable user diagnostic.
  public static func evaluateTermination(
    exitCode: Int32,
    terminalOutput: String
  ) -> (isAuthFailure: Bool, userFacingMessage: String) {
    let lower = terminalOutput.lowercased()
    if exitCode == 255 && (lower.contains("permission denied") || lower.contains("authentication failed")) {
      return (
        true,
        "Authentication failed: remote host rejected credentials (exit code: 255). Check your username and password, then retry."
      )
    }
    return (false, "Disconnected (exit code: \(exitCode))")
  }
}
