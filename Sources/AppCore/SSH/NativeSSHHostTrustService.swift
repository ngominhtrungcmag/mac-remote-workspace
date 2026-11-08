import Darwin
import Foundation

public typealias SSHHostTrustPersistenceAuthorization = (() throws -> Void) throws -> Bool

/// Represents a parsed SSH host key retrieved from an endpoint or known_hosts file.
public struct SSHHostKeyRecord: Sendable, Equatable, Identifiable, Hashable {
  public var id: String { rawLine }
  public let rawLine: String
  public let keyType: String
  public let keyBase64: String
  public let comment: String?
  public let algorithm: String
  public let bitLength: Int?
  public let fingerprintSHA256: String
  public let visualArt: String?

  public init(
    rawLine: String,
    keyType: String,
    keyBase64: String,
    comment: String? = nil,
    algorithm: String,
    bitLength: Int? = nil,
    fingerprintSHA256: String,
    visualArt: String? = nil
  ) {
    self.rawLine = rawLine
    self.keyType = keyType
    self.keyBase64 = keyBase64
    self.comment = comment
    self.algorithm = algorithm
    self.bitLength = bitLength
    self.fingerprintSHA256 = fingerprintSHA256
    self.visualArt = visualArt
  }
}

/// Result of evaluating an endpoint's host key against a known_hosts store.
public enum SSHHostTrustStatus: Sendable, Equatable {
  /// The host key is already present in known_hosts and matches strictly.
  case trusted(matchedKey: SSHHostKeyRecord)
  /// The host key is not present in known_hosts; requires user verification.
  case unknown(challenge: SSHHostTrustChallenge)
  /// The host key presented by the endpoint differs from the key recorded in known_hosts.
  /// Hard block — connection must not proceed.
  case mismatch(recordedKeys: [SSHHostKeyRecord], presentedKey: SSHHostKeyRecord)
}

/// An ephemeral challenge generated during host key verification.
/// Tied strictly to the specific endpoint, key, session ID, and nonce.
public struct SSHHostTrustChallenge: Sendable, Equatable, Identifiable {
  public let id: UUID
  public let host: String
  public let port: Int
  public let presentedKey: SSHHostKeyRecord
  public let nonce: String
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    host: String,
    port: Int,
    presentedKey: SSHHostKeyRecord,
    nonce: String = UUID().uuidString,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.host = host
    self.port = port
    self.presentedKey = presentedKey
    self.nonce = nonce
    self.createdAt = createdAt
  }
}

/// A parsed entry from a known_hosts file, representing a trusted or recorded host key.
public struct KnownHostEntry: Sendable, Equatable, Identifiable, Hashable {
  public var id: String { "\(lineNumber):\(hostPattern):\(keyRecord.fingerprintSHA256)" }
  public let lineNumber: Int
  public let rawLine: String
  public let hostPattern: String
  public let marker: String?
  public let isHashed: Bool
  public let keyRecord: SSHHostKeyRecord

  public init(
    lineNumber: Int,
    rawLine: String,
    hostPattern: String,
    marker: String? = nil,
    isHashed: Bool = false,
    keyRecord: SSHHostKeyRecord
  ) {
    self.lineNumber = lineNumber
    self.rawLine = rawLine
    self.hostPattern = hostPattern
    self.marker = marker
    self.isHashed = isHashed
    self.keyRecord = keyRecord
  }
}

/// Errors raised by NativeSSHHostTrustService.
public enum SSHHostTrustError: Error, Equatable, AppCoreLocalizedError {
  case invalidHost(String)
  case invalidPort(Int)
  case probeFailed(String)
  case hostKeyNotFound(host: String, port: Int)
  case parsingFailed(String)
  case knownHostsUnparseable(String)
  case knownHostsFileUnwritable(String)
  case subprocessTimedOut(String)
  case staleChallenge
  case challengeMismatch(details: String)
  case mismatchBlocked(details: String)

  public func displayDescription(locale: Locale?) -> String? {
    switch self {
    case .invalidHost(let host):
      return AppCoreLocalization.format("Invalid host '%1$@'.", host, locale: locale)
    case .invalidPort(let port):
      return AppCoreLocalization.format("Invalid port '%1$@'.", String(port), locale: locale)
    case .probeFailed(let details):
      return AppCoreLocalization.format("Failed to probe host key: %1$@", details, locale: locale)
    case .hostKeyNotFound(let host, let port):
      return AppCoreLocalization.format("No host key offered by %1$@:%2$@.", host, String(port), locale: locale)
    case .parsingFailed(let details):
      return AppCoreLocalization.format("Failed to parse host key: %1$@", details, locale: locale)
    case .knownHostsUnparseable(let details):
      return AppCoreLocalization.format("known_hosts file contains unreadable or malformed entries: %1$@", details, locale: locale)
    case .knownHostsFileUnwritable(let path):
      return AppCoreLocalization.format("Known hosts file is not writable: %1$@", path, locale: locale)
    case .subprocessTimedOut(let executable):
      return AppCoreLocalization.format("Host-trust helper timed out: %1$@", executable, locale: locale)
    case .staleChallenge:
      return AppCoreLocalization.string("Trust challenge has expired or does not match the active session.", locale: locale)
    case .challengeMismatch(let details):
      return AppCoreLocalization.format("Challenge mismatch: %1$@", details, locale: locale)
    case .mismatchBlocked(let details):
      return AppCoreLocalization.format("Host key mismatch blocked: %1$@", details, locale: locale)
    }
  }
}

/// Service providing safe native host key evaluation, inspection, and explicit trust persistence.
/// Direct probes do not authenticate. Forwarded ProxyJump probes authenticate only to the already
/// trusted jump host and never authenticate to the endpoint whose key is being inspected.
public final class NativeSSHHostTrustService: Sendable {
  public let knownHostsFileURL: URL
  /// Optional audit sink: (action, "host:port", outcome, errorCode). Metadata only.
  public typealias AuditSink = @Sendable (String, String, AuditOutcome, String?) -> Void
  private let audit: AuditSink?

  public init(knownHostsFileURL: URL, audit: AuditSink? = nil) {
    self.knownHostsFileURL = knownHostsFileURL
    self.audit = audit
  }

  private func record(_ action: String, _ host: String, _ port: Int, _ outcome: AuditOutcome = .success, _ code: String? = nil) {
    RedactedLogger.shared.info("hostkey", "\(action) \(host):\(port) \(outcome.rawValue)")
    audit?(action, "\(host):\(port)", outcome, code)
  }

  private static let auditRepository = try? SQLiteHostRepository.openApplicationRepository()

  /// Production sink writing to the application audit table.
  public static let appAuditSink: AuditSink = { action, entity, outcome, code in
    guard let repo = auditRepository else { return }
    try? repo.recordAuditEvent(action: action, entityType: "ssh_host_key", entityID: entity, outcome: outcome, errorCode: code)
  }

  /// Default known_hosts URL in user's ~/.ssh directory.
  public static var defaultKnownHostsURL: URL {
    knownHostsURL()
  }

  static func knownHostsURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
    if environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
      return SQLiteHostRepository.applicationSupportDirectory(environment: environment)!.appendingPathComponent("known_hosts")
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".ssh")
      .appendingPathComponent("known_hosts")
  }

  // MARK: - Safe Subprocess Execution Helper (Anti-Deadlock)

  private final class PipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()

    var data: Data {
      lock.lock()
      defer { lock.unlock() }
      return _data
    }

    func collect(from handle: FileHandle) {
      let read = handle.readDataToEndOfFile()
      lock.lock()
      _data = read
      lock.unlock()
    }
  }

  private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _didTimeout = false

    var didTimeout: Bool {
      lock.lock()
      defer { lock.unlock() }
      return _didTimeout
    }

    func markTimedOut() {
      lock.lock()
      _didTimeout = true
      lock.unlock()
    }
  }

  /// Executes a subprocess while asynchronously draining stdout and stderr to prevent pipe buffer deadlock.
  public static func runSubprocess(
    executableURL: URL,
    arguments: [String],
    standardInput: Data? = nil,
    timeoutSeconds: TimeInterval = 10,
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) throws -> (exitCode: Int32, stdout: Data, stderr: Data) {
    guard !isCancelled() else { throw SSHHostTrustError.staleChallenge }
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let stdinPipe: Pipe?
    if standardInput != nil {
      let pipe = Pipe()
      process.standardInput = pipe
      stdinPipe = pipe
    } else {
      stdinPipe = nil
    }

    try process.run()

    let timeout = TimeoutFlag()
    let boundedTimeout = timeoutSeconds.isFinite ? min(60, max(0.1, timeoutSeconds)) : 10
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(boundedTimeout * 1_000_000_000)
    let monitor = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    monitor.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
    monitor.setEventHandler {
      guard process.isRunning else { return }
      if isCancelled() {
        process.terminate()
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
      } else if DispatchTime.now().uptimeNanoseconds >= deadline {
        timeout.markTimedOut()
        process.terminate()
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
      }
    }
    monitor.resume()

    let ioGroup = DispatchGroup()
    let stdoutCollector = PipeCollector()
    let stderrCollector = PipeCollector()

    ioGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      stdoutCollector.collect(from: stdoutPipe.fileHandleForReading)
      ioGroup.leave()
    }

    ioGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      stderrCollector.collect(from: stderrPipe.fileHandleForReading)
      ioGroup.leave()
    }

    if let stdinPipe = stdinPipe, let input = standardInput {
      ioGroup.enter()
      DispatchQueue.global(qos: .userInitiated).async {
        stdinPipe.fileHandleForWriting.write(input)
        stdinPipe.fileHandleForWriting.closeFile()
        ioGroup.leave()
      }
    }

    process.waitUntilExit()
    monitor.cancel()
    ioGroup.wait()

    if isCancelled() { throw SSHHostTrustError.staleChallenge }
    if timeout.didTimeout { throw SSHHostTrustError.subprocessTimedOut(executableURL.lastPathComponent) }

    return (process.terminationStatus, stdoutCollector.data, stderrCollector.data)
  }

  // MARK: - Endpoint Formatting

  /// Formats the host and port pattern according to OpenSSH known_hosts rules:
  /// - Standard port 22 IPv4 / hostname: `example.com` or `127.0.0.1`
  /// - Non-standard port: `[example.com]:2222` or `[127.0.0.1]:2222`
  /// - IPv6 standard port: `[::1]` or `::1` (OpenSSH bracket format is `[::1]` or `::1`)
  /// - IPv6 non-standard port: `[::1]:2222`
  public static func formatHostPattern(host: String, port: Int) -> String {
    let isIPv6 = host.contains(":")
    if port == 22 {
      if isIPv6 && !host.hasPrefix("[") {
        return host
      }
      return host
    } else {
      let cleanHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
      return "[\(cleanHost)]:\(port)"
    }
  }

  // MARK: - Validation

  private static func isValidIPv4(_ str: String) -> Bool {
    var sin = sockaddr_in()
    return str.withCString { inet_pton(AF_INET, $0, &sin.sin_addr) } == 1
  }

  private static func isValidIPv6(_ str: String) -> Bool {
    var sin6 = sockaddr_in6()
    return str.withCString { inet_pton(AF_INET6, $0, &sin6.sin6_addr) } == 1
  }

  private static func isValidHostname(_ str: String) -> Bool {
    guard !str.isEmpty, str.count <= 253 else { return false }
    let labels = str.split(separator: ".", omittingEmptySubsequences: false)
    guard !labels.isEmpty else { return false }
    for label in labels {
      guard !label.isEmpty, label.count <= 63 else { return false }
      guard !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
      let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
      if label.unicodeScalars.contains(where: { !allowed.contains($0) }) {
        return false
      }
    }
    return true
  }

  public static func validateEndpoint(host: String, port: Int) throws {
    guard !host.isEmpty,
          host == host.trimmingCharacters(in: .whitespacesAndNewlines),
          !host.hasPrefix("-") else {
      throw SSHHostTrustError.invalidHost(host)
    }

    // Explicitly reject wildcards, pattern metacharacters, and command injection characters
    let disallowedCharacters = CharacterSet(charactersIn: ",*?!~`'\"$|&;(){}[]\0@")
    // IPv6 enclosed in brackets is permitted only if brackets are at the edges and content is valid IPv6
    var hostToValidate = host
    if host.hasPrefix("[") && host.hasSuffix("]") && host.count > 2 {
      let inner = String(host.dropFirst().dropLast())
      guard isValidIPv6(inner) else {
        throw SSHHostTrustError.invalidHost(host)
      }
      hostToValidate = inner
    } else {
      guard host.rangeOfCharacter(from: disallowedCharacters) == nil else {
        throw SSHHostTrustError.invalidHost(host)
      }
    }

    let isValid = isValidIPv4(hostToValidate) || isValidIPv6(hostToValidate) || isValidHostname(hostToValidate)
    guard isValid else {
      throw SSHHostTrustError.invalidHost(host)
    }

    guard (1...65535).contains(port) else {
      throw SSHHostTrustError.invalidPort(port)
    }
  }

  // MARK: - Trust Evaluation

  /// Evaluate the endpoint out-of-band:
  /// 1. Look up any existing keys for the endpoint in `knownHostsFileURL`.
  /// 2. Probe the endpoint for its currently offered host key using `ssh-keyscan`.
  /// 3. Compare:
  ///    - If known_hosts contains a matching key for the same algorithm -> `.trusted`
  ///    - If known_hosts has a key for this host but the key differs -> `.mismatch`
  ///    - If known_hosts has no record for this host -> `.unknown`
  public func evaluateEndpoint(
    host: String,
    port: Int,
    probeTimeoutSeconds: Int = 5,
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) throws -> SSHHostTrustStatus {
    try evaluateEndpoint(
      host: host,
      port: port,
      probeHost: host,
      probePort: port,
      probeTimeoutSeconds: probeTimeoutSeconds,
      isCancelled: isCancelled
    )
  }

  /// Evaluate the real endpoint while reaching it through a short-lived loopback SSH forward.
  /// The trust store and challenge remain bound to `host` and `port`; the local forwarding address
  /// is only a transport detail and is never persisted as host identity.
  func evaluateEndpoint(
    host: String,
    port: Int,
    throughLoopbackPort localPort: Int,
    probeTimeoutSeconds: Int = 5,
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) throws -> SSHHostTrustStatus {
    guard (1...65535).contains(localPort) else {
      throw SSHHostTrustError.invalidPort(localPort)
    }
    return try evaluateEndpoint(
      host: host,
      port: port,
      probeHost: "127.0.0.1",
      probePort: localPort,
      probeTimeoutSeconds: probeTimeoutSeconds,
      isCancelled: isCancelled
    )
  }

  private func evaluateEndpoint(
    host: String,
    port: Int,
    probeHost: String,
    probePort: Int,
    probeTimeoutSeconds: Int,
    isCancelled: @escaping @Sendable () -> Bool
  ) throws -> SSHHostTrustStatus {
    try Self.validateEndpoint(host: host, port: port)

    let recordedKeys = try queryRecordedKeys(host: host, port: port, isCancelled: isCancelled)
    let keyFromRoute = try probePresentedKey(
      host: probeHost,
      port: probePort,
      timeoutSeconds: probeTimeoutSeconds,
      isCancelled: isCancelled
    )
    let presentedKey: SSHHostKeyRecord
    if probeHost == host && probePort == port {
      presentedKey = keyFromRoute
    } else {
      // Rebind the parsed public key to the requested endpoint before exposing the challenge or
      // persisting trust. This keeps localhost forwarding metadata out of known_hosts.
      presentedKey = try parseHostKeyLine(
        "\(Self.formatHostPattern(host: host, port: port)) \(keyFromRoute.keyType) \(keyFromRoute.keyBase64)",
        isCancelled: isCancelled
      )
    }

    if recordedKeys.isEmpty {
      let challenge = SSHHostTrustChallenge(
        host: host,
        port: port,
        presentedKey: presentedKey
      )
      return .unknown(challenge: challenge)
    }

    // Check if any recorded key matches the presented key
    for recorded in recordedKeys {
      if recorded.keyType == presentedKey.keyType && recorded.keyBase64 == presentedKey.keyBase64 {
        return .trusted(matchedKey: recorded)
      }
    }

    // Keys exist for this endpoint, but none matched the presented key
    record("ssh.hostkey.rejected", host, port, .failure, "mismatch")
    return .mismatch(recordedKeys: recordedKeys, presentedKey: presentedKey)
  }

  // MARK: - Query Recorded Keys

  /// Validates the format of known_hosts file contents to fail closed on malformed entries.
  private func validateKnownHostsFileFormat() throws {
    guard let contents = try? String(contentsOf: knownHostsFileURL, encoding: .utf8) else {
      throw SSHHostTrustError.knownHostsUnparseable("Unable to read \(knownHostsFileURL.path) as UTF-8")
    }

    let lines = contents.components(separatedBy: .newlines)
    for (lineIndex, rawLine) in lines.enumerated() {
      let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

      var line = trimmed
      if line.hasPrefix("@") {
        let parts = line.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
        let marker = parts[0]
        guard marker == "@revoked" || marker == "@cert-authority" else {
          throw SSHHostTrustError.knownHostsUnparseable("Unsupported marker '\(marker)' at line \(lineIndex + 1)")
        }
        guard parts.count > 1 else {
          throw SSHHostTrustError.knownHostsUnparseable("Marker without host/key entry at line \(lineIndex + 1)")
        }
        line = String(parts[1])
      }

      let tokens = line.split(whereSeparator: { $0.isWhitespace })
      guard tokens.count >= 3 else {
        throw SSHHostTrustError.knownHostsUnparseable("Malformed known_hosts entry at line \(lineIndex + 1): '\(trimmed)'")
      }

      let keyBase64 = String(tokens[2])
      guard Data(base64Encoded: keyBase64) != nil else {
        throw SSHHostTrustError.knownHostsUnparseable("Invalid base64 host key at line \(lineIndex + 1): '\(trimmed)'")
      }
    }
  }

  /// Opens the trust store through its verified parent directory, refusing path redirection.
  private func openSecureKnownHostsFile(createIfMissing: Bool, writable: Bool = false) throws -> Int32? {
    let parentDirectory = knownHostsFileURL.deletingLastPathComponent()
    if createIfMissing {
      do {
        try FileManager.default.createDirectory(
          at: parentDirectory,
          withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700]
        )
      } catch {
        throw SSHHostTrustError.knownHostsFileUnwritable(parentDirectory.path)
      }
    }

    let directoryFD = open(parentDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard directoryFD >= 0 else {
      if !createIfMissing && errno == ENOENT { return nil }
      throw SSHHostTrustError.knownHostsFileUnwritable(parentDirectory.path)
    }
    defer { close(directoryFD) }

    var directoryInfo = stat()
    guard fstat(directoryFD, &directoryInfo) == 0,
          (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
          directoryInfo.st_uid == geteuid() else {
      throw SSHHostTrustError.knownHostsFileUnwritable(parentDirectory.path)
    }
    let directoryPermissions = directoryInfo.st_mode & 0o7777
    guard directoryPermissions & 0o022 == 0 else {
      throw SSHHostTrustError.knownHostsFileUnwritable(parentDirectory.path)
    }

    let filename = knownHostsFileURL.lastPathComponent
    guard !filename.isEmpty, filename != ".", filename != ".." else {
      throw SSHHostTrustError.knownHostsFileUnwritable(knownHostsFileURL.path)
    }

    if createIfMissing, directoryPermissions != 0o700, fchmod(directoryFD, 0o700) != 0 {
      throw SSHHostTrustError.knownHostsFileUnwritable(parentDirectory.path)
    }

    let fileFlags = O_RDONLY | O_NOFOLLOW | (createIfMissing ? O_CREAT : 0)
    var fileFD = openat(directoryFD, filename, fileFlags, 0o600)
    guard fileFD >= 0 else {
      if !createIfMissing && errno == ENOENT { return nil }
      throw SSHHostTrustError.knownHostsFileUnwritable(knownHostsFileURL.path)
    }
    var closeFileFD = true
    defer {
      if closeFileFD { close(fileFD) }
    }

    var fileInfo = stat()
    guard fstat(fileFD, &fileInfo) == 0,
          (fileInfo.st_mode & S_IFMT) == S_IFREG,
          fileInfo.st_uid == geteuid() else {
      throw SSHHostTrustError.knownHostsFileUnwritable(knownHostsFileURL.path)
    }
    let filePermissions = fileInfo.st_mode & 0o7777
    guard filePermissions & 0o022 == 0 else {
      throw SSHHostTrustError.knownHostsFileUnwritable(knownHostsFileURL.path)
    }

    if !createIfMissing, directoryPermissions != 0o700, fchmod(directoryFD, 0o700) != 0 {
      throw SSHHostTrustError.knownHostsFileUnwritable(parentDirectory.path)
    }
    if filePermissions != 0o600, fchmod(fileFD, 0o600) != 0 {
      throw SSHHostTrustError.knownHostsFileUnwritable(knownHostsFileURL.path)
    }

    if writable {
      let writeFD = openat(directoryFD, filename, O_RDWR | O_NOFOLLOW)
      guard writeFD >= 0 else {
        throw SSHHostTrustError.knownHostsFileUnwritable(knownHostsFileURL.path)
      }
      var writeInfo = stat()
      guard fstat(writeFD, &writeInfo) == 0,
            writeInfo.st_dev == fileInfo.st_dev,
            writeInfo.st_ino == fileInfo.st_ino else {
        close(writeFD)
        throw SSHHostTrustError.knownHostsFileUnwritable(knownHostsFileURL.path)
      }
      close(fileFD)
      fileFD = writeFD
    }

    closeFileFD = false
    return fileFD
  }

  /// Query known_hosts using `/usr/bin/ssh-keygen -F <pattern> -f <file>`.
  /// Preserves OpenSSH semantics:
  /// - Fails closed on ssh-keygen error (exit code != 0 or 1).
  /// - Fails closed on any unparseable line or markers like `@revoked` / `@cert-authority`.
  public func queryRecordedKeys(
    host: String,
    port: Int,
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) throws -> [SSHHostKeyRecord] {
    try Self.validateEndpoint(host: host, port: port)
    let pattern = Self.formatHostPattern(host: host, port: port)
    let knownHostsFD: Int32
    do {
      guard let descriptor = try openSecureKnownHostsFile(createIfMissing: false) else { return [] }
      knownHostsFD = descriptor
    } catch {
      throw SSHHostTrustError.knownHostsUnparseable(error.localizedDescription)
    }
    defer { close(knownHostsFD) }

    // Validate the known_hosts file format; never treat unreadable/malformed known_hosts as unknown.
    try validateKnownHostsFileFormat()

    let result = try Self.runSubprocess(
      executableURL: URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
      arguments: ["-F", pattern, "-f", knownHostsFileURL.path],
      isCancelled: isCancelled
    )

    // ssh-keygen -F returns:
    // 0 = host found
    // 1 = host not found
    // >1 = error / failure
    if result.exitCode > 1 {
      let errStr = String(data: result.stderr, encoding: .utf8) ?? "Unknown ssh-keygen error"
      throw SSHHostTrustError.knownHostsUnparseable(errStr)
    }

    guard let output = String(data: result.stdout, encoding: .utf8), !output.isEmpty else {
      return []
    }

    var records: [SSHHostKeyRecord] = []
    let lines = output.components(separatedBy: .newlines)
    for rawLine in lines {
      let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

      // Check for OpenSSH markers like @revoked or @cert-authority
      if trimmed.hasPrefix("@") {
        let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
        let marker = parts.first ?? ""
        if marker == "@revoked" {
          throw SSHHostTrustError.knownHostsUnparseable("Host key is marked @revoked in known_hosts for \(pattern)")
        } else if marker == "@cert-authority" {
          throw SSHHostTrustError.knownHostsUnparseable("Host key is marked @cert-authority in known_hosts for \(pattern)")
        } else {
          throw SSHHostTrustError.knownHostsUnparseable("Unsupported marker '\(marker)' in known_hosts for \(pattern)")
        }
      }

      do {
        let record = try parseHostKeyLine(trimmed, isCancelled: isCancelled)
        records.append(record)
      } catch {
        throw SSHHostTrustError.knownHostsUnparseable("Malformed known_hosts entry for \(pattern): \(error.localizedDescription)")
      }
    }
    return records
  }

  // MARK: - Out-of-band Key Probing

  /// Probes the endpoint host key using `/usr/bin/ssh-keyscan`.
  /// Retrieves ed25519, ecdsa, or rsa host keys safely without authenticating.
  public func probePresentedKey(
    host: String,
    port: Int,
    timeoutSeconds: Int = 5,
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) throws -> SSHHostKeyRecord {
    try Self.validateEndpoint(host: host, port: port)
    let boundedTimeout = min(30, max(1, timeoutSeconds))

    let result: (exitCode: Int32, stdout: Data, stderr: Data)
    do {
      result = try Self.runSubprocess(
        executableURL: URL(fileURLWithPath: "/usr/bin/ssh-keyscan"),
        arguments: [
          "-t", "ed25519,ecdsa,rsa",
          "-T", String(boundedTimeout),
          "-p", String(port),
          host
        ],
        timeoutSeconds: TimeInterval(boundedTimeout + 5),
        isCancelled: isCancelled
      )
    } catch {
      if case SSHHostTrustError.staleChallenge = error { throw error }
      throw SSHHostTrustError.probeFailed(error.localizedDescription)
    }

    let output = String(data: result.stdout, encoding: .utf8) ?? ""
    let errOutput = String(data: result.stderr, encoding: .utf8) ?? ""

    let lines = output.components(separatedBy: .newlines)
    var candidateLines: [String] = []
    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
        candidateLines.append(trimmed)
      }
    }

    guard !candidateLines.isEmpty else {
      let details = errOutput.trimmingCharacters(in: .whitespacesAndNewlines)
      if details.isEmpty {
        throw SSHHostTrustError.hostKeyNotFound(host: host, port: port)
      } else {
        throw SSHHostTrustError.probeFailed(details)
      }
    }

    // Prefer ed25519, then ecdsa, then rsa
    let preferredLine = candidateLines.first { $0.contains("ssh-ed25519") }
      ?? candidateLines.first { $0.contains("ecdsa-") }
      ?? candidateLines[0]

    return try parseHostKeyLine(preferredLine, isCancelled: isCancelled)
  }

  // MARK: - Key Inspection & Fingerprinting

  /// Parses a known_hosts line or ssh-keyscan line and extracts its fingerprint and visual art
  /// using `/usr/bin/ssh-keygen -l -v -f -`.
  public func parseHostKeyLine(
    _ line: String,
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) throws -> SSHHostKeyRecord {
    let parts = line.split(whereSeparator: { $0.isWhitespace })
    guard parts.count >= 3 else {
      throw SSHHostTrustError.parsingFailed("Malformed host key line: expected at least 3 fields.")
    }

    let keyType = String(parts[1])
    let keyBase64 = String(parts[2])
    let comment = parts.count > 3 ? parts[3...].joined(separator: " ") : nil

    // Format normalized single key entry for ssh-keygen inspection
    let normalized = "\(parts[0]) \(keyType) \(keyBase64)\n"
    guard let inputData = normalized.data(using: .utf8) else {
      throw SSHHostTrustError.parsingFailed("Failed to encode line for inspection.")
    }

    let result: (exitCode: Int32, stdout: Data, stderr: Data)
    do {
      result = try Self.runSubprocess(
        executableURL: URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
        arguments: ["-l", "-v", "-E", "sha256", "-f", "-"],
        standardInput: inputData,
        isCancelled: isCancelled
      )
    } catch {
      if case SSHHostTrustError.staleChallenge = error { throw error }
      if case SSHHostTrustError.subprocessTimedOut = error { throw error }
      throw SSHHostTrustError.parsingFailed("Failed to spawn ssh-keygen: \(error.localizedDescription)")
    }

    guard result.exitCode == 0,
          let keygenOutput = String(data: result.stdout, encoding: .utf8),
          !keygenOutput.isEmpty else {
      let errStr = String(data: result.stderr, encoding: .utf8) ?? "unknown"
      throw SSHHostTrustError.parsingFailed("ssh-keygen failed to inspect key: \(errStr)")
    }

    let outLines = keygenOutput.components(separatedBy: .newlines).filter { !$0.isEmpty }
    guard let firstLine = outLines.first else {
      throw SSHHostTrustError.parsingFailed("Empty output from ssh-keygen.")
    }

    // Expected format: <bitLength> <SHA256:fingerprint> <host> (<ALGORITHM>)
    let headerTokens = firstLine.split(whereSeparator: { $0.isWhitespace })
    guard headerTokens.count >= 4 else {
      throw SSHHostTrustError.parsingFailed("Unexpected fingerprint output format: \(firstLine)")
    }

    let bitLength = Int(headerTokens[0])
    let fingerprint = String(headerTokens[1])
    let algorithm = String(headerTokens[3]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))

    let visualArt: String?
    if outLines.count > 1 {
      visualArt = outLines[1...].joined(separator: "\n")
    } else {
      visualArt = nil
    }

    return SSHHostKeyRecord(
      rawLine: line,
      keyType: keyType,
      keyBase64: keyBase64,
      comment: comment,
      algorithm: algorithm,
      bitLength: bitLength,
      fingerprintSHA256: fingerprint,
      visualArt: visualArt
    )
  }

  /// The lock file has a stable inode even when the trust store is replaced.
  private func lockKnownHosts(createIfMissing: Bool) throws -> Int32? {
    let directory = knownHostsFileURL.deletingLastPathComponent()
    if createIfMissing {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directoryFD >= 0 else {
      if !createIfMissing && errno == ENOENT { return nil }
      throw SSHHostTrustError.knownHostsFileUnwritable(directory.path)
    }
    defer { close(directoryFD) }
    var directoryInfo = stat()
    guard fstat(directoryFD, &directoryInfo) == 0, directoryInfo.st_uid == geteuid(),
          (directoryInfo.st_mode & S_IFMT) == S_IFDIR, directoryInfo.st_mode & 0o022 == 0 else {
      throw SSHHostTrustError.knownHostsFileUnwritable(directory.path)
    }
    let path = knownHostsFileURL.path + ".mrw.lock"
    var fd: Int32 = -1
    for _ in 0..<10 {
      fd = openat(directoryFD, knownHostsFileURL.lastPathComponent + ".mrw.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
      if fd >= 0 || errno != ENOENT { break }
      usleep(1_000)
    }
    guard fd >= 0 else { throw SSHHostTrustError.knownHostsFileUnwritable(path) }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
          info.st_uid == geteuid(), info.st_nlink == 1, fchmod(fd, 0o600) == 0 else {
      close(fd)
      throw SSHHostTrustError.knownHostsFileUnwritable(path)
    }
    while flock(fd, LOCK_EX) != 0 {
      if errno == EINTR { continue }
      close(fd)
      throw SSHHostTrustError.knownHostsFileUnwritable(path)
    }
    return fd
  }

  private func replaceKnownHosts(_ data: Data) throws {
    let directory = knownHostsFileURL.deletingLastPathComponent()
    let dirFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard dirFD >= 0 else { throw SSHHostTrustError.knownHostsFileUnwritable(directory.path) }
    defer { close(dirFD) }
    let temporary = ".mrw-known-hosts-" + UUID().uuidString
    let fd = openat(dirFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw SSHHostTrustError.knownHostsFileUnwritable(directory.path) }
    defer { close(fd); unlinkat(dirFD, temporary, 0) }
    guard fchmod(fd, 0o600) == 0 else { throw SSHHostTrustError.knownHostsFileUnwritable(knownHostsFileURL.path) }
    try Self.overwrite(fd: fd, with: data, path: knownHostsFileURL.path)
    guard renameat(dirFD, temporary, dirFD, knownHostsFileURL.lastPathComponent) == 0 else {
      throw SSHHostTrustError.knownHostsFileUnwritable(knownHostsFileURL.path)
    }
  }

  // MARK: - Trust Persistence

  /// Persists the approved challenge into the known_hosts file safely using coordinated file locking.
  /// Validates:
  /// 1. The challenge matches the current endpoint.
  /// 2. Under exclusive file lock, re-checks that NO existing key entry for this host conflicts
  ///    (regardless of key type / algorithm). Fails closed on any conflicting entry.
  /// 3. Ensures trailing newline before appending, preventing corruption of existing file contents.
  /// 4. Synchronizes writes to disk.
  public func approveChallenge(
    _ challenge: SSHHostTrustChallenge,
    expectedHost: String,
    expectedPort: Int,
    isCancelled: @escaping @Sendable () -> Bool = { false },
    authorizePersistence: SSHHostTrustPersistenceAuthorization? = nil
  ) throws {
    guard challenge.host == expectedHost, challenge.port == expectedPort else {
      throw SSHHostTrustError.challengeMismatch(
        details: "Challenge endpoint \(challenge.host):\(challenge.port) does not match requested \(expectedHost):\(expectedPort)"
      )
    }

    try Self.validateEndpoint(host: expectedHost, port: expectedPort)
    guard !isCancelled() else { throw SSHHostTrustError.staleChallenge }

    let filePath = knownHostsFileURL.path
    guard let lockFD = try lockKnownHosts(createIfMissing: true) else {
      throw SSHHostTrustError.knownHostsFileUnwritable(filePath)
    }
    defer { flock(lockFD, LOCK_UN); close(lockFD) }
    guard let fd = try openSecureKnownHostsFile(createIfMissing: true) else {
      throw SSHHostTrustError.knownHostsFileUnwritable(filePath)
    }
    defer { close(fd) }

    // Safety check under lock: ensure no conflicting entry exists in known_hosts
    let currentRecorded = try queryRecordedKeys(host: expectedHost, port: expectedPort, isCancelled: isCancelled)
    for recorded in currentRecorded {
      // If any existing key doesn't match the approved challenge key, fail closed
      if recorded.keyType != challenge.presentedKey.keyType || recorded.keyBase64 != challenge.presentedKey.keyBase64 {
        record("ssh.hostkey.rejected", expectedHost, expectedPort, .failure, "mismatch")
        throw SSHHostTrustError.mismatchBlocked(
          details: "Refusing to overwrite existing recorded key (\(recorded.keyType)) for \(expectedHost):\(expectedPort)"
        )
      }
    }

    // If identical key is already present, nothing to append
    if currentRecorded.contains(where: { $0.keyType == challenge.presentedKey.keyType && $0.keyBase64 == challenge.presentedKey.keyBase64 }) {
      return
    }

    // Check existing content size and ensure trailing newline
    let currentLength = lseek(fd, 0, SEEK_END)
    guard currentLength >= 0 else {
      throw SSHHostTrustError.knownHostsFileUnwritable("Failed to inspect \(filePath)")
    }
    var prefixNewline = ""
    if currentLength > 0 {
      var lastByte: UInt8 = 0
      guard lseek(fd, currentLength - 1, SEEK_SET) >= 0 else {
        throw SSHHostTrustError.knownHostsFileUnwritable("Failed to inspect \(filePath)")
      }
      let bytesRead = read(fd, &lastByte, 1)
      guard bytesRead == 1 else {
        throw SSHHostTrustError.knownHostsFileUnwritable("Failed to inspect \(filePath)")
      }
      if lastByte != 0x0A { // not '\n'
        prefixNewline = "\n"
      }
    }

    let pattern = Self.formatHostPattern(host: expectedHost, port: expectedPort)
    let newEntry = "\(prefixNewline)\(pattern) \(challenge.presentedKey.keyType) \(challenge.presentedKey.keyBase64)\n"

    guard let entryData = newEntry.data(using: .utf8) else {
      throw SSHHostTrustError.parsingFailed("Failed to encode known_hosts entry as UTF-8.")
    }

    let persist = {
      guard let original = try? Data(contentsOf: self.knownHostsFileURL) else {
        throw SSHHostTrustError.knownHostsFileUnwritable(filePath)
      }
      try self.replaceKnownHosts(original + entryData)
    }

    if let authorizePersistence {
      guard try authorizePersistence(persist) else {
        throw SSHHostTrustError.staleChallenge
      }
    } else {
      guard !isCancelled() else { throw SSHHostTrustError.staleChallenge }
      try persist()
    }
    record("ssh.hostkey.trusted", expectedHost, expectedPort)
  }

  // MARK: - Known Hosts Management

  /// Loads all host key entries recorded in the known_hosts file.
  public func loadAllKnownHosts(
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) throws -> [KnownHostEntry] {
    guard let fd = try openSecureKnownHostsFile(createIfMissing: false) else {
      return []
    }
    close(fd)

    guard let contents = try? String(contentsOf: knownHostsFileURL, encoding: .utf8) else {
      return []
    }

    var entries: [KnownHostEntry] = []
    let lines = contents.components(separatedBy: .newlines)

    for (index, rawLine) in lines.enumerated() {
      guard !isCancelled() else { throw SSHHostTrustError.staleChallenge }
      let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

      let lineNumber = index + 1
      var parseTarget = trimmed
      var marker: String? = nil

      if parseTarget.hasPrefix("@") {
        let parts = parseTarget.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
        guard parts.count == 2 else { continue }
        marker = String(parts[0])
        parseTarget = String(parts[1])
      }

      let tokens = parseTarget.split(whereSeparator: { $0.isWhitespace })
      guard tokens.count >= 3 else { continue }

      let hostPattern = String(tokens[0])
      let keyType = String(tokens[1])
      let keyBase64 = String(tokens[2])
      let comment = tokens.count > 3 ? tokens[3...].joined(separator: " ") : nil
      let isHashed = hostPattern.hasPrefix("|1|")

      do {
        let keyRecord = try parseHostKeyLine(parseTarget, isCancelled: isCancelled)
        entries.append(
          KnownHostEntry(
            lineNumber: lineNumber,
            rawLine: trimmed,
            hostPattern: hostPattern,
            marker: marker,
            isHashed: isHashed,
            keyRecord: keyRecord
          )
        )
      } catch {
        let keyRecord = SSHHostKeyRecord(
          rawLine: trimmed,
          keyType: keyType,
          keyBase64: keyBase64,
          comment: comment,
          algorithm: keyType,
          bitLength: nil,
          fingerprintSHA256: "Unavailable",
          visualArt: nil
        )
        entries.append(
          KnownHostEntry(
            lineNumber: lineNumber,
            rawLine: trimmed,
            hostPattern: hostPattern,
            marker: marker,
            isHashed: isHashed,
            keyRecord: keyRecord
          )
        )
      }
    }

    return entries
  }

  /// Safely removes a recorded host key entry from the known_hosts file under POSIX file lock.
  public func removeKnownHostEntry(
    _ entry: KnownHostEntry,
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) throws {
    guard !isCancelled() else { throw SSHHostTrustError.staleChallenge }
    let filePath = knownHostsFileURL.path
    guard let lockFD = try lockKnownHosts(createIfMissing: false) else {
      throw SSHHostTrustError.knownHostsFileUnwritable(filePath)
    }
    defer { flock(lockFD, LOCK_UN); close(lockFD) }
    guard let fd = try openSecureKnownHostsFile(createIfMissing: false) else {
      throw SSHHostTrustError.knownHostsFileUnwritable(filePath)
    }
    defer { close(fd) }

    guard let contents = try? String(contentsOf: knownHostsFileURL, encoding: .utf8) else {
      throw SSHHostTrustError.knownHostsUnparseable("Cannot read \(filePath)")
    }

    let lines = contents.components(separatedBy: .newlines)
    var updatedLines: [String] = []
    var removed = false

    for (index, line) in lines.enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if (index + 1 == entry.lineNumber && trimmed == entry.rawLine) || (!removed && trimmed == entry.rawLine) {
        removed = true
        continue
      }
      updatedLines.append(line)
    }

    while let last = updatedLines.last, last.isEmpty {
      updatedLines.removeLast()
    }
    let newContent = updatedLines.isEmpty ? "" : updatedLines.joined(separator: "\n") + "\n"

    guard let data = newContent.data(using: .utf8) else {
      throw SSHHostTrustError.parsingFailed("Failed to encode updated known_hosts.")
    }

    try replaceKnownHosts(data)
    RedactedLogger.shared.info("hostkey", "ssh.hostkey.removed success")
    audit?("ssh.hostkey.removed", entry.hostPattern, .success, nil)
  }

  /// Rewrites the whole (already locked) known_hosts descriptor with `data`, truncating and syncing.
  private static func overwrite(fd: Int32, with data: Data, path: String) throws {
    guard lseek(fd, 0, SEEK_SET) >= 0 else {
      throw SSHHostTrustError.knownHostsFileUnwritable("Failed to rewind \(path)")
    }
    var offset = 0
    try data.withUnsafeBytes { ptr in
      guard let baseAddress = ptr.baseAddress else { return }
      while offset < ptr.count {
        let written = write(fd, baseAddress.advanced(by: offset), ptr.count - offset)
        if written > 0 {
          offset += written
        } else if written < 0 && errno == EINTR {
          continue
        } else {
          throw SSHHostTrustError.knownHostsFileUnwritable("Failed to write to \(path)")
        }
      }
    }
    guard ftruncate(fd, off_t(data.count)) == 0 else {
      throw SSHHostTrustError.knownHostsFileUnwritable("Failed to truncate \(path)")
    }
    guard fsync(fd) == 0 else {
      throw SSHHostTrustError.knownHostsFileUnwritable("Failed to sync \(path)")
    }
  }

  /// Explicit user-confirmed rotation (docs/09-security §4): atomically (under the known_hosts POSIX lock)
  /// replaces every recorded key for host:port with the presented one and emits `ssh.hostkey.rotated`
  /// carrying host:port plus old/new SHA-256 fingerprints (public values). Fails if nothing is trusted yet
  /// (use `approveChallenge`) or if the presented key is already the recorded one. Never called implicitly:
  /// a mismatch during evaluate/approve still fails closed.
  public func rotateKnownHostKey(
    _ challenge: SSHHostTrustChallenge,
    expectedHost: String,
    expectedPort: Int,
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) throws {
    guard challenge.host == expectedHost, challenge.port == expectedPort else {
      throw SSHHostTrustError.challengeMismatch(
        details: "Challenge endpoint \(challenge.host):\(challenge.port) does not match requested \(expectedHost):\(expectedPort)"
      )
    }
    try Self.validateEndpoint(host: expectedHost, port: expectedPort)
    guard !isCancelled() else { throw SSHHostTrustError.staleChallenge }

    let filePath = knownHostsFileURL.path
    guard let lockFD = try lockKnownHosts(createIfMissing: false) else {
      throw SSHHostTrustError.hostKeyNotFound(host: expectedHost, port: expectedPort)
    }
    defer { flock(lockFD, LOCK_UN); close(lockFD) }
    guard let fd = try openSecureKnownHostsFile(createIfMissing: false) else {
      throw SSHHostTrustError.hostKeyNotFound(host: expectedHost, port: expectedPort)
    }
    defer { close(fd) }

    let old = try queryRecordedKeys(host: expectedHost, port: expectedPort, isCancelled: isCancelled)
    guard !old.isEmpty else {
      throw SSHHostTrustError.hostKeyNotFound(host: expectedHost, port: expectedPort)
    }
    let new = challenge.presentedKey
    if old.contains(where: { $0.keyType == new.keyType && $0.keyBase64 == new.keyBase64 }) {
      throw SSHHostTrustError.challengeMismatch(details: "Presented key is already trusted for \(expectedHost):\(expectedPort)")
    }

    guard let originalData = try? Data(contentsOf: knownHostsFileURL),
          let contents = String(data: originalData, encoding: .utf8) else {
      throw SSHHostTrustError.knownHostsUnparseable("Cannot read \(filePath)")
    }
    let oldLines = Set(old.map(\.rawLine))
    var kept: [String] = []
    var removedCount = 0
    for line in contents.components(separatedBy: .newlines) {
      if oldLines.contains(line.trimmingCharacters(in: .whitespaces)) {
        removedCount += 1
        let pattern = Self.formatHostPattern(host: expectedHost, port: expectedPort)
        let parts = line.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
        guard parts.count == 2 else { throw SSHHostTrustError.knownHostsUnparseable("Malformed host entry") }
        var hosts = parts[0].split(separator: ",").map(String.init)
        if hosts.count > 1 {
          let matchedLiteral = hosts.contains { $0.lowercased() == pattern.lowercased() }
          hosts.removeAll { $0.lowercased() == pattern.lowercased() }
          if !hosts.isEmpty {
            if !matchedLiteral || hosts.contains(where: { $0.contains("*") || $0.contains("?") }) {
              // A wildcard may still match the rotated endpoint.
              hosts.insert("!" + pattern, at: 0)
            }
            kept.append(hosts.joined(separator: ",") + " " + parts[1])
          }
        } else if hosts.first?.lowercased() != pattern.lowercased() && !(hosts.first?.hasPrefix("|1|") ?? false) {
          kept.append("!" + pattern + "," + parts[0] + " " + parts[1])
        }
      } else {
        kept.append(line)
      }
    }
    guard removedCount >= old.count else {
      throw SSHHostTrustError.knownHostsUnparseable("Could not locate existing entries for \(expectedHost):\(expectedPort)")
    }
    while let last = kept.last, last.isEmpty { kept.removeLast() }
    kept.append("\(Self.formatHostPattern(host: expectedHost, port: expectedPort)) \(new.keyType) \(new.keyBase64)")
    guard let data = (kept.joined(separator: "\n") + "\n").data(using: .utf8) else {
      throw SSHHostTrustError.parsingFailed("Failed to encode updated known_hosts.")
    }
    guard !isCancelled() else { throw SSHHostTrustError.staleChallenge }

    try replaceKnownHosts(data)
    let oldFP = old.map(\.fingerprintSHA256).joined(separator: ",")
    let entity = "\(expectedHost):\(expectedPort) old=\(oldFP) new=\(new.fingerprintSHA256)"
    RedactedLogger.shared.info("hostkey", "ssh.hostkey.rotated \(entity)")
    audit?("ssh.hostkey.rotated", entity, .success, nil)
  }
}
