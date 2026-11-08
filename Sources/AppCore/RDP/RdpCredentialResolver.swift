import Foundation

/// Resolved in-memory credentials for RDP NLA (CredSSP) authentication.
/// Secrets are never persisted in SQLite, argv, environment variables, or logs.
public struct RdpResolvedCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public let username: String
  public let domain: String?
  public let password: String

  public init(username: String, domain: String?, password: String) {
    self.username = username
    self.domain = domain
    self.password = password
  }

  public var description: String {
    let domainStr = domain.map { "'\($0)'" } ?? "nil"
    return "RdpResolvedCredentials(username: '\(username)', domain: \(domainStr), password: <REDACTED>)"
  }

  public var debugDescription: String {
    description
  }
}

/// Errors raised during RDP credential resolution.
public enum RdpCredentialError: Error, Equatable, AppCoreLocalizedError {
  case missingCredentialReference
  case invalidCredentialReference(String)
  case credentialNotFoundInKeychain
  case emptyPassword
  case emptyUsername
  case keychainAccessFailed(String)

  public func displayDescription(locale: Locale?) -> String? {
    switch self {
    case .missingCredentialReference:
      return AppCoreLocalization.string("An Apple Keychain credential reference is required for embedded RDP authentication.", locale: locale)
    case .invalidCredentialReference(let ref):
      return AppCoreLocalization.format("Invalid Keychain credential reference locator: '%1$@'.", ref, locale: locale)
    case .credentialNotFoundInKeychain:
      return AppCoreLocalization.string("The referenced credential was not found in Apple Keychain.", locale: locale)
    case .emptyPassword:
      return AppCoreLocalization.string("The resolved RDP password from Keychain is empty.", locale: locale)
    case .emptyUsername:
      return AppCoreLocalization.string("The RDP username cannot be empty.", locale: locale)
    case .keychainAccessFailed(let reason):
      return AppCoreLocalization.format("Apple Keychain credential access failed: %1$@", reason, locale: locale)
    }
  }
}

/// Protocol for resolving NLA credentials for RDP sessions.
public protocol RdpCredentialResolving: Sendable {
  func resolveCredentials(
    rawUsername: String,
    credentialRefID: String?
  ) throws -> RdpResolvedCredentials

  func parseUsernameAndDomain(from raw: String) -> (username: String, domain: String?)
}

/// Keychain-backed credential resolver for RDP connections.
public final class RdpCredentialResolver: RdpCredentialResolving, @unchecked Sendable {
  private let keychainStore: CredentialSecretStore
  private let credentialLookup: @Sendable (String) throws -> CredentialRefRecord?

  public init(
    keychainStore: CredentialSecretStore = KeychainCredentialStore(),
    credentialLookup: @escaping @Sendable (String) throws -> CredentialRefRecord?
  ) {
    self.keychainStore = keychainStore
    self.credentialLookup = credentialLookup
  }

  /// Parses raw username formats such as "DOMAIN\user" or "user@domain.corp".
  public func parseUsernameAndDomain(from raw: String) -> (username: String, domain: String?) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    
    // Check for "DOMAIN\user" format
    if let slashIndex = trimmed.firstIndex(of: "\\") {
      let domainPart = String(trimmed[..<slashIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
      let userPart = String(trimmed[trimmed.index(after: slashIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
      return (userPart, domainPart.isEmpty ? nil : domainPart)
    }

    // Check for "user@domain.corp" format (UPN)
    if let atIndex = trimmed.firstIndex(of: "@") {
      let userPart = String(trimmed[..<atIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
      let domainPart = String(trimmed[trimmed.index(after: atIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
      return (userPart, domainPart.isEmpty ? nil : domainPart)
    }

    return (trimmed, nil)
  }

  public func resolveCredentials(
    rawUsername: String,
    credentialRefID: String?
  ) throws -> RdpResolvedCredentials {
    let (username, domain) = parseUsernameAndDomain(from: rawUsername)
    guard !username.isEmpty else {
      throw RdpCredentialError.emptyUsername
    }

    guard let refID = credentialRefID, !refID.isEmpty else {
      throw RdpCredentialError.missingCredentialReference
    }

    guard let refRecord = try credentialLookup(refID) else {
      throw RdpCredentialError.invalidCredentialReference(refID)
    }

    guard let keychainRef = KeychainCredentialReference.decode(refRecord.keychainItemID) else {
      throw RdpCredentialError.invalidCredentialReference(refRecord.keychainItemID)
    }

    let secret: ProtectedSecret
    do {
      secret = try keychainStore.read(keychainRef)
    } catch CredentialStoreError.notFound {
      throw RdpCredentialError.credentialNotFoundInKeychain
    } catch let error as CredentialStoreError {
      throw RdpCredentialError.keychainAccessFailed(error.localizedDescription)
    } catch {
      throw RdpCredentialError.keychainAccessFailed(error.localizedDescription)
    }

    let password = secret.withBytes { bytes -> String in
      String(decoding: bytes, as: UTF8.self)
    } ?? ""

    guard !password.isEmpty else {
      throw RdpCredentialError.emptyPassword
    }

    return RdpResolvedCredentials(username: username, domain: domain, password: password)
  }
}
