import Darwin
import Foundation

/// One SSH jump endpoint. The same local SSH agent is used for the jump and target.
public struct NativeSSHProxyJumpEndpoint: Sendable, Equatable {
  public let host: String
  public let port: Int
  public let username: String

  public init(host: String, port: Int = 22, username: String) {
    self.host = host
    self.port = port
    self.username = username
  }
}

/// A private, per-session OpenSSH config containing only the approved jump endpoint and strict policy.
final class NativeSSHProxyJumpConfigurationFile: @unchecked Sendable {
  let directoryURL: URL
  let fileURL: URL
  let jumpAlias: String

  private init(directoryURL: URL, fileURL: URL, jumpAlias: String) {
    self.directoryURL = directoryURL
    self.fileURL = fileURL
    self.jumpAlias = jumpAlias
  }

  deinit {
    _ = unlink(fileURL.path)
    _ = rmdir(directoryURL.path)
  }

  static func create(for configuration: NativeSSHConfiguration) throws -> Self {
    guard let jump = configuration.proxyJump else {
      throw NativeSSHError.connectionFailed(details: "ProxyJump endpoint is missing.")
    }
    try NativeSSHSession.validateProxyJump(jump)
    let alias = "_mrw_jump_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
    let contents = try Self.contents(
      jump: jump,
      knownHostsFileURL: configuration.knownHostsFileURL,
      authentication: configuration.authentication,
      alias: alias
    )

    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("mrw-ssh-proxyjump-\(UUID().uuidString)", isDirectory: true)
    guard mkdir(directoryURL.path, 0o700) == 0 else {
      throw NativeSSHError.connectionFailed(details: "Unable to create a private ProxyJump config directory.")
    }

    let fileURL = directoryURL.appendingPathComponent("ssh_config", isDirectory: false)
    do {
      try Self.writePrivateConfig(contents, to: fileURL)
      try Self.validatePrivateDirectory(directoryURL)
      return Self(directoryURL: directoryURL, fileURL: fileURL, jumpAlias: alias)
    } catch {
      _ = unlink(fileURL.path)
      _ = rmdir(directoryURL.path)
      throw error
    }
  }

  static func contents(
    jump: NativeSSHProxyJumpEndpoint,
    knownHostsFileURL: URL,
    authentication: NativeSSHAuthentication,
    alias: String
  ) throws -> String {
    guard case .agent = authentication else {
      throw NativeSSHError.connectionFailed(details: "ProxyJump requires SSH agent authentication.")
    }
    try NativeSSHSession.validateProxyJump(jump)
    guard alias.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil else {
      throw NativeSSHError.connectionFailed(details: "Invalid internal ProxyJump alias.")
    }

    let knownHosts = try configValue(knownHostsFileURL.path)
    let host = try configValue(normalizedHost(jump.host))
    let username = try configValue(jump.username)

    var usesAskpassCredential = false
    if case .keychainAskpass = authentication { usesAskpassCredential = true }

    var lines = [
      "Host *",
      "  StrictHostKeyChecking yes",
      "  UserKnownHostsFile \(knownHosts)",
      "  GlobalKnownHostsFile /dev/null",
      "  UpdateHostKeys no",
      "  CheckHostIP no",
      "  ConnectTimeout 10",
      "  ForwardAgent no",
      "  ForwardX11 no",
    ]
    if !usesAskpassCredential {
      lines.append("  BatchMode yes")
      lines.append("  PasswordAuthentication no")
      lines.append("  KbdInteractiveAuthentication no")
      lines.append("  PreferredAuthentications publickey")
    } else {
      lines.append("  PasswordAuthentication yes")
      lines.append("  KbdInteractiveAuthentication yes")
      lines.append("  PreferredAuthentications publickey,password,keyboard-interactive")
      lines.append("  NumberOfPasswordPrompts 1")
    }

    switch authentication {
    case .agent(let socketURL):
      lines.append("  IdentityFile none")
      lines.append("  IdentitiesOnly no")
      lines.append("  IdentityAgent \(try configValue(socketURL.path))")
    case .identityFile(let identityURL):
      lines.append("  IdentityFile \(try configValue(identityURL.path))")
      lines.append("  IdentitiesOnly yes")
      lines.append("  IdentityAgent none")
    case .keychainAskpass(_, _, let identityFile):
      if let identityFile {
        lines.append("  IdentityFile \(try configValue(identityFile.path))")
        lines.append("  IdentitiesOnly yes")
      } else {
        lines.append("  IdentityFile none")
        lines.append("  IdentitiesOnly no")
      }
      lines.append("  IdentityAgent none")
    }

    lines.append("Host \(alias)")
    lines.append("  HostName \(host)")
    lines.append("  Port \(jump.port)")
    lines.append("  User \(username)")
    return lines.joined(separator: "\n") + "\n"
  }

  private static func normalizedHost(_ host: String) -> String {
    guard host.hasPrefix("["), host.hasSuffix("]") else { return host }
    return String(host.dropFirst().dropLast())
  }

  private static func configValue(_ value: String) throws -> String {
    guard !value.contains("\0"), !value.contains("\n"), !value.contains("\r") else {
      throw NativeSSHError.connectionFailed(details: "A ProxyJump config value contains an invalid control character.")
    }
    let escaped = value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }

  private static func validatePrivateDirectory(_ directoryURL: URL) throws {
    var info = stat()
    guard lstat(directoryURL.path, &info) == 0,
          (info.st_mode & S_IFMT) == S_IFDIR,
          info.st_uid == geteuid(),
          (info.st_mode & 0o7777) == 0o700 else {
      throw NativeSSHError.connectionFailed(details: "Private ProxyJump config directory failed ownership or permission checks.")
    }
  }

  private static func writePrivateConfig(_ contents: String, to fileURL: URL) throws {
    let descriptor = open(fileURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw NativeSSHError.connectionFailed(details: "Unable to create a private ProxyJump config file.")
    }
    defer { Darwin.close(descriptor) }

    var data = Data(contents.utf8)
    let writeSucceeded = data.withUnsafeMutableBytes { rawBuffer -> Bool in
      guard let baseAddress = rawBuffer.baseAddress else { return true }
      var offset = 0
      while offset < rawBuffer.count {
        let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), rawBuffer.count - offset)
        if count > 0 {
          offset += count
        } else if errno != EINTR {
          return false
        }
      }
      return true
    }
    guard writeSucceeded, fchmod(descriptor, 0o600) == 0, fsync(descriptor) == 0 else {
      throw NativeSSHError.connectionFailed(details: "Unable to write a private ProxyJump config file.")
    }
  }
}

/// Temporarily forwards only the target SSH port through an already-trusted jump.
/// The listener is loopback-only and exists only while the target key is being probed.
public enum NativeSSHProxyJumpProbe {
  /// Inspects a target endpoint through the already-trusted jump without authenticating to target.
  public static func evaluateTargetHost(
    configuration: NativeSSHConfiguration,
    trustService: NativeSSHHostTrustService,
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) throws -> SSHHostTrustStatus {
    guard configuration.proxyJump != nil else {
      throw NativeSSHError.connectionFailed(details: "ProxyJump endpoint is missing.")
    }
    return try withForward(configuration: configuration, isCancelled: isCancelled) { localPort in
      try trustService.evaluateEndpoint(
        host: configuration.host,
        port: configuration.port,
        throughLoopbackPort: localPort,
        isCancelled: isCancelled
      )
    }
  }

  static func withForward<Result>(
    configuration: NativeSSHConfiguration,
    timeoutSeconds: TimeInterval = 12,
    isCancelled: @escaping @Sendable () -> Bool = { false },
    probe: (Int) throws -> Result
  ) throws -> Result {
    guard configuration.proxyJump != nil else {
      throw NativeSSHError.connectionFailed(details: "ProxyJump endpoint is missing.")
    }
    try NativeSSHSession.validate(configuration: configuration)
    let configFile = try NativeSSHProxyJumpConfigurationFile.create(for: configuration)
    let localPort = try availableLoopbackPort()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    process.arguments = [
      "-F", configFile.fileURL.path,
      "-N",
      "-v",
      "-o", "ExitOnForwardFailure=yes",
      "-o", "ControlMaster=no",
      "-o", "ControlPath=none",
      "-L", localForwardSpecification(
        localPort: localPort,
        targetHost: configuration.host,
        targetPort: configuration.port
      ),
      configFile.jumpAlias,
    ]

    var environment = [
      "PATH": "/usr/bin:/bin",
      "LC_ALL": "C",
      "HOME": NSHomeDirectory(),
    ]
    var askpassHelper: KeychainAskpassHelper?
    do {
      switch configuration.authentication {
      case .agent(let socketURL):
        environment["SSH_AUTH_SOCK"] = socketURL.path
      case .identityFile:
        environment["SSH_AUTH_SOCK"] = ""
      case .keychainAskpass:
        environment["SSH_AUTH_SOCK"] = ""
        askpassHelper = try KeychainAskpassHelper.install(for: configuration, isCancelled: isCancelled)
        environment.merge(askpassHelper!.childEnvironment(for: configuration.authentication)) { _, new in new }
      }
    } catch {
      askpassHelper?.cleanup()
      throw error
    }
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice

    let stderrPipe = Pipe()
    let readiness = ForwardReadiness(port: localPort)
    process.standardError = stderrPipe
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      readiness.append(data)
    }
    process.terminationHandler = { _ in readiness.finish() }

    do {
      try process.run()
    } catch {
      stderrPipe.fileHandleForReading.readabilityHandler = nil
      throw NativeSSHError.connectionFailed(details: "Unable to start the SSH jump connection.")
    }

    defer {
      stderrPipe.fileHandleForReading.readabilityHandler = nil
      terminate(process)
      if let askpassHelper { askpassHelper.cleanup() }
      withExtendedLifetime(configFile) {}
    }

    try readiness.wait(
      process: process,
      timeoutSeconds: timeoutSeconds,
      isCancelled: isCancelled
    )
    guard !isCancelled() else {
      throw NativeSSHError.connectionFailed(details: "ProxyJump target key probe was cancelled.")
    }
    return try probe(localPort)
  }

  private static func localForwardSpecification(localPort: Int, targetHost: String, targetPort: Int) -> String {
    let host = targetHost.contains(":") ? "[\(targetHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))]" : targetHost
    return "127.0.0.1:\(localPort):\(host):\(targetPort)"
  }

  private static func availableLoopbackPort() throws -> Int {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw NativeSSHError.connectionFailed(details: "Unable to select a loopback port for the ProxyJump key probe.")
    }
    defer { Darwin.close(descriptor) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    _ = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &address.sin_addr) }

    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else {
      throw NativeSSHError.connectionFailed(details: "Unable to select a loopback port for the ProxyJump key probe.")
    }

    var boundAddress = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(descriptor, $0, &length)
      }
    }
    guard nameResult == 0 else {
      throw NativeSSHError.connectionFailed(details: "Unable to select a loopback port for the ProxyJump key probe.")
    }
    return Int(UInt16(bigEndian: boundAddress.sin_port))
  }

  private static func terminate(_ process: Process) {
    guard process.isRunning else {
      process.waitUntilExit()
      return
    }
    process.terminate()
    let deadline = Date().addingTimeInterval(0.5)
    while process.isRunning && Date() < deadline { usleep(10_000) }
    if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
  }
}

private final class ForwardReadiness: @unchecked Sendable {
  private let condition = NSCondition()
  private let port: Int
  private var output = Data()
  private var isFinished = false

  init(port: Int) {
    self.port = port
  }

  func append(_ data: Data) {
    condition.lock()
    if data.isEmpty {
      isFinished = true
    } else {
      output.append(data)
    }
    condition.broadcast()
    condition.unlock()
  }

  func finish() {
    condition.lock()
    isFinished = true
    condition.broadcast()
    condition.unlock()
  }

  func wait(
    process: Process,
    timeoutSeconds: TimeInterval,
    isCancelled: @Sendable () -> Bool
  ) throws {
    let deadline = Date().addingTimeInterval(timeoutSeconds.isFinite ? max(0.1, timeoutSeconds) : 12)
    let expectedLine = "Local forwarding listening on 127.0.0.1 port \(port)."

    condition.lock()
    defer { condition.unlock() }
    while true {
      let text = String(decoding: output, as: UTF8.self)
      if text.contains(expectedLine) { return }
      if isCancelled() {
        throw NativeSSHError.connectionFailed(details: "ProxyJump target key probe was cancelled.")
      }
      if isFinished || !process.isRunning {
        throw NativeSSHError.connectionFailed(details: "The trusted jump connection could not open its loopback key-probe listener.")
      }
      guard Date() < deadline else {
        throw NativeSSHError.connectionFailed(details: "Timed out while connecting to the trusted jump host.")
      }
      _ = condition.wait(until: min(deadline, Date().addingTimeInterval(0.05)))
    }
  }
}
