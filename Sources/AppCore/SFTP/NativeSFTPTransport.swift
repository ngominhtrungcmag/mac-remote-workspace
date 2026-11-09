import Darwin
import Foundation

// MARK: - Models

/// An entry representing a file or directory in a remote SFTP filesystem.
public struct SFTPFileEntry: Sendable, Equatable, Identifiable, Hashable {
  public var id: String { path }
  public let name: String
  public let path: String
  public let isDirectory: Bool
  public let isSymlink: Bool
  public let size: Int64
  public let permissions: String
  public let modificationDateString: String?
  public let symlinkTarget: String?

  public init(
    name: String,
    path: String,
    isDirectory: Bool,
    isSymlink: Bool,
    size: Int64,
    permissions: String,
    modificationDateString: String? = nil,
    symlinkTarget: String? = nil
  ) {
    self.name = name
    self.path = path
    self.isDirectory = isDirectory
    self.isSymlink = isSymlink
    self.size = size
    self.permissions = permissions
    self.modificationDateString = modificationDateString
    self.symlinkTarget = symlinkTarget
  }
}

/// Errors raised during SFTP operations.
public enum SFTPError: Error, AppCoreLocalizedError, Sendable, Equatable {
  case invalidPath(String)
  case permissionDenied(String)
  case fileNotFound(String)
  case collision(String)
  case remoteError(String)
  case connectionFailed(String)
  case cancelled
  case askpassUnavailable

  public func displayDescription(locale: Locale?) -> String? {
    switch self {
    case .invalidPath(let path):
      return AppCoreLocalization.format("Invalid remote path '%1$@'.", path, locale: locale)
    case .permissionDenied(let path):
      return AppCoreLocalization.format("Permission denied accessing '%1$@'.", path, locale: locale)
    case .fileNotFound(let path):
      return AppCoreLocalization.format("Remote path not found: '%1$@'.", path, locale: locale)
    case .collision(let path):
      return AppCoreLocalization.format("Destination file already exists: '%1$@'.", path, locale: locale)
    case .remoteError(let details):
      return AppCoreLocalization.format("SFTP remote error: %1$@", details, locale: locale)
    case .connectionFailed(let details):
      return AppCoreLocalization.format("SFTP connection failed: %1$@", details, locale: locale)
    case .cancelled:
      return AppCoreLocalization.string("Transfer was cancelled.", locale: locale)
    case .askpassUnavailable:
      return AppCoreLocalization.string("Keychain credential helper is unavailable.", locale: locale)
    }
  }
}

public enum SFTPTransferKind: String, Sendable, Equatable, CaseIterable {
  case upload = "Upload"
  case download = "Download"
}

public enum SFTPTransferStatus: Sendable, Equatable {
  case queued
  case running(progress: Double?)
  case completed
  case failed(String)
  case cancelled

  public var label: String {
    switch self {
    case .queued: "Queued"
    case .running(let progress): progress.map { "\(Int($0 * 100))%" } ?? "Running"
    case .completed: "Completed"
    case .failed(let err): "Failed: \(err)"
    case .cancelled: "Cancelled"
    }
  }
}

public struct SFTPTransferItem: Sendable, Equatable, Identifiable {
  public let id: UUID
  public let kind: SFTPTransferKind
  public let sourceDescription: String
  public let destinationDescription: String
  public let totalBytes: Int64
  public var transferredBytes: Int64
  public var status: SFTPTransferStatus
  public let startedAt: Date
  public var finishedAt: Date?

  public init(
    id: UUID = UUID(),
    kind: SFTPTransferKind,
    sourceDescription: String,
    destinationDescription: String,
    totalBytes: Int64,
    transferredBytes: Int64 = 0,
    status: SFTPTransferStatus = .queued,
    startedAt: Date = Date(),
    finishedAt: Date? = nil
  ) {
    self.id = id
    self.kind = kind
    self.sourceDescription = sourceDescription
    self.destinationDescription = destinationDescription
    self.totalBytes = totalBytes
    self.transferredBytes = transferredBytes
    self.status = status
    self.startedAt = startedAt
    self.finishedAt = finishedAt
  }
}

final class SFTPOutputCollector: @unchecked Sendable {
  private let lock = NSLock()
  private let limit: Int
  private var stored = Data()
  private var exceeded = false

  init(limit: Int) { self.limit = limit }

  func append(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    guard !exceeded else { return }
    guard data.count <= limit - stored.count else { exceeded = true; return }
    stored.append(data)
  }

  var didExceedLimit: Bool {
    lock.lock()
    defer { lock.unlock() }
    return exceeded
  }

  var data: Data {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
}

final class SFTPIdleBox: @unchecked Sendable {
  private let lock = NSLock()
  private var tracker: SFTPIdleTracker

  init(now: UInt64) {
    self.tracker = SFTPIdleTracker(now: now)
  }

  @discardableResult
  func observe(size: Int64, now: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return tracker.observe(size: size, now: now)
  }

  func hasTimedOut(now: UInt64, seconds: TimeInterval) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return tracker.hasTimedOut(now: now, seconds: seconds)
  }
}

struct SFTPIdleTracker {
  private(set) var lastSize: Int64 = 0
  private var lastChange: UInt64

  init(now: UInt64) { lastChange = now }

  mutating func observe(size: Int64, now: UInt64) -> Bool {
    guard size > lastSize else { return false }
    lastSize = size
    lastChange = now
    return true
  }

  func hasTimedOut(now: UInt64, seconds: TimeInterval) -> Bool {
    now - lastChange >= UInt64(seconds * 1_000_000_000)
  }
}

/// Bounded streaming parser for OpenSSH `/usr/bin/sftp -vvv` stderr during `put`:
/// counts successful acknowledged upload bytes (`In write loop, ack for <id> <len> bytes at <offset>`)
/// while discarding verbose diagnostic lines so neither secrets/paths nor multi-gigabyte debug logs are retained.
final class SFTPUploadDiagnosticStream: @unchecked Sendable {
  private static let maxLineBytes = 4096
  private static let ackMarker = "In write loop, ack for "

  private let lock = NSLock()
  private var lineBuffer = Data()
  private var discardingOversizedLine = false
  private(set) var acknowledgedBytes: Int64 = 0
  private var previousLineWasSuccessfulStatus = false

  func consume(
    _ chunk: Data,
    into collector: SFTPOutputCollector,
    onAcknowledgedBytes: (Int64) -> Void = { _ in }
  ) {
    for byte in chunk {
      if byte == 0x0A {
        let completedLine: Data? = {
          lock.lock()
          defer {
            lineBuffer.removeAll(keepingCapacity: true)
            discardingOversizedLine = false
            lock.unlock()
          }
          return discardingOversizedLine ? nil : lineBuffer
        }()
        if let completedLine {
          processLine(completedLine, into: collector, onAcknowledgedBytes: onAcknowledgedBytes)
        }
      } else if byte != 0x0D {
        lock.lock()
        if !discardingOversizedLine {
          if lineBuffer.count < Self.maxLineBytes {
            lineBuffer.append(byte)
          } else {
            lineBuffer.removeAll(keepingCapacity: true)
            discardingOversizedLine = true
          }
        }
        lock.unlock()
      }
    }
  }

  func finish(
    into collector: SFTPOutputCollector,
    onAcknowledgedBytes: (Int64) -> Void = { _ in }
  ) {
    let trailingLine: Data? = {
      lock.lock()
      defer {
        lineBuffer.removeAll(keepingCapacity: true)
        discardingOversizedLine = false
        lock.unlock()
      }
      return (!discardingOversizedLine && !lineBuffer.isEmpty) ? lineBuffer : nil
    }()
    if let trailingLine {
      processLine(trailingLine, into: collector, onAcknowledgedBytes: onAcknowledgedBytes)
    }
  }

  private func processLine(
    _ lineData: Data,
    into collector: SFTPOutputCollector,
    onAcknowledgedBytes: (Int64) -> Void
  ) {
    guard let line = String(data: lineData, encoding: .utf8) else { return }
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    let successfulStatus = previousLineWasSuccessfulStatus
    previousLineWasSuccessfulStatus = trimmed == "debug3: SSH2_FXP_STATUS 0"
    if successfulStatus, let length = Self.parseWriteAckLength(trimmed) {
      let (total, overflow) = acknowledgedBytes.addingReportingOverflow(length)
      guard !overflow else { return }
      acknowledgedBytes = total
      onAcknowledgedBytes(total)
    }
    // Upload diagnostics are never returned to callers, including unprefixed SSH messages.
  }

  static func parseWriteAckLength(_ line: String) -> Int64? {
    guard line.hasPrefix("debug3:") else { return nil }
    guard let markerRange = line.range(of: ackMarker) else { return nil }
    let remainder = line[markerRange.upperBound...]
    let parts = remainder.split(whereSeparator: \.isWhitespace)
    // Expected tokens: <id> <len> "bytes" "at" <offset>
    guard parts.count == 5,
          parts[2] == "bytes",
          parts[3] == "at",
          UInt64(parts[0]) != nil,
          let length = Int64(parts[1]), length > 0,
          let offset = Int64(parts[4]), offset >= 0 else {
      return nil
    }
    let (_, overflow) = offset.addingReportingOverflow(length)
    return overflow ? nil : length
  }
}

/// POSIX read returns available bytes immediately; FileHandle.readData(ofLength:) waits to fill the buffer.
final class SFTPNonblockingPipe {
  private let descriptor: Int32
  private var bytes = [UInt8](repeating: 0, count: 65536)
  private(set) var reachedEOF = false

  init(_ handle: FileHandle) throws {
    descriptor = handle.fileDescriptor
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
      throw POSIXError(.EIO)
    }
  }

  func read() throws -> Data? {
    guard !reachedEOF else { return nil }
    let count = Darwin.read(descriptor, &bytes, bytes.count)
    if count > 0 { return Data(bytes.prefix(count)) }
    if count == 0 { reachedEOF = true; return nil }
    if errno == EAGAIN || errno == EINTR { return nil }
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}

enum SFTPProcessTeardown {
  static func stop(_ process: Process) -> Bool {
    let group = process.processIdentifier
    // The caller verifies group ownership immediately after launch.
    _ = kill(-group, SIGTERM)
    let deadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
    while process.isRunning && DispatchTime.now().uptimeNanoseconds < deadline { usleep(5_000) }
    _ = kill(-group, SIGKILL)
    let killDeadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
    while process.isRunning && DispatchTime.now().uptimeNanoseconds < killDeadline { usleep(5_000) }
    return !process.isRunning
  }
}

// MARK: - Native SFTP Client

/// Thread-safe client performing native SFTP operations over OpenSSH's `/usr/bin/sftp` in batch mode.
public final class NativeSFTPClient: Sendable {
  public let configuration: NativeSSHConfiguration
  let uploadIdleTimeoutSeconds: TimeInterval

  public convenience init(configuration: NativeSSHConfiguration) throws {
    try self.init(configuration: configuration, uploadIdleTimeoutSeconds: 300)
  }

  init(configuration: NativeSSHConfiguration, uploadIdleTimeoutSeconds: TimeInterval) throws {
    try NativeSSHSession.validate(configuration: configuration)
    guard configuration.proxyJump == nil else {
      throw SFTPError.connectionFailed(AppCoreLocalization.string("ProxyJump is not supported for SFTP."))
    }
    self.configuration = configuration
    self.uploadIdleTimeoutSeconds = max(0.05, uploadIdleTimeoutSeconds)
  }

  // MARK: - Path Validation & Sanitization

  /// Validates and sanitizes a remote POSIX path:
  /// - Disallows NUL bytes, CR, LF
  /// - Strips redundant trailing slashes unless root
  public static func sanitizeRemotePath(_ path: String) throws -> String {
    guard !path.isEmpty else { throw SFTPError.invalidPath(path) }

    // Disallow NUL and newlines to prevent command injection in batch mode
    let disallowed = CharacterSet(charactersIn: "\0\r\n")
    guard path.rangeOfCharacter(from: disallowed) == nil else {
      throw SFTPError.invalidPath(path)
    }

    if path == "/" { return "/" }
    var cleaned = path
    while cleaned.hasSuffix("/") && cleaned.count > 1 {
      cleaned.removeLast()
    }
    return cleaned
  }

  /// Quotes a path for sftp batch mode, where quotes also suppress glob expansion.
  private static func quoteForBatch(_ path: String) -> String {
    let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }

  // MARK: - Command Building & Error Mapping (FR-011)

  static func deleteFileCommand(_ cleanPath: String) -> String { "rm \(quoteForBatch(cleanPath))" }
  static func deleteDirectoryCommand(_ cleanPath: String) -> String { "rmdir \(quoteForBatch(cleanPath))" }
  static func renameCommand(from old: String, to new: String) -> String {
    "rename \(quoteForBatch(old)) \(quoteForBatch(new))"
  }

  /// Maps sftp stderr to a typed error. `fallback` is used when stderr is empty/unrecognized.
  static func mapRemoteError(stderr: String, path: String, fallback: String) -> SFTPError {
    let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    if err.localizedCaseInsensitiveContains("Permission denied") {
      return .permissionDenied(path)
    } else if err.localizedCaseInsensitiveContains("No such file") {
      return .fileNotFound(path)
    }
    return .remoteError(err.isEmpty ? fallback : err)
  }

  // MARK: - Execution Engine

  private func executeBatchCommands(
    _ commands: [String],
    timeoutSeconds: TimeInterval? = 30,
    progressFile: URL? = nil,
    trackUploadAckProgress: Bool = false,
    onProgress: @escaping @Sendable (Int64) -> Void = { _ in },
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
    guard !isCancelled() else { throw SFTPError.cancelled }

    var args: [String] = []
    if trackUploadAckProgress {
      args.append("-vvv")
    }
    args.append(contentsOf: [
      "-F", "/dev/null",
      "-o", "GlobalKnownHostsFile=/dev/null",
      "-o", "StrictHostKeyChecking=yes",
      "-o", "UserKnownHostsFile=\(configuration.knownHostsFileURL.path)",
      "-P", String(configuration.port),
    ])

    var env: [String: String] = [
      "PATH": "/usr/bin:/bin", "LC_ALL": "C", "HOME": NSHomeDirectory(),
      "TERM": configuration.termEnvironment,
    ]
    var askpassHelper: KeychainAskpassHelper?
    defer { askpassHelper?.cleanup() }

    switch configuration.authentication {
    case .agent(let socketURL):
      args.append(contentsOf: [
        "-o", "BatchMode=yes",
        "-o", "PasswordAuthentication=no",
        "-o", "PubkeyAuthentication=yes",
      ])
      env["SSH_AUTH_SOCK"] = socketURL.path

    case .identityFile(let fileURL):
      args.append(contentsOf: [
        "-o", "BatchMode=yes",
        "-o", "IdentityFile=\(fileURL.path)",
        "-o", "PasswordAuthentication=no",
        "-o", "PubkeyAuthentication=yes",
      ])
      env["SSH_AUTH_SOCK"] = ""

    case .keychainAskpass(_, _, let identityFile):
      do {
        let helper = try KeychainAskpassHelper.install(for: configuration, isCancelled: isCancelled)
        askpassHelper = helper
        env.merge(helper.childEnvironment(for: configuration.authentication)) { _, new in new }
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = ":0"
      } catch {
        throw SFTPError.askpassUnavailable
      }

      args.append(contentsOf: [
        "-o", "BatchMode=no",
        "-o", "NumberOfPasswordPrompts=1",
      ])
      if let identityFile {
        args.append(contentsOf: [
          "-o", "IdentityFile=\(identityFile.path)",
          "-o", "PubkeyAuthentication=yes",
        ])
      }
    }

    // Pass batch mode reading from stdin
    args.append(contentsOf: ["-b", "-"])
    args.append("\(configuration.username)@\(configuration.host)")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
    process.arguments = args
    process.environment = env

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    defer {
      try? stdinPipe.fileHandleForWriting.close()
      try? stdoutPipe.fileHandleForReading.close()
      try? stderrPipe.fileHandleForReading.close()
    }
    // Foundation launches a separate process group on macOS; fail closed if that changes.
    guard getpgid(process.processIdentifier) == process.processIdentifier else {
      process.terminate()
      throw SFTPError.connectionFailed("SFTP subprocess has no isolated process group.")
    }
    defer { _ = SFTPProcessTeardown.stop(process) }

    let batchScript = commands.joined(separator: "\n") + "\nquit\n"
    try stdinPipe.fileHandleForWriting.write(contentsOf: Data(batchScript.utf8))
    try stdinPipe.fileHandleForWriting.close()

    let outCollector = SFTPOutputCollector(limit: 4 * 1024 * 1024)
    let errCollector = SFTPOutputCollector(limit: 4 * 1024 * 1024)
    let idle = SFTPIdleBox(now: DispatchTime.now().uptimeNanoseconds)
    let diagnostics = SFTPUploadDiagnosticStream()
    let output = try SFTPNonblockingPipe(stdoutPipe.fileHandleForReading)
    let errors = try SFTPNonblockingPipe(stderrPipe.fileHandleForReading)
    var drainDeadline: UInt64?

    while true {
      if let chunk = try output.read(), !trackUploadAckProgress { outCollector.append(chunk) }
      if let chunk = try errors.read() {
        if trackUploadAckProgress {
          diagnostics.consume(chunk, into: errCollector) { acknowledged in
            if idle.observe(size: acknowledged, now: DispatchTime.now().uptimeNanoseconds) {
              onProgress(acknowledged)
            }
          }
        } else {
          errCollector.append(chunk)
        }
      }
      if let progressFile,
        let size = (try? FileManager.default.attributesOfItem(atPath: progressFile.path)[.size] as? NSNumber)?.int64Value,
        idle.observe(size: size, now: DispatchTime.now().uptimeNanoseconds) {
        onProgress(size)
      }
      if outCollector.didExceedLimit || errCollector.didExceedLimit {
        throw SFTPError.remoteError("SFTP output exceeded the 4 MiB limit.")
      }
      if isCancelled() { throw SFTPError.cancelled }
      let now = DispatchTime.now().uptimeNanoseconds
      if !process.isRunning {
        if output.reachedEOF && errors.reachedEOF { break }
        // A descendant retaining a pipe must never keep the caller waiting indefinitely.
        if drainDeadline == nil { drainDeadline = now + 1_000_000_000 }
        if now >= drainDeadline! {
          throw SFTPError.remoteError("SFTP subprocess output did not close.")
        }
      } else if let timeoutSeconds, idle.hasTimedOut(now: now, seconds: timeoutSeconds) {
        throw SFTPError.remoteError("SFTP subprocess timed out after \(Int(ceil(timeoutSeconds))) seconds.")
      }
      usleep(5_000)
    }
    diagnostics.finish(into: errCollector) { acknowledged in onProgress(acknowledged) }
    _ = askpassHelper

    guard !outCollector.didExceedLimit, !errCollector.didExceedLimit else {
      throw SFTPError.remoteError("SFTP output exceeded the 4 MiB limit.")
    }
    guard let stdoutStr = String(data: outCollector.data, encoding: .utf8),
          let stderrStr = String(data: errCollector.data, encoding: .utf8) else {
      throw SFTPError.remoteError("SFTP output is not valid UTF-8.")
    }

    return (process.terminationStatus, stdoutStr, stderrStr)
  }

  // MARK: - Directory Listing (FR-009 / US-011)

  /// Lists entries in the specified remote directory.
  public func listDirectory(
    at remotePath: String,
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) throws -> [SFTPFileEntry] {
    let cleanPath = try Self.sanitizeRemotePath(remotePath)
    let quoted = Self.quoteForBatch(cleanPath)

    // Execute cd and ls -la in batch mode
    let res = try executeBatchCommands([
      "cd \(quoted)",
      "ls -la"
    ], isCancelled: isCancelled)

    if res.exitCode != 0 {
      let err = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      if err.localizedCaseInsensitiveContains("Permission denied") {
        throw SFTPError.permissionDenied(cleanPath)
      } else if err.localizedCaseInsensitiveContains("No such file") || err.localizedCaseInsensitiveContains("not found") {
        throw SFTPError.fileNotFound(cleanPath)
      } else {
        throw SFTPError.remoteError(err.isEmpty ? "Exit code \(res.exitCode)" : err)
      }
    }

    guard let entries = Self.parseListing(res.stdout, inDirectory: cleanPath) else {
      throw SFTPError.remoteError(AppCoreLocalization.string("SFTP listing contains an invalid or unsupported filename."))
    }
    return entries
  }

  /// Parses `ls -la` output lines into structured SFTPFileEntry objects.
  public static func parseListingOutput(_ output: String, inDirectory: String) -> [SFTPFileEntry] {
    parseListing(output, inDirectory: inDirectory) ?? []
  }

  // shortcut: crafted newlines can imitate listing rows, switch to structured SFTP enumeration.
  private static func parseListing(_ output: String, inDirectory: String) -> [SFTPFileEntry]? {
    var entries: [SFTPFileEntry] = []
    let lines = output.components(separatedBy: .newlines)

    for rawLine in lines {
      let line = rawLine
      guard !line.isEmpty else { continue }
      // Skip prompts or headers
      if line.hasPrefix("sftp>") || line.hasPrefix("Changing to:") { continue }

      // Standard Unix ls -l format:
      // [perms] [links] [owner] [group] [size] [month] [day] [time/year] [name]
      let tokens = line.split(whereSeparator: { $0.isWhitespace })
      guard tokens.count >= 9 else { return nil }

      let perms = String(tokens[0])
      // Verify permissions start with d, l, c, b, or -
      guard let firstChar = perms.first, "dlcb-ps".contains(firstChar) else { return nil }

      guard let size = Int64(tokens[4]) else { return nil }
      let dateString = String(line[tokens[5].startIndex..<tokens[7].endIndex])

      // Name is everything after the 8th token (tokens[7])
      let suffix = line[tokens[7].endIndex...]
      guard let separator = suffix.first, separator.isWhitespace else { return nil }
      let rawName = String(suffix.dropFirst())
      guard !rawName.isEmpty, rawName != ".", rawName != ".." else { continue }

      let isDirectory = perms.hasPrefix("d")
      let isSymlink = perms.hasPrefix("l")

      let fileName: String
      let symlinkTarget: String?
      if isSymlink && rawName.contains(" -> ") {
        let parts = rawName.components(separatedBy: " -> ")
        guard parts.count == 2 else { continue }
        fileName = parts[0]
        symlinkTarget = parts[1]
      } else {
        fileName = rawName
        symlinkTarget = nil
      }

      let fullPath = inDirectory == "/" ? "/\(fileName)" : "\(inDirectory)/\(fileName)"

      entries.append(
        SFTPFileEntry(
          name: fileName,
          path: fullPath,
          isDirectory: isDirectory,
          isSymlink: isSymlink,
          size: size,
          permissions: perms,
          modificationDateString: dateString,
          symlinkTarget: symlinkTarget
        )
      )
    }

    // Sort: directories first, then alphabetically
    return entries.sorted { lhs, rhs in
      if lhs.isDirectory != rhs.isDirectory {
        return lhs.isDirectory && !rhs.isDirectory
      }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
  }

  // MARK: - Directory Creation & Deletion (FR-011 / US-013)

  public func createDirectory(
    at remotePath: String,
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) throws {
    let cleanPath = try Self.sanitizeRemotePath(remotePath)
    let quoted = Self.quoteForBatch(cleanPath)

    let res = try executeBatchCommands(["mkdir \(quoted)"], isCancelled: isCancelled)
    if res.exitCode != 0 {
      let err = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      if err.localizedCaseInsensitiveContains("Permission denied") {
        throw SFTPError.permissionDenied(cleanPath)
      } else {
        throw SFTPError.remoteError(err.isEmpty ? "Failed to create directory." : err)
      }
    }
  }

  public func deleteFile(
    at remotePath: String,
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) throws {
    let cleanPath = try Self.sanitizeRemotePath(remotePath)
    let res = try executeBatchCommands([Self.deleteFileCommand(cleanPath)], isCancelled: isCancelled)
    if res.exitCode != 0 {
      throw Self.mapRemoteError(stderr: res.stderr, path: cleanPath, fallback: "Failed to delete file.")
    }
  }

  public func deleteDirectory(
    at remotePath: String,
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) throws {
    let cleanPath = try Self.sanitizeRemotePath(remotePath)
    let res = try executeBatchCommands([Self.deleteDirectoryCommand(cleanPath)], isCancelled: isCancelled)
    if res.exitCode != 0 {
      throw Self.mapRemoteError(stderr: res.stderr, path: cleanPath, fallback: "Failed to delete directory.")
    }
  }

  /// Renames a remote path. Never replaces an existing destination: throws `SFTPError.collision`.
  public func rename(
    from oldPath: String,
    to newPath: String,
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) throws {
    let cleanOld = try Self.sanitizeRemotePath(oldPath)
    let cleanNew = try Self.sanitizeRemotePath(newPath)

    let parentDir = (cleanNew as NSString).deletingLastPathComponent
    let newName = (cleanNew as NSString).lastPathComponent
    let existing = try listDirectory(at: parentDir.isEmpty ? "/" : parentDir, isCancelled: isCancelled)
    if existing.contains(where: { $0.name == newName }) {
      throw SFTPError.collision(cleanNew)
    }

    let res = try executeBatchCommands([Self.renameCommand(from: cleanOld, to: cleanNew)], isCancelled: isCancelled)
    if res.exitCode != 0 {
      throw Self.mapRemoteError(stderr: res.stderr, path: cleanOld, fallback: "Failed to rename path.")
    }
  }

  /// Resolves a user-typed new name into a sibling path. Rejects empty names, separators, "." and "..".
  public static func renameTarget(for oldPath: String, newName: String) throws -> String {
    let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
      throw SFTPError.invalidPath(newName)
    }
    let cleanOld = try sanitizeRemotePath(oldPath)
    let parent = (cleanOld as NSString).deletingLastPathComponent
    let target = parent == "/" || parent.isEmpty ? "/\(name)" : "\(parent)/\(name)"
    return try sanitizeRemotePath(target)
  }

  /// Confirmation text that always names the exact remote target (FR-011).
  public static func deleteConfirmationMessage(for entry: SFTPFileEntry) -> String {
    "Are you sure you want to delete this \(entry.isDirectory ? "directory" : "file")?\n\nTarget path: '\(entry.path)'\nThis operation cannot be undone."
  }

  // MARK: - Safe Upload & Download (FR-010 / TC-010)

  /// Safe upload strategy:
  /// 1. Verifies local file exists and is readable.
  /// 2. If not `overwrite`, checks whether destination exists; if so, throws `SFTPError.collision`.
  /// 3. Uploads to `.mrw-part-[uuid]` temporary staging path.
  /// 4. Atomically links the staged file when overwrite is disallowed; otherwise renames it.
  /// 5. On cancellation or failure, removes temporary staging file; target is never corrupted.
  public func uploadFile(
    from localURL: URL,
    to remotePath: String,
    overwrite: Bool,
    onProgress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in },
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) throws {
    guard !isCancelled() else { throw SFTPError.cancelled }
    guard FileManager.default.fileExists(atPath: localURL.path) else {
      throw SFTPError.fileNotFound(localURL.path)
    }

    let cleanRemote = try Self.sanitizeRemotePath(remotePath)
    let parentDir = (cleanRemote as NSString).deletingLastPathComponent
    let fileName = (cleanRemote as NSString).lastPathComponent

    // Collision check
    if !overwrite {
      let existing = try listDirectory(at: parentDir, isCancelled: isCancelled)
      if existing.contains(where: { $0.name == fileName }) {
        throw SFTPError.collision(cleanRemote)
      }
    }

    let stagingPath = "\(cleanRemote).mrw-part-\(UUID().uuidString)"
    let quotedLocal = Self.quoteForBatch(localURL.path)
    let quotedStaging = Self.quoteForBatch(stagingPath)
    let quotedTarget = Self.quoteForBatch(cleanRemote)

    onProgress(0, 0)
    do {
      let res = try executeBatchCommands(
        ["put \(quotedLocal) \(quotedStaging)"],
        timeoutSeconds: uploadIdleTimeoutSeconds,
        trackUploadAckProgress: true,
        onProgress: { onProgress($0, 0) },
        isCancelled: isCancelled
      )
      if res.exitCode != 0 {
        let err = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        throw SFTPError.remoteError(err.isEmpty ? "Upload failed." : err)
      }
      guard !isCancelled() else { throw SFTPError.cancelled }
      // Hard-link creation fails if the destination exists; unsupported servers fail closed.
      let commitCommand = overwrite ? "rename" : "ln"
      let commit = try executeBatchCommands(["\(commitCommand) \(quotedStaging) \(quotedTarget)"],
        isCancelled: isCancelled)
      guard commit.exitCode == 0 else {
        let err = commit.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        throw SFTPError.remoteError(overwrite
          ? (err.isEmpty ? "Upload failed." : err)
          : "Upload could not safely create the destination; it may already exist or the server may not support hard links. \(err)")
      }
      if !overwrite { _ = try? executeBatchCommands(["-rm \(quotedStaging)"], timeoutSeconds: 2) }
    } catch {
      // Clean up staging file on cancellation or failure
      _ = try? executeBatchCommands(["-rm \(quotedStaging)"], timeoutSeconds: 2)
      throw error
    }
  }

  /// Safe download strategy:
  /// 1. Determines local destination.
  /// 2. If not `overwrite` and local destination exists, throws `SFTPError.collision`.
  /// 3. Downloads to temporary `.mrw-part-[uuid]` in destination folder.
  /// 4. On success, moves/replaces temporary file to final target.
  /// 5. On cancellation or failure, removes temporary file; target is never corrupted.
  public func downloadFile(
    from remotePath: String,
    to localDirectoryURL: URL,
    filename: String,
    overwrite: Bool,
    onProgress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in },
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) throws -> URL {
    let cleanRemote = try Self.sanitizeRemotePath(remotePath)
    guard !filename.isEmpty, filename != ".", filename != "..",
          filename.rangeOfCharacter(from: CharacterSet(charactersIn: "/\0\r\n")) == nil else {
      throw SFTPError.invalidPath(filename)
    }
    let finalLocalURL = localDirectoryURL.appendingPathComponent(filename)

    if !overwrite && FileManager.default.fileExists(atPath: finalLocalURL.path) {
      throw SFTPError.collision(finalLocalURL.path)
    }

    let tempLocalURL = localDirectoryURL.appendingPathComponent("\(filename).mrw-part-\(UUID().uuidString)")
    let quotedRemote = Self.quoteForBatch(cleanRemote)
    let quotedTempLocal = Self.quoteForBatch(tempLocalURL.path)

    do {
      let res = try executeBatchCommands([
        "get \(quotedRemote) \(quotedTempLocal)"
      ], timeoutSeconds: 300, progressFile: tempLocalURL,
        onProgress: { onProgress($0, 0) }, isCancelled: isCancelled)

      if res.exitCode != 0 {
        try? FileManager.default.removeItem(at: tempLocalURL)
        let err = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        throw SFTPError.remoteError(err.isEmpty ? "Download failed." : err)
      }

      guard !isCancelled() else { throw SFTPError.cancelled }
      try Self.commitDownloadedFile(tempLocalURL, to: finalLocalURL, overwrite: overwrite)

      let downloadedSize = (try? FileManager.default.attributesOfItem(atPath: finalLocalURL.path)[.size] as? Int64) ?? 0
      onProgress(downloadedSize, downloadedSize)
      return finalLocalURL
    } catch {
      try? FileManager.default.removeItem(at: tempLocalURL)
      throw error
    }
  }
  static func commitDownloadedFile(_ staging: URL, to destination: URL, overwrite: Bool) throws {
    if overwrite {
      if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
      } else {
        try FileManager.default.moveItem(at: staging, to: destination)
      }
      return
    }
    if renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) != 0 {
      let code = errno
      if code == EEXIST { throw SFTPError.collision(destination.path) }
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
  }

}
