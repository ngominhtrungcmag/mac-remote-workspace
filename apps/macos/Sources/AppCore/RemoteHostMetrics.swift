import Darwin
import Dispatch
import Foundation

/// Read-only host metrics (FR-023 / US-023). Fixed command, no user-supplied input.
public struct RemoteHostMetrics: Sendable, Equatable {
  public let operatingSystem: String
  public let load1: Double
  public let load5: Double
  public let load15: Double
  public let memoryTotalBytes: UInt64
  public let memoryAvailableBytes: UInt64
  public let diskTotalBytes: UInt64
  public let diskUsedBytes: UInt64
  public let uptimeSeconds: UInt64

  public var memoryUsedFraction: Double {
    memoryTotalBytes == 0 ? 0 : 1 - Double(min(memoryAvailableBytes, memoryTotalBytes)) / Double(memoryTotalBytes)
  }
  public var diskUsedFraction: Double {
    diskTotalBytes == 0 ? 0 : Double(min(diskUsedBytes, diskTotalBytes)) / Double(diskTotalBytes)
  }
}

public enum RemoteHostMetricsError: Error, Equatable, AppCoreLocalizedError {
  case unsupportedOperatingSystem(String)
  case malformedOutput(String)
  case commandFailed(String)
  case cancelled

  public func displayDescription(locale: Locale?) -> String? {
    switch self {
    case .unsupportedOperatingSystem(let os):
      AppCoreLocalization.format("Metrics are supported on Linux and macOS hosts only (found '%1$@').", os, locale: locale)
    case .malformedOutput(let what):
      AppCoreLocalization.format("Unexpected metrics output: %1$@.", what, locale: locale)
    case .commandFailed(let details):
      AppCoreLocalization.format("Metrics command failed: %1$@", details, locale: locale)
    case .cancelled:
      AppCoreLocalization.string("Metrics request cancelled.", locale: locale)
    }
  }
}

public enum RemoteHostMetricsParser {
  /// Fixed script run via `/bin/sh -c`. Contains no single quotes (it is single-quoted below)
  /// and no interpolated values. Every command is read-only.
  public static let command: String = {
    let script = [
      "OS=$(uname -s); echo \"OS=$OS\";",
      "case \"$OS\" in",
      "Linux) echo \"LOAD=$(cut -d\" \" -f1-3 /proc/loadavg)\"; echo \"UPTIME=$(cut -d\" \" -f1 /proc/uptime)\";",
      "grep -E \"^(MemTotal|MemAvailable):\" /proc/meminfo;;",
      "Darwin) echo \"LOAD=$(sysctl -n vm.loadavg | tr -d \"{}\")\";",
      "echo \"UPTIME=$(( $(date +%s) - $(sysctl -n kern.boottime | sed \"s/.*sec = \\([0-9]*\\).*/\\1/\") ))\";",
      "echo \"MEMTOTAL=$(sysctl -n hw.memsize)\"; vm_stat;;",
      "esac; echo \"DF=$(df -Pk / | tail -n 1)\"",
    ].joined(separator: " ")
    return "/bin/sh -c '\(script)'"
  }()

  public static func parse(_ output: String) throws -> RemoteHostMetrics {
    var os: String?
    var load: [Double] = []
    var uptime: UInt64?
    var memTotal: UInt64?
    var memAvailable: UInt64?
    var df: [Substring] = []
    var pageSize: UInt64 = 4096
    var pages: [String: UInt64] = [:]

    for rawLine in output.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if let v = value(line, "OS=") {
        os = v
      } else if let v = value(line, "LOAD=") {
        load = v.split(separator: " ").compactMap { Double($0) }
      } else if let v = value(line, "UPTIME=") {
        uptime = Double(v).flatMap { $0 >= 0 && $0 < 1e12 ? UInt64($0) : nil }
      } else if let v = value(line, "MEMTOTAL=") {
        memTotal = UInt64(v)
      } else if let v = value(line, "DF=") {
        df = v.split(separator: " ", omittingEmptySubsequences: true)
      } else if line.hasPrefix("MemTotal:") {
        memTotal = kib(line)
      } else if line.hasPrefix("MemAvailable:") {
        memAvailable = kib(line)
      } else if line.hasPrefix("Mach Virtual Memory Statistics"),
        let r = line.range(of: "page size of "),
        let n = UInt64(line[r.upperBound...].prefix(while: \.isNumber)), n > 0
      {
        pageSize = n
      } else if line.hasPrefix("Pages "), let colon = line.firstIndex(of: ":"),
        let n = UInt64(line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " .")))
      {
        pages[String(line[..<colon])] = n
      }
    }

    guard let os else { throw RemoteHostMetricsError.malformedOutput("missing OS") }
    guard os == "Linux" || os == "Darwin" else {
      throw RemoteHostMetricsError.unsupportedOperatingSystem(String(os.prefix(32)))
    }
    guard load.count == 3, load.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
      throw RemoteHostMetricsError.malformedOutput("load average")
    }
    guard let uptime else { throw RemoteHostMetricsError.malformedOutput("uptime") }
    guard let memTotal, memTotal > 0 else { throw RemoteHostMetricsError.malformedOutput("memory total") }
    if os == "Darwin" {
      guard let free = pages["Pages free"] else { throw RemoteHostMetricsError.malformedOutput("vm_stat") }
      let reclaimable = free + (pages["Pages inactive"] ?? 0) + (pages["Pages speculative"] ?? 0)
      let (bytes, overflow) = reclaimable.multipliedReportingOverflow(by: pageSize)
      memAvailable = overflow ? nil : bytes
    }
    guard let memAvailable else { throw RemoteHostMetricsError.malformedOutput("memory available") }
    // POSIX df -Pk: Filesystem 1024-blocks Used Available Capacity Mounted-on
    guard df.count >= 6, let total = UInt64(df[1]), let used = UInt64(df[2]), total > 0, used <= total,
      total <= UInt64.max / 1024
    else { throw RemoteHostMetricsError.malformedOutput("disk usage") }

    return RemoteHostMetrics(
      operatingSystem: os, load1: load[0], load5: load[1], load15: load[2],
      memoryTotalBytes: memTotal, memoryAvailableBytes: min(memAvailable, memTotal),
      diskTotalBytes: total * 1024, diskUsedBytes: used * 1024, uptimeSeconds: uptime)
  }

  private static func value(_ line: String, _ prefix: String) -> String? {
    line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) : nil
  }

  /// "MemTotal:       16384 kB" -> bytes
  private static func kib(_ line: String) -> UInt64? {
    guard let colon = line.firstIndex(of: ":"),
      let n = UInt64(line[line.index(after: colon)...].split(separator: " ").first ?? ""),
      n <= UInt64.max / 1024
    else { return nil }
    return n * 1024
  }
}

/// Runs the fixed metrics command over `/usr/bin/ssh` with the strict trust policy.
public final class NativeSSHMetricsClient: Sendable {
  public static let maximumOutputBytes = 64 * 1024
  public let configuration: NativeSSHConfiguration

  public init(configuration: NativeSSHConfiguration) throws {
    try NativeSSHSession.validate(configuration: configuration)
    guard configuration.proxyJump == nil else {
      throw RemoteHostMetricsError.commandFailed("ProxyJump hosts are not supported for metrics.")
    }
    self.configuration = configuration
  }

  public func fetch(
    timeoutSeconds: TimeInterval = 20,
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) throws -> RemoteHostMetrics {
    let (status, out, err) = try run(
      arguments: NativeSSHSession.buildMetricsSSHArguments(for: configuration),
      timeoutSeconds: timeoutSeconds, isCancelled: isCancelled)
    guard status == 0 else { throw Self.classify(stderr: err, status: status) }
    return try RemoteHostMetricsParser.parse(out)
  }

  /// Host-key failures are surfaced as trust failures; nothing is parsed or retried.
  static func classify(stderr: String, status: Int32) -> Error {
    let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    let bounded = String(text.suffix(300))
    if text.contains("Host key verification failed") || text.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
      return NativeSSHError.hostVerificationFailed(details: bounded)
    }
    if text.contains("Permission denied") { return NativeSSHError.authenticationFailed(details: bounded) }
    return RemoteHostMetricsError.commandFailed(bounded.isEmpty ? "exit status \(status)" : bounded)
  }

  private final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
      lock.lock()
      defer { lock.unlock() }
      if data.count < NativeSSHMetricsClient.maximumOutputBytes {
        data.append(chunk.prefix(NativeSSHMetricsClient.maximumOutputBytes - data.count))
      }
    }
    var text: String {
      lock.lock()
      defer { lock.unlock() }
      return String(decoding: data, as: UTF8.self)
    }
  }

  private func run(
    arguments: [String], timeoutSeconds: TimeInterval, isCancelled: @escaping @Sendable () -> Bool
  ) throws -> (Int32, String, String) {
    guard !isCancelled() else { throw RemoteHostMetricsError.cancelled }

    var env: [String: String] = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "HOME": NSHomeDirectory()]
    var helper: KeychainAskpassHelper?
    switch configuration.authentication {
    case .agent(let socketURL):
      env["SSH_AUTH_SOCK"] = socketURL.path
    case .identityFile:
      env["SSH_AUTH_SOCK"] = ""
    case .keychainAskpass:
      env["SSH_AUTH_SOCK"] = ""
      guard let installed = try? KeychainAskpassHelper.install(for: configuration, isCancelled: isCancelled) else { throw NativeSSHError.askpassUnavailable }
      helper = installed
      env.merge(installed.childEnvironment(for: configuration.authentication)) { _, new in new }
    }
    defer { helper?.cleanup() }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    process.arguments = arguments
    process.environment = env
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = outPipe
    process.standardError = errPipe
    try process.run()

    let out = Sink()
    let err = Sink()
    let group = DispatchGroup()
    for (pipe, sink) in [(outPipe, out), (errPipe, err)] {
      group.enter()
      DispatchQueue.global(qos: .utility).async {
        while true {
          let chunk = pipe.fileHandleForReading.availableData
          if chunk.isEmpty { break }
          sink.append(chunk)
        }
        group.leave()
      }
    }

    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while process.isRunning {
      let cancelled = isCancelled()
      if cancelled || Date() >= deadline {
        process.terminate()
        _ = kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        group.wait()
        throw cancelled ? RemoteHostMetricsError.cancelled : NativeSSHError.operationTimedOut
      }
      usleep(20_000)
    }
    process.waitUntilExit()
    group.wait()
    return (process.terminationStatus, out.text, err.text)
  }
}
