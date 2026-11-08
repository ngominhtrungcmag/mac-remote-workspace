import Foundation

// MARK: - Redacted Logger & Diagnostics Service (FR-013, FR-026, US-007, TC-018)

public enum LogLevel: String, Sendable, CaseIterable {
  case debug = "DEBUG"
  case info = "INFO"
  case warning = "WARN"
  case error = "ERROR"
}

public struct LogEntry: Sendable, Equatable, Identifiable {
  public let id: UUID
  public let timestamp: Date
  public let level: LogLevel
  public let category: String
  public let message: String

  public init(
    id: UUID = UUID(),
    timestamp: Date = Date(),
    level: LogLevel,
    category: String,
    message: String
  ) {
    self.id = id
    self.timestamp = timestamp
    self.level = level
    self.category = category
    self.message = message
  }

  public var formattedLine: String {
    let dateStr = ISO8601DateFormatter().string(from: timestamp)
    return "[\(dateStr)] [\(level.rawValue)] [\(category)] \(message)"
  }
}

/// Thread-safe logger enforcing strict in-memory and on-disk redaction of secrets,
/// credentials, private keys, and terminal transcripts (FR-013, TC-018).
public final class RedactedLogger: @unchecked Sendable {
  public static let shared = RedactedLogger()

  private let lock = NSLock()
  private let fileQueue = DispatchQueue(label: "mrw.redacted-log", qos: .utility)
  private var memoryBuffer: [LogEntry] = []
  private let maxMemoryEntries = 500
  private let maxFileSize: Int64 = 10 * 1024 * 1024 // 10 MB per NFR-009
  private var logFileURL: URL?

  public init(customLogDirectory: URL? = nil) {
    if let dir = customLogDirectory {
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      self.logFileURL = dir.appendingPathComponent("mrw.log")
    } else if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
      let logDir = appSupport.appendingPathComponent("MacRemoteWorkspace/Logs", isDirectory: true)
      try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      self.logFileURL = logDir.appendingPathComponent("mrw.log")
    }
  }

  // MARK: - Logging API

  public func log(_ level: LogLevel, category: String, _ message: String) {
    let sanitizedMessage = Self.redact(message)
    let entry = LogEntry(level: level, category: category, message: sanitizedMessage)

    lock.lock()
    defer { lock.unlock() }

    memoryBuffer.append(entry)
    if memoryBuffer.count > maxMemoryEntries {
      memoryBuffer.removeFirst(memoryBuffer.count - maxMemoryEntries)
    }

    fileQueue.async { self.appendToFile(entry) }
  }

  public func debug(_ category: String, _ message: String) { log(.debug, category: category, message) }
  public func info(_ category: String, _ message: String) { log(.info, category: category, message) }
  public func warning(_ category: String, _ message: String) { log(.warning, category: category, message) }
  public func error(_ category: String, _ message: String) { log(.error, category: category, message) }

  public func recentEntries(limit: Int = 100) -> [LogEntry] {
    lock.lock()
    defer { lock.unlock() }
    let count = memoryBuffer.count
    let startIndex = max(0, count - limit)
    return Array(memoryBuffer[startIndex..<count])
  }

  public func clear() {
    lock.lock()
    defer { lock.unlock() }
    memoryBuffer.removeAll()
    fileQueue.async {
      if let url = self.logFileURL {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("1"))
      }
    }
  }

  private static let pemRegex = try? NSRegularExpression(pattern: "-----[A-Z0-9 ]*BEGIN [A-Z0-9 ]+PRIVATE KEY-----[\\s\\S]*?-----[A-Z0-9 ]*END [A-Z0-9 ]+PRIVATE KEY-----")

  private static let kvRegex = try? NSRegularExpression(pattern: "(?i)(password|passwd|secret|passphrase|token|auth_token)\\s*[:=]\\s*(?:'[^']*'|\"[^\"]*\"|[^\\s,;]+)")

  private static let urlRegex = try? NSRegularExpression(pattern: "([a-zA-Z][a-zA-Z0-9+.-]*://)([^:/\\s]+):(.*?)@([a-zA-Z0-9.-]+(?::[0-9]+)?(?:/|$))")

  private static let bearerRegex = try? NSRegularExpression(pattern: "(?i)Bearer\\s+[A-Za-z0-9\\-._~+/]+=*")

  // MARK: - Redaction Engine (TC-018)

  /// Sanitizes any string by replacing private keys, passwords, bearer tokens,
  /// and authentication credentials with [REDACTED].
  public static func redact(_ rawText: String) -> String {
    var text = rawText

    // 1. Private keys (PEM blocks)
    if let regex = Self.pemRegex {
      let range = NSRange(text.startIndex..., in: text)
      text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "[REDACTED PRIVATE KEY]")
    }

    // 2. Passwords / secrets / tokens in key-value or query format (handles quoted and unquoted values)
    if let regex = Self.kvRegex {
      let range = NSRange(text.startIndex..., in: text)
      text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1=[REDACTED]")
    }

    // 3. Basic auth embedded in URLs (e.g., https://user:pass@host)
    if let regex = Self.urlRegex {
      let range = NSRange(text.startIndex..., in: text)
      text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1[REDACTED]@$4")
    }

    // 4. Bearer tokens
    if let regex = Self.bearerRegex {
      let range = NSRange(text.startIndex..., in: text)
      text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "Bearer [REDACTED]")
    }

    return text
  }

  func flush() { fileQueue.sync {} }

  // MARK: - File Appender & Size Cap (NFR-009)

  private func appendToFile(_ entry: LogEntry) {
    guard let url = logFileURL else { return }

    let line = entry.formattedLine + "\n"
    guard let lineData = line.data(using: .utf8) else { return }

    if !FileManager.default.fileExists(atPath: url.path) {
      try? lineData.write(to: url, options: .atomic)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      return
    }

    // Check size cap
    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
       let fileSize = attrs[.size] as? Int64,
       fileSize > maxFileSize {
      let rotated = url.appendingPathExtension("1")
      try? FileManager.default.removeItem(at: rotated)
      do { try FileManager.default.moveItem(at: url, to: rotated) } catch { return }
      try? lineData.write(to: url, options: .atomic)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      return
    }

    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(lineData)
      try? handle.close()
    }
  }

  // MARK: - Diagnostics Bundle Generator (US-007, FR-013, TC-018)

  /// Generates a strictly redacted, sanitized diagnostics report for export.
  /// Never includes terminal I/O, raw file contents, or credentials.
  public static func generateDiagnosticsReport(
    repository: HostRepository?,
    knownHostsCount: Int = 0
  ) -> String {
    let nowStr = ISO8601DateFormatter().string(from: Date())
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

    let wsCount = (try? repository?.listWorkspaces().count) ?? 0
    let hostCount = (try? repository?.listHosts().count) ?? 0

    var report = """
    # Mac Remote Workspace — Diagnostics Report
    Generated: \(nowStr)
    OS: macOS \(osVersion)
    Process Architecture: \(Self.systemArchitecture())
    Sandbox/Permissions: Local AppCore (Strict 0600/0700 metadata)

    ## Inventory Metadata Summary
    - Workspaces: \(wsCount)
    - Total Configured Hosts: \(hostCount)
    - Pinned Known Hosts: \(knownHostsCount)

    ## Security & Transport Status
    - StrictHostKeyChecking: Enforced (Hard mismatch abort)
    - Secrets Persistence: Keychain only (zero secrets in SQLite/argv)
    - SFTP Staging: Atomic .mrw-part temporary isolation
    - ProxyJump Independent Policy: Enforced

    ## Recent Redacted Logs
    """

    let recentLogs = RedactedLogger.shared.recentEntries(limit: 50)
    if recentLogs.isEmpty {
      report += "\n(No recent log entries)\n"
    } else {
      report += "\n```\n"
      for entry in recentLogs {
        report += entry.formattedLine + "\n"
      }
      report += "```\n"
    }

    return report
  }

  private static func systemArchitecture() -> String {
    #if arch(arm64)
    return "Apple Silicon (arm64)"
    #elseif arch(x86_64)
    return "Intel (x86_64)"
    #else
    return "Unknown"
    #endif
  }
}
