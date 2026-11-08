import Darwin
import Foundation

/// Opaque metadata reference for one Keychain generic-password item.
///
/// The reference contains no secret material. `service` groups all app items,
/// `account` is an opaque, app-generated identifier stored only in SQLite
/// metadata (FR-004).
public struct KeychainCredentialReference: Sendable, Equatable, Hashable {
  public let service: String
  public let account: String

  public init(service: String, account: String) {
    self.service = service
    self.account = account
  }

  /// Stable serialization for SQLite metadata (never contains the secret).
  public var encoded: String { "\(service)/\(account)" }

  public static func decode(_ encoded: String) -> Self? {
    let parts = encoded.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    let service = String(parts[0])
    let account = String(parts[1])
    return Self.isValid(service: service, account: account) ? Self(service: service, account: account) : nil
  }

  static func isValid(service: String, account: String) -> Bool {
    guard !service.isEmpty, service.utf8.count <= 256, !account.isEmpty, account.utf8.count <= 256 else {
      return false
    }
    let forbiddenCharacters = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
    let first = String(service.prefix(1))
    let last = String(account.prefix(1))
    guard first == first.trimmingCharacters(in: .whitespacesAndNewlines),
      last == last.trimmingCharacters(in: .whitespacesAndNewlines)
    else {
      return false
    }
    return service.rangeOfCharacter(from: forbiddenCharacters) == nil
      && account.rangeOfCharacter(from: forbiddenCharacters) == nil
  }
}

/// Container for a short-lived secret value. Lifetime is bounded by the
/// explicit scope of an authentication operation; content is best-effort
/// zeroed when the object is deinitialized. It performs no plaintext
/// fallback and never logs its bytes (SEC-T07).
public final class ProtectedSecret: @unchecked Sendable {
  private var bytes: [UInt8]
  private var isConsumed = false

  public init(bytes: [UInt8]) {
    self.bytes = bytes
  }

  public convenience init(data: Data) {
    self.init(bytes: [UInt8](data))
  }

  var byteCount: Int { bytes.count }

  /// Grants access to the secret bytes for the requested operation. Reads
  /// may repeat while the object is alive; zeroing is best-effort on deinit.
  public func withBytes<T>(_ body: ([UInt8]) throws -> T) rethrows -> T? {
    guard !isConsumed else { return nil }
    return try body(bytes)
  }

  private func consume() {
    isConsumed = true
    for index in bytes.indices where bytes[index] != 0 {
      bytes[index] = 0
    }
  }

  deinit {
    consume()
  }
}

extension ProtectedSecret: Equatable {
  public static func == (lhs: ProtectedSecret, rhs: ProtectedSecret) -> Bool {
    lhs.withBytes { lhsBytes in
      rhs.withBytes { rhsBytes in
        lhsBytes == rhsBytes
      } ?? false
    } ?? false
  }
}

public enum CredentialStoreError: Error, Equatable, AppCoreLocalizedError {
  /// macOS could not address the Keychain at all (unavailable environment).
  case unavailable(OSStatus)
  /// Access denied, user rejected, Keychain locked, or interaction refused.
  case deniedOrLocked(OSStatus)
  /// The referenced item no longer exists.
  case notFound
  /// An item with the same reference already exists.
  case duplicate
  /// The provided reference or bytes are unusable.
  case invalidReference
  case invalidSecret
  case unexpected(OSStatus)

  public func displayDescription(locale: Locale?) -> String? {
    switch self {
    case .unavailable:
      return AppCoreLocalization.string("The macOS Keychain is unavailable in this environment.", locale: locale)
    case .deniedOrLocked(let status):
      switch status {
      case errSecUserCanceled:
        return AppCoreLocalization.string("Keychain access was cancelled. No credential was used.", locale: locale)
      case errSecInteractionNotAllowed:
        return AppCoreLocalization.string("The Keychain is locked or cannot prompt right now. Unlock it and retry.", locale: locale)
      default:
        return AppCoreLocalization.string("Access to the saved credential was denied. Allow access in the Keychain prompt and retry.", locale: locale)
      }
    case .notFound:
      return AppCoreLocalization.string("The referenced credential no longer exists in the Keychain.", locale: locale)
    case .duplicate:
      return AppCoreLocalization.string("A credential with this reference already exists.", locale: locale)
    case .invalidReference:
      return AppCoreLocalization.string("The credential reference is invalid.", locale: locale)
    case .invalidSecret:
      return AppCoreLocalization.string("The credential value is empty or too large to store.", locale: locale)
    case .unexpected(let status):
      return AppCoreLocalization.format("Keychain operation failed (OSStatus %1$@).", String(status), locale: locale)
    }
  }
}

/// Typed contract for the Keychain-backed secret store (FR-004).
/// Implementations must never fall back to plaintext storage.
public protocol CredentialSecretStore: AnyObject, Sendable {
  func create(secret: ProtectedSecret) throws -> KeychainCredentialReference
  /// Stores a secret under a caller-chosen reference (e.g. ephemeral session items).
  func create(reference: KeychainCredentialReference, secret: ProtectedSecret) throws
  func read(_ reference: KeychainCredentialReference) throws -> ProtectedSecret
  func update(_ reference: KeychainCredentialReference, secret: ProtectedSecret) throws
  func delete(_ reference: KeychainCredentialReference) throws
  func contains(_ reference: KeychainCredentialReference) -> Bool
}

/// Concrete Keychain generic-password store implementation.
public final class KeychainCredentialStore: CredentialSecretStore, @unchecked Sendable {
  private static let maximumSecretBytes = 4096
  private static let defaultService = "com.macremoteworkspace.credentials"

  public init() {}

  /// Creates a fresh opaque reference in the app's Keychain service namespace.
  public static func freshReference() -> KeychainCredentialReference {
    KeychainCredentialReference(service: defaultService, account: UUID().uuidString)
  }

  public func create(secret: ProtectedSecret) throws -> KeychainCredentialReference {
    let reference = Self.freshReference()
    try create(reference: reference, secret: secret)
    return reference
  }

  public func create(reference: KeychainCredentialReference, secret: ProtectedSecret) throws {
    guard Self.isValidReference(reference) else { throw CredentialStoreError.invalidReference }
    var query = Self.baseQuery(for: reference)
    query[kSecValueData as String] = try Self.secretBytes(secret)
    query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    var status: OSStatus = errSecSuccess
    withExtendedLifetime(query) {
      status = SecItemAdd(query as CFDictionary, nil)
    }
    let mapped = Self.map(status: status)
    if let mapped { throw mapped }
  }

  public func read(_ reference: KeychainCredentialReference) throws -> ProtectedSecret {
    guard Self.isValidReference(reference) else { throw CredentialStoreError.invalidReference }
    var query = Self.baseQuery(for: reference)
    query[kSecReturnData as String] = true as CFBoolean
    var item: CFTypeRef?
    var status = errSecSuccess
    withExtendedLifetime(query) {
      status = SecItemCopyMatching(query as CFDictionary, &item)
    }
    if let mapped = Self.map(status: status) { throw mapped }
    guard let data = item as? Data else {
      throw CredentialStoreError.unexpected(errSecSuccess)
    }
    return ProtectedSecret(data: data)
  }

  public func update(_ reference: KeychainCredentialReference, secret: ProtectedSecret) throws {
    guard Self.isValidReference(reference) else { throw CredentialStoreError.invalidReference }
    var attributes: [String: Any] = [
      kSecValueData as String: try Self.secretBytes(secret),
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let query = Self.baseQuery(for: reference)
    var status = errSecSuccess
    withExtendedLifetime(query) {
      withExtendedLifetime(attributes) {
        status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
      }
    }
    if let mapped = Self.map(status: status) { throw mapped }
    attributes.removeAll()
  }

  public func delete(_ reference: KeychainCredentialReference) throws {
    guard Self.isValidReference(reference) else { throw CredentialStoreError.invalidReference }
    let query = Self.baseQuery(for: reference)
    var status = errSecSuccess
    withExtendedLifetime(query) {
      status = SecItemDelete(query as CFDictionary)
    }
    if let mapped = Self.map(status: status) { throw mapped }
  }

  public func contains(_ reference: KeychainCredentialReference) -> Bool {
    guard Self.isValidReference(reference) else { return false }
    let query = Self.baseQuery(for: reference)
    var status = errSecSuccess
    withExtendedLifetime(query) {
      status = SecItemCopyMatching(query as CFDictionary, nil)
    }
    return status == errSecSuccess
  }

  // MARK: - Internals

  private static func baseQuery(
    for reference: KeychainCredentialReference
  ) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: reference.service,
      kSecAttrAccount as String: reference.account,
    ]
  }

  private static func isValidReference(_ reference: KeychainCredentialReference) -> Bool {
    KeychainCredentialReference.isValid(service: reference.service, account: reference.account)
  }

  private static func secretBytes(_ secret: ProtectedSecret) throws -> Data {
    guard let bytes = secret.withBytes({ $0 }) else {
      throw CredentialStoreError.invalidSecret
    }
    guard !bytes.isEmpty else { throw CredentialStoreError.invalidSecret }
    guard bytes.count <= maximumSecretBytes else { throw CredentialStoreError.invalidSecret }
    return Data(bytes)
  }

  static func map(status: OSStatus) -> CredentialStoreError? {
    switch status {
    case errSecSuccess: return nil
    case errSecItemNotFound: return .notFound
    case errSecDuplicateItem: return .duplicate
    case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled,
      errSecMissingEntitlement:
      return .deniedOrLocked(status)
    default:
      return .unexpected(status)
    }
  }
}
