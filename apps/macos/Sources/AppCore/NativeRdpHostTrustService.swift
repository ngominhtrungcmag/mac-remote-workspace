import Foundation

/// Represents a trusted or presented Windows Server RDP TLS/X.509 certificate.
public struct RdpCertificateRecord: Sendable, Equatable, Identifiable, Hashable {
  public var id: String { "\(host):\(port)" }
  public let host: String
  public let port: Int
  /// 64-character hexadecimal SHA-256 fingerprint (canonical uppercase).
  public let sha256Fingerprint: String
  public let subjectCN: String
  public let issuerCN: String
  public let createdAt: Date
  public let updatedAt: Date
  public let version: Int64

  public var formattedFingerprint: String {
    // Return colon-separated uppercase hex pairs, e.g. "AA:BB:CC:..."
    stride(from: 0, to: sha256Fingerprint.count, by: 2).map { offset in
      let start = sha256Fingerprint.index(sha256Fingerprint.startIndex, offsetBy: offset)
      let end = sha256Fingerprint.index(start, offsetBy: min(2, sha256Fingerprint.distance(from: start, to: sha256Fingerprint.endIndex)))
      return String(sha256Fingerprint[start..<end])
    }.joined(separator: ":")
  }

  public init(
    host: String,
    port: Int,
    sha256Fingerprint: String,
    subjectCN: String,
    issuerCN: String,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    version: Int64 = 1
  ) {
    self.host = host
    self.port = port
    self.sha256Fingerprint = sha256Fingerprint.uppercased()
    self.subjectCN = subjectCN
    self.issuerCN = issuerCN
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.version = version
  }
}

/// Evaluation result of an RDP server TLS certificate against recorded host trust.
public enum RdpHostTrustStatus: Sendable, Equatable {
  /// The presented certificate strictly matches the recorded trust fingerprint.
  case trusted(matched: RdpCertificateRecord)
  /// First time connecting to this host/port; requires user confirmation (TOFU).
  case unknown(challenge: RdpCertificateTrustChallenge)
  /// The presented certificate fingerprint differs from the recorded fingerprint.
  /// Hard block — connection must not proceed (MITM defense).
  case mismatch(recorded: RdpCertificateRecord, presented: RdpCertificateRecord)
}

/// An ephemeral challenge generated when an unknown certificate is encountered.
public struct RdpCertificateTrustChallenge: Sendable, Equatable, Identifiable {
  public let id: UUID
  public let host: String
  public let port: Int
  public let presentedCertificate: RdpCertificateRecord
  public let nonce: String
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    host: String,
    port: Int,
    presentedCertificate: RdpCertificateRecord,
    nonce: String = UUID().uuidString,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.host = host
    self.port = port
    self.presentedCertificate = presentedCertificate
    self.nonce = nonce
    self.createdAt = createdAt
  }
}

/// Typed errors for RDP certificate trust operations.
public enum RdpCertificateTrustError: Error, Equatable, AppCoreLocalizedError {
  case invalidHost(String)
  case invalidPort(Int)
  case invalidFingerprint(String)
  case challengeExpired
  case challengeNonceMismatch
  case mismatchBlocked(details: String)
  case persistenceFailed(String)

  public func displayDescription(locale: Locale?) -> String? {
    switch self {
    case .invalidHost(let host):
      return AppCoreLocalization.format("Invalid RDP host: '%1$@'.", host, locale: locale)
    case .invalidPort(let port):
      return AppCoreLocalization.format("Invalid RDP port: %1$@. Port must be between 1 and 65535.", String(port), locale: locale)
    case .invalidFingerprint(let fp):
      return AppCoreLocalization.format("Invalid SHA-256 fingerprint '%1$@'. Must be a 64-character hexadecimal string.", fp, locale: locale)
    case .challengeExpired:
      return AppCoreLocalization.string("The certificate trust challenge has expired. Please retry connection.", locale: locale)
    case .challengeNonceMismatch:
      return AppCoreLocalization.string("Certificate challenge nonce verification failed.", locale: locale)
    case .mismatchBlocked(let details):
      return AppCoreLocalization.format("Strict RDP certificate verification failed: %1$@. Connection blocked to prevent potential MITM attack.", details, locale: locale)
    case .persistenceFailed(let message):
      return AppCoreLocalization.format("Failed to persist RDP host trust record: %1$@", message, locale: locale)
    }
  }
}

/// Protocol for evaluating and managing RDP server certificate trust.
public protocol RdpHostCertificateVerifier: Sendable {
  func evaluateTrust(
    host: String,
    port: Int,
    presented: RdpCertificateRecord
  ) async throws -> RdpHostTrustStatus

  func approveChallenge(_ challenge: RdpCertificateTrustChallenge) async throws
  func revokeTrust(host: String, port: Int) async throws
  func listTrustedCertificates() async throws -> [RdpCertificateRecord]
}

/// Default implementation of RDP host certificate trust verification with SQLite persistence.
public actor NativeRdpCertificateTrustService: RdpHostCertificateVerifier {
  private let repository: RdpHostTrustRepository
  private var activeChallenges: [UUID: RdpCertificateTrustChallenge] = [:]
  public static let challengeValiditySeconds: TimeInterval = 300 // 5 minutes

  public init(repository: RdpHostTrustRepository) {
    self.repository = repository
  }

  /// Metadata-only audit + log; audits only when the repository is also an AuditRepository (SQLite).
  private func record(_ action: String, _ host: String, _ port: Int, _ outcome: AuditOutcome = .success, _ code: String? = nil) {
    RedactedLogger.shared.info("rdp", "\(action) \(host):\(port) \(outcome.rawValue)")
    try? (repository as? AuditRepository)?.recordAuditEvent(
      action: action, entityType: "rdp_cert", entityID: "\(host):\(port)", outcome: outcome, errorCode: code)
  }

  // MARK: - Validation

  public static func validateHost(_ host: String) throws -> String {
    let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw RdpCertificateTrustError.invalidHost("Host cannot be empty.")
    }
    guard !trimmed.hasPrefix("-") else {
      throw RdpCertificateTrustError.invalidHost("Host cannot start with a hyphen.")
    }
    let disallowedCharacters = CharacterSet(charactersIn: ";|&`$<>\"'\n\r\t\0*?,!")
    guard trimmed.rangeOfCharacter(from: disallowedCharacters) == nil else {
      throw RdpCertificateTrustError.invalidHost("Host contains disallowed metacharacters.")
    }
    return trimmed
  }

  public static func validatePort(_ port: Int) throws -> Int {
    guard (1...65535).contains(port) else {
      throw RdpCertificateTrustError.invalidPort(port)
    }
    return port
  }

  public static func validateFingerprint(_ fingerprint: String) throws -> String {
    // Strip optional colons or spaces
    let cleanHex = fingerprint.filter { $0 != ":" && !$0.isWhitespace }
    guard cleanHex.count == 64 else {
      throw RdpCertificateTrustError.invalidFingerprint("Expected 64 hex characters, got \(cleanHex.count).")
    }
    let hexCharset = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
    guard cleanHex.unicodeScalars.allSatisfy({ hexCharset.contains($0) }) else {
      throw RdpCertificateTrustError.invalidFingerprint("Fingerprint contains non-hexadecimal characters.")
    }
    return cleanHex.uppercased()
  }

  // MARK: - RdpHostCertificateVerifier

  public func evaluateTrust(
    host: String,
    port: Int,
    presented: RdpCertificateRecord
  ) async throws -> RdpHostTrustStatus {
    let validHost = try Self.validateHost(host)
    let validPort = try Self.validatePort(port)
    let validFingerprint = try Self.validateFingerprint(presented.sha256Fingerprint)

    let normalizedPresented = RdpCertificateRecord(
      host: validHost,
      port: validPort,
      sha256Fingerprint: validFingerprint,
      subjectCN: presented.subjectCN,
      issuerCN: presented.issuerCN
    )

    let existing: RdpCertificateRecord?
    do {
      existing = try repository.getRdpHostTrust(host: validHost, port: validPort)
    } catch {
      throw RdpCertificateTrustError.persistenceFailed(error.localizedDescription)
    }

    if let existing {
      if existing.sha256Fingerprint == validFingerprint {
        return .trusted(matched: existing)
      } else {
        record("rdp.cert.rejected", validHost, validPort, .failure, "mismatch")
        return .mismatch(recorded: existing, presented: normalizedPresented)
      }
    } else {
      let challenge = RdpCertificateTrustChallenge(
        host: validHost,
        port: validPort,
        presentedCertificate: normalizedPresented
      )
      activeChallenges[challenge.id] = challenge
      return .unknown(challenge: challenge)
    }
  }

  public func approveChallenge(_ challenge: RdpCertificateTrustChallenge) async throws {
    guard let stored = activeChallenges[challenge.id] else {
      throw RdpCertificateTrustError.challengeExpired
    }
    guard stored.nonce == challenge.nonce else {
      throw RdpCertificateTrustError.challengeNonceMismatch
    }
    guard Date().timeIntervalSince(stored.createdAt) <= Self.challengeValiditySeconds else {
      activeChallenges.removeValue(forKey: challenge.id)
      throw RdpCertificateTrustError.challengeExpired
    }
    activeChallenges.removeValue(forKey: challenge.id)

    do {
      try repository.recordRdpHostTrust(record: challenge.presentedCertificate)
    } catch {
      throw RdpCertificateTrustError.persistenceFailed(error.localizedDescription)
    }
    record("rdp.cert.trusted", challenge.host, challenge.port)
  }

  public func revokeTrust(host: String, port: Int) async throws {
    let validHost = try Self.validateHost(host)
    let validPort = try Self.validatePort(port)
    do {
      try repository.deleteRdpHostTrust(host: validHost, port: validPort)
    } catch {
      throw RdpCertificateTrustError.persistenceFailed(error.localizedDescription)
    }
    record("rdp.cert.revoked", validHost, validPort)
  }

  public func listTrustedCertificates() async throws -> [RdpCertificateRecord] {
    do {
      return try repository.listRdpHostTrust()
    } catch {
      throw RdpCertificateTrustError.persistenceFailed(error.localizedDescription)
    }
  }
}

/// In-memory repository for tests and ephemeral environments.
public final class InMemoryRdpHostTrustRepository: RdpHostTrustRepository, @unchecked Sendable {
  private let lock = NSLock()
  private var records: [String: RdpCertificateRecord] = [:]

  public init(initialRecords: [RdpCertificateRecord] = []) {
    for r in initialRecords {
      records["\(r.host):\(r.port)"] = r
    }
  }

  public func getRdpHostTrust(host: String, port: Int) throws -> RdpCertificateRecord? {
    lock.lock()
    defer { lock.unlock() }
    return records["\(host):\(port)"]
  }

  public func recordRdpHostTrust(record: RdpCertificateRecord) throws {
    lock.lock()
    defer { lock.unlock() }
    records["\(record.host):\(record.port)"] = record
  }

  public func deleteRdpHostTrust(host: String, port: Int) throws {
    lock.lock()
    defer { lock.unlock() }
    records.removeValue(forKey: "\(host):\(port)")
  }

  public func listRdpHostTrust() throws -> [RdpCertificateRecord] {
    lock.lock()
    defer { lock.unlock() }
    return Array(records.values).sorted { "\($0.host):\($0.port)" < "\($1.host):\($1.port)" }
  }
}
