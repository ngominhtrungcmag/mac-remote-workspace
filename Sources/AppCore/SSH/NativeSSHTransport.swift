import Darwin
import Foundation

/// Represents the authentication method used by NativeSSHTransport.
public enum NativeSSHAuthentication: Sendable, Equatable {
  /// Use an active ssh-agent specified by the socket URL.
  case agent(socketURL: URL)
  /// Use an identity file (private key).
  case identityFile(URL)
  /// Fetch a password or key passphrase from the macOS Keychain through a
  /// short-lived askpass helper. `service` and `account` are opaque
  /// metadata references — no secret value travels in argv, environment, or
  /// the PTY. Authentication is still limited to one password attempt.
  case keychainAskpass(service: String, account: String, identityFile: URL?)
}

/// Represents the terminal dimensions for PTY allocation.
public struct NativeSSHTerminalSize: Sendable, Equatable {
  public var rows: UInt16
  public var columns: UInt16

  public init(rows: UInt16 = 24, columns: UInt16 = 80) {
    self.rows = max(1, rows)
    self.columns = max(1, columns)
  }
}

/// Target endpoint and configuration for an SSH session.
public struct NativeSSHConfiguration: Sendable, Equatable {
  public let host: String
  public let port: Int
  public let username: String
  public let knownHostsFileURL: URL
  public let authentication: NativeSSHAuthentication
  public let proxyJump: NativeSSHProxyJumpEndpoint?
  public let initialTerminalSize: NativeSSHTerminalSize
  public let termEnvironment: String

  public init(
    host: String,
    port: Int = 22,
    username: String,
    knownHostsFileURL: URL,
    authentication: NativeSSHAuthentication,
    proxyJump: NativeSSHProxyJumpEndpoint? = nil,
    initialTerminalSize: NativeSSHTerminalSize = NativeSSHTerminalSize(),
    termEnvironment: String = "xterm-256color"
  ) {
    self.host = host
    self.port = port
    self.username = username
    self.knownHostsFileURL = knownHostsFileURL
    self.authentication = authentication
    self.proxyJump = proxyJump
    self.initialTerminalSize = initialTerminalSize
    self.termEnvironment = termEnvironment
  }
}

/// A managed local TCP forward owned by one SSH session.
public struct NativeSSHLocalTunnelConfiguration: Sendable, Equatable {
  public let localPort: Int
  public let remoteHost: String
  public let remotePort: Int

  public init(localPort: Int, remoteHost: String, remotePort: Int) {
    self.localPort = localPort
    self.remoteHost = remoteHost
    self.remotePort = remotePort
  }
}

public enum NativeSSHTunnelState: Sendable, Equatable {
  case starting
  case running
  case failed(exitCode: Int32)
  case stopped
}

public struct NativeSSHTunnelSummary: Sendable, Equatable, Identifiable {
  public let id: UUID
  public let configuration: NativeSSHLocalTunnelConfiguration
  public let state: NativeSSHTunnelState
}

/// High-level session lifecycle state.
public enum NativeSSHSessionState: Sendable, Equatable {
  case idle
  case connecting
  case running
  case disconnected(exitCode: Int32?)
  case failed(String)

  /// Backwards-compatible alias for running state.
  public static var connected: NativeSSHSessionState {
    .running
  }
}

/// Errors raised by the NativeSSH subsystem.
public enum NativeSSHError: Error, Equatable, AppCoreLocalizedError {
  case invalidHost(String)
  case invalidPort(Int)
  case invalidUsername(String)
  case missingKnownHostsFile(String)
  case missingIdentityFile(String)
  case missingAgentSocket(String)
  case hostVerificationFailed(details: String)
  case authenticationFailed(details: String)
  case connectionFailed(details: String)
  case systemCallFailed(String, Int32)
  case sessionAlreadyRunning
  case sessionNotRunning
  case ptyClosed
  case operationTimedOut
  case invalidTunnelHost
  case tunnelLimitReached
  case invalidAskpassReference
  case askpassUnavailable

  public func displayDescription(locale: Locale?) -> String? {
    switch self {
    case .invalidHost(let host):
      return AppCoreLocalization.format(
        "Invalid host '%1$@'. Host must be a valid DNS hostname or IPv4/IPv6 address and cannot start with '-'.",
        host, locale: locale)
    case .invalidPort(let port):
      return AppCoreLocalization.format("Invalid port '%1$@'. Port must be between 1 and 65535.", String(port), locale: locale)
    case .invalidUsername(let user):
      return AppCoreLocalization.format(
        "Invalid username '%1$@'. Username cannot be empty, start with '-', or contain control characters.",
        user, locale: locale)
    case .missingKnownHostsFile(let path):
      return AppCoreLocalization.format("Known hosts file does not exist or is not readable: %1$@", path, locale: locale)
    case .missingIdentityFile(let path):
      return AppCoreLocalization.format("Identity file does not exist or is not readable: %1$@", path, locale: locale)
    case .missingAgentSocket(let path):
      return AppCoreLocalization.format("SSH agent socket does not exist: %1$@", path, locale: locale)
    case .hostVerificationFailed(let details):
      return AppCoreLocalization.format("Strict host key verification failed: %1$@", details, locale: locale)
    case .authenticationFailed(let details):
      return AppCoreLocalization.format("SSH authentication failed: %1$@", details, locale: locale)
    case .connectionFailed(let details):
      return AppCoreLocalization.format("SSH connection failed: %1$@", details, locale: locale)
    case .systemCallFailed(let name, let errno):
      return AppCoreLocalization.format("System call '%1$@' failed with errno %2$@.", name, String(errno), locale: locale)
    case .sessionAlreadyRunning:
      return AppCoreLocalization.string("Session is already active.", locale: locale)
    case .sessionNotRunning:
      return AppCoreLocalization.string("Session is not running.", locale: locale)
    case .ptyClosed:
      return AppCoreLocalization.string("PTY descriptor closed.", locale: locale)
    case .operationTimedOut:
      return AppCoreLocalization.string("Operation timed out.", locale: locale)
    case .invalidTunnelHost:
      return AppCoreLocalization.string("Invalid remote tunnel target host.", locale: locale)
    case .tunnelLimitReached:
      return AppCoreLocalization.string("This SSH session already has the maximum number of local tunnels.", locale: locale)
    case .invalidAskpassReference:
      return AppCoreLocalization.string("The Keychain credential reference is invalid.", locale: locale)
    case .askpassUnavailable:
      return AppCoreLocalization.string("The Keychain askpass helper could not be prepared.", locale: locale)
    }
  }
}

/// Native OpenSSH transport session managing process lifecycle, PTY I/O, and strict host isolation.
public final class NativeSSHSession: @unchecked Sendable {
  public let id: UUID
  public let configuration: NativeSSHConfiguration

  private let lock = NSRecursiveLock()
  private var _state: NativeSSHSessionState = .idle
  private var process: Process?
  private var proxyJumpConfigurationFile: NativeSSHProxyJumpConfigurationFile?
  private var askpassHelper: KeychainAskpassHelper?
  private var masterFD: Int32 = -1
  private var readSource: DispatchSourceRead?
  private var tunnels: [UUID: NativeSSHTunnel] = [:]
  private var isClosed = false
  private var terminationStatus: Int32?

  public static let maximumLocalTunnels = 4

  public var onOutput: (@Sendable (Data) -> Void)?
  public var onStateChange: (@Sendable (NativeSSHSessionState) -> Void)?

  public var state: NativeSSHSessionState {
    lock.lock()
    defer { lock.unlock() }
    return _state
  }

  public var localTunnelSummaries: [NativeSSHTunnelSummary] {
    lock.lock()
    defer { lock.unlock() }
    return tunnels.values.map(\.summary).sorted { $0.id.uuidString < $1.id.uuidString }
  }

  public init(id: UUID = UUID(), configuration: NativeSSHConfiguration) {
    self.id = id
    self.configuration = configuration
  }

  deinit {
    close()
  }

  // MARK: - Validation

  public static func validate(configuration: NativeSSHConfiguration) throws {
    // Validate host: disallow untrimmed whitespace, empty, leading '-', control chars (incl NUL), '@', or shell metacharacters
    let rawHost = configuration.host
    guard !rawHost.isEmpty,
          rawHost == rawHost.trimmingCharacters(in: .whitespacesAndNewlines),
          !rawHost.hasPrefix("-") else {
      throw NativeSSHError.invalidHost(rawHost)
    }
    let disallowedHostCharacters = CharacterSet.whitespacesAndNewlines
      .union(.controlCharacters)
      .union(CharacterSet(charactersIn: "\0@\";'`$|&<>{}()[]"))
    guard rawHost.rangeOfCharacter(from: disallowedHostCharacters) == nil else {
      throw NativeSSHError.invalidHost(rawHost)
    }

    // Validate port
    guard configuration.port >= 1 && configuration.port <= 65535 else {
      throw NativeSSHError.invalidPort(configuration.port)
    }

    // Validate username: disallow untrimmed whitespace, empty, leading '-', control chars (incl NUL), '@', or dangerous metacharacters
    let rawUser = configuration.username
    guard !rawUser.isEmpty,
          rawUser == rawUser.trimmingCharacters(in: .whitespacesAndNewlines),
          !rawUser.hasPrefix("-") else {
      throw NativeSSHError.invalidUsername(rawUser)
    }
    let disallowedUserCharacters = CharacterSet.whitespacesAndNewlines
      .union(.controlCharacters)
      .union(CharacterSet(charactersIn: "\0@\";'`$|&<>{}()[]:"))
    guard rawUser.rangeOfCharacter(from: disallowedUserCharacters) == nil else {
      throw NativeSSHError.invalidUsername(rawUser)
    }

    if let proxyJump = configuration.proxyJump {
      try validateProxyJump(proxyJump)
    }

    // Validate known_hosts file
    let knownHostsPath = configuration.knownHostsFileURL.path
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: knownHostsPath, isDirectory: &isDir), !isDir.boolValue else {
      throw NativeSSHError.missingKnownHostsFile(knownHostsPath)
    }

    // Validate authentication prerequisites
    switch configuration.authentication {
    case .agent(let socketURL):
      let socketPath = socketURL.path
      guard FileManager.default.fileExists(atPath: socketPath) else {
        throw NativeSSHError.missingAgentSocket(socketPath)
      }
    case .identityFile(let fileURL):
      let filePath = fileURL.path
      var isFileDir: ObjCBool = false
      guard FileManager.default.fileExists(atPath: filePath, isDirectory: &isFileDir), !isFileDir.boolValue else {
        throw NativeSSHError.missingIdentityFile(filePath)
      }
    case .keychainAskpass(let service, let account, let identityFile):
      guard KeychainAskpassHelper.isValidReference(service: service, account: account) else {
        throw NativeSSHError.invalidAskpassReference
      }
      if let identityFile {
        let filePath = identityFile.path
        var isFileDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: filePath, isDirectory: &isFileDir), !isFileDir.boolValue else {
          throw NativeSSHError.missingIdentityFile(filePath)
        }
      }
    }
  }

  static func validateProxyJump(_ endpoint: NativeSSHProxyJumpEndpoint) throws {
    do {
      try NativeSSHHostTrustService.validateEndpoint(host: endpoint.host, port: endpoint.port)
    } catch SSHHostTrustError.invalidPort(let port) {
      throw NativeSSHError.invalidPort(port)
    } catch {
      throw NativeSSHError.invalidHost(endpoint.host)
    }
    let rawUser = endpoint.username
    guard !rawUser.isEmpty,
          rawUser == rawUser.trimmingCharacters(in: .whitespacesAndNewlines),
          !rawUser.hasPrefix("-") else {
      throw NativeSSHError.invalidUsername(rawUser)
    }
    let disallowedUserCharacters = CharacterSet.whitespacesAndNewlines
      .union(.controlCharacters)
      .union(CharacterSet(charactersIn: "\0@\";'`$|&<>{}()[]:"))
    guard rawUser.rangeOfCharacter(from: disallowedUserCharacters) == nil else {
      throw NativeSSHError.invalidUsername(rawUser)
    }
  }

  // MARK: - Lifecycle

  /// Launch the SSH session using local PTY and system `/usr/bin/ssh`.
  public func start() throws {
    try Self.validate(configuration: configuration)
    let proxyConfigFile = try configuration.proxyJump.map { _ in
      try NativeSSHProxyJumpConfigurationFile.create(for: configuration)
    }

    lock.lock()
    guard _state == .idle, !isClosed else {
      lock.unlock()
      throw NativeSSHError.sessionAlreadyRunning
    }
    _state = .connecting
    lock.unlock()

    var master: Int32 = -1
    var slave: Int32 = -1
    var size = winsize(
      ws_row: configuration.initialTerminalSize.rows,
      ws_col: configuration.initialTerminalSize.columns,
      ws_xpixel: 0,
      ws_ypixel: 0
    )

    guard openpty(&master, &slave, nil, nil, &size) == 0 else {
      let code = errno
      lock.lock()
      _state = .idle
      lock.unlock()
      throw NativeSSHError.systemCallFailed("openpty", code)
    }

    let flags = fcntl(master, F_GETFL)
    guard flags >= 0, fcntl(master, F_SETFL, flags | O_NONBLOCK) == 0 else {
      let code = errno
      Darwin.close(master)
      Darwin.close(slave)
      lock.lock()
      _state = .idle
      lock.unlock()
      throw NativeSSHError.systemCallFailed("fcntl(O_NONBLOCK)", code)
    }

    let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    proc.arguments = Self.buildSSHArguments(
      for: configuration,
      proxyJumpConfigURL: proxyConfigFile?.fileURL,
      jumpAlias: proxyConfigFile?.jumpAlias
    )

    var env: [String: String] = [
      "PATH": "/usr/bin:/bin",
      "LC_ALL": "C",
      "TERM": configuration.termEnvironment,
      "HOME": NSHomeDirectory(),
    ]

    switch configuration.authentication {
    case .agent(let socketURL):
      env["SSH_AUTH_SOCK"] = socketURL.path
    case .identityFile:
      env["SSH_AUTH_SOCK"] = ""
    case .keychainAskpass:
      env["SSH_AUTH_SOCK"] = ""
    }

    // Install the short-lived askpass helper before launching when using a
    // Keychain credential. The helper file contains no secret values.
    var askpassHelper: KeychainAskpassHelper?
      if case .keychainAskpass = configuration.authentication {
      do {
        let helper = try KeychainAskpassHelper.install(for: configuration, isCancelled: { [weak self] in
          guard let self else { return true }
          self.lock.lock()
          defer { self.lock.unlock() }
          return self.isClosed
        })
        askpassHelper = helper
        env.merge(helper.childEnvironment(for: configuration.authentication)) { _, new in new }
      } catch {
        Darwin.close(master)
        Darwin.close(slave)
        lock.lock()
        _state = .idle
        lock.unlock()
        throw NativeSSHError.askpassUnavailable
      }
    }

    proc.environment = env
    proc.standardInput = slaveHandle
    proc.standardOutput = slaveHandle
    proc.standardError = slaveHandle

    proc.terminationHandler = { [weak self] p in
      self?.handleTermination(status: p.terminationStatus)
    }

    // Check if session was closed while configuring
    lock.lock()
    if isClosed {
      lock.unlock()
      Darwin.close(master)
      Darwin.close(slave)
      throw NativeSSHError.sessionNotRunning
    }
    self.process = proc
    self.proxyJumpConfigurationFile = proxyConfigFile
    self.askpassHelper = askpassHelper
    self.masterFD = master
    // Keep launch and reader registration atomic with close().

    do {
      try proc.run()
    } catch {
      Darwin.close(master)
      Darwin.close(slave)
      self.process = nil
      self.proxyJumpConfigurationFile = nil
      if let installedHelper = self.askpassHelper{
        self.askpassHelper = nil
        installedHelper.cleanup()
      }
      self.masterFD = -1
      self._state = .idle
      lock.unlock()
      RedactedLogger.shared.error("ssh", "connect failed \(configuration.host):\(configuration.port)")
      throw NativeSSHError.connectionFailed(details: error.localizedDescription)
    }

    // Close slave handle in parent process; child owns its duplicated descriptor
    Darwin.close(slave)

    var notifyRunning = false
    var stateCallback: (@Sendable (NativeSSHSessionState) -> Void)?
    var killedProcess: Process?
    if isClosed {
      killedProcess = self.process
      self.process = nil
      let fdToClose = self.masterFD
      self.masterFD = -1
      if fdToClose >= 0 {
        Darwin.close(fdToClose)
      }
    } else {
      self._state = .running
      notifyRunning = true
      stateCallback = self.onStateChange
      setupReadSourceLocked(for: master)
    }
    lock.unlock()

    if let procToKill = killedProcess {
      Self.terminateProcess(procToKill)
    }

    if notifyRunning {
      RedactedLogger.shared.info("ssh", "connected \(configuration.host):\(configuration.port)")
      stateCallback?(.running)
    }
  }

  private func setupReadSourceLocked(for fd: Int32) {
    // Called while holding `lock`
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue.global(qos: .userInitiated))
    self.readSource = source

    source.setEventHandler { [weak self] in
      guard let self = self else { return }

      self.lock.lock()
      guard !self.isClosed, self.masterFD == fd else {
        self.lock.unlock()
        return
      }
      self.lock.unlock()

      var shouldCancel = false
      var buffer = [UInt8](repeating: 0, count: 8192)
      let bytesRead = Darwin.read(fd, &buffer, buffer.count)
      if bytesRead > 0 {
        let chunk = Data(buffer.prefix(bytesRead))
        let outputCallback = self.onOutput
        outputCallback?(chunk)
      } else if bytesRead == 0 || errno == EIO {
        self.lock.lock()
        if self.masterFD == fd {
          self.masterFD = -1
        }
        self.lock.unlock()
        shouldCancel = true
      }

      if shouldCancel {
        source.cancel()
      }
    }

    source.setCancelHandler {
      Darwin.close(fd)
    }

    source.resume()
  }

  // MARK: - Interactive I/O

  /// Write interactive bytes into the PTY master descriptor with bounded retry and deadline.
  public func write(data: Data, timeout: TimeInterval = 5.0) throws {
    lock.lock()
    guard (_state == .running || _state == .connecting), masterFD >= 0, !isClosed else {
      lock.unlock()
      throw NativeSSHError.sessionNotRunning
    }
    // Duplicate master descriptor under lock so descriptor lifetime is independent of close().
    let writeFD = Darwin.dup(masterFD)
    lock.unlock()

    guard writeFD >= 0 else {
      throw NativeSSHError.systemCallFailed("dup", errno)
    }
    defer {
      Darwin.close(writeFD)
    }

    let deadline = Date().addingTimeInterval(timeout)

    try data.withUnsafeBytes { rawBuffer in
      guard let base = rawBuffer.baseAddress else { return }
      var offset = 0
      while offset < rawBuffer.count {
        self.lock.lock()
        let isStillRunning = (self._state == .running || self._state == .connecting) && !self.isClosed
        self.lock.unlock()
        guard isStillRunning else {
          throw NativeSSHError.sessionNotRunning
        }

        let count = Darwin.write(writeFD, base.advanced(by: offset), rawBuffer.count - offset)
        if count > 0 {
          offset += count
        } else if errno == EINTR {
          continue
        } else if errno == EAGAIN || errno == EWOULDBLOCK {
          guard Date() < deadline else {
            throw NativeSSHError.operationTimedOut
          }
          usleep(1000) // 1ms
        } else {
          throw NativeSSHError.systemCallFailed("write", errno)
        }
      }
    }
  }

  /// Write UTF-8 string to the terminal.
  public func write(string: String, timeout: TimeInterval = 5.0) throws {
    guard let data = string.data(using: .utf8) else { return }
    try write(data: data, timeout: timeout)
  }

  /// Resize the PTY window and notify the remote terminal via SIGWINCH.
  public func resize(rows: UInt16, columns: UInt16) throws {
    lock.lock()
    guard masterFD >= 0, let proc = process, proc.isRunning, !isClosed else {
      lock.unlock()
      throw NativeSSHError.sessionNotRunning
    }
    let resizeFD = Darwin.dup(masterFD)
    let pid = proc.processIdentifier
    lock.unlock()

    guard resizeFD >= 0 else {
      throw NativeSSHError.systemCallFailed("dup", errno)
    }
    defer {
      Darwin.close(resizeFD)
    }

    lock.lock()
    let valid = !isClosed
    lock.unlock()
    guard valid else {
      throw NativeSSHError.sessionNotRunning
    }

    var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
    guard ioctl(resizeFD, TIOCSWINSZ, &size) == 0 else {
      throw NativeSSHError.systemCallFailed("ioctl(TIOCSWINSZ)", errno)
    }
    guard kill(pid, SIGWINCH) == 0 else {
      throw NativeSSHError.systemCallFailed("kill(SIGWINCH)", errno)
    }
  }

  /// Start a local forward using a separate strict OpenSSH process tied to this SSH session.
  public func startLocalTunnel(
    configuration tunnelConfiguration: NativeSSHLocalTunnelConfiguration,
    onStateChange: (@Sendable (NativeSSHTunnelState) -> Void)? = nil
  ) throws -> NativeSSHTunnel {
    try Self.validate(localTunnel: tunnelConfiguration)

    lock.lock()
    guard _state == .running, !isClosed else {
      lock.unlock()
      throw NativeSSHError.sessionNotRunning
    }
    let activeTunnelCount = tunnels.values.reduce(into: 0) { count, tunnel in
      if tunnel.state == .starting || tunnel.state == .running {
        count += 1
      }
    }
    guard activeTunnelCount < Self.maximumLocalTunnels else {
      lock.unlock()
      throw NativeSSHError.tunnelLimitReached
    }

    let tunnel = NativeSSHTunnel(
      sshConfiguration: configuration,
      proxyJumpConfigurationFile: proxyJumpConfigurationFile,
      tunnelConfiguration: tunnelConfiguration,
      onStateChange: onStateChange
    )
    tunnels[tunnel.id] = tunnel
    lock.unlock()

    do {
      try tunnel.start()
      return tunnel
    } catch {
      lock.lock()
      tunnels.removeValue(forKey: tunnel.id)
      lock.unlock()
      throw error
    }
  }

  /// Stop and forget one tunnel. Returns false when the tunnel is already absent.
  @discardableResult
  public func stopLocalTunnel(id: UUID) -> Bool {
    lock.lock()
    let tunnel = tunnels.removeValue(forKey: id)
    lock.unlock()

    guard let tunnel else { return false }
    tunnel.stop()
    return true
  }

  /// Close and cleanup the session gracefully and terminate process if active.
  public func close() {
    lock.lock()
    guard !isClosed else {
      lock.unlock()
      return
    }
    isClosed = true
    let proc = process
    process = nil
    let proxyConfigFile = proxyJumpConfigurationFile
    proxyJumpConfigurationFile = nil
    let askpassCleanup = askpassHelper
    askpassHelper = nil

    let activeTunnels = Array(tunnels.values)
    tunnels.removeAll()

    let readSrc = readSource
    readSource = nil

    let fdToCloseDirectly: Int32
    if readSrc == nil && masterFD >= 0 {
      fdToCloseDirectly = masterFD
    } else {
      fdToCloseDirectly = -1
    }
    masterFD = -1

    let priorState = _state
    let termStatus = terminationStatus
    _state = .disconnected(exitCode: termStatus)
    let stateCallback = self.onStateChange
    lock.unlock()

    if let readSrc = readSrc {
      readSrc.cancel() // readSrc cancelHandler will close fd exactly once
    } else if fdToCloseDirectly >= 0 {
      Darwin.close(fdToCloseDirectly)
    }

    activeTunnels.forEach { $0.stop() }

    if let proc = proc {
      Self.terminateProcess(proc)
    }
    if let askpassCleanup { askpassCleanup.cleanup() }
    withExtendedLifetime(proxyConfigFile) {}

    if case .disconnected = priorState {
      // already informed if prior state was disconnected
    } else {
      let finalExitCode = termStatus ?? proc?.terminationStatus
      stateCallback?(.disconnected(exitCode: finalExitCode))
    }
  }

  private func handleTermination(status: Int32) {
    lock.lock()
    self.terminationStatus = status
    let hasReader = readSource != nil
    lock.unlock()

    // Drain the PTY to EOF (bounded) so final ssh error lines are not lost; the reader
    // clears masterFD on EOF/EIO.
    if hasReader {
      let deadline = Date().addingTimeInterval(0.5)
      while Date() < deadline {
        lock.lock()
        let drained = masterFD < 0 || isClosed
        lock.unlock()
        if drained { break }
        usleep(10_000)
      }
    }

    lock.lock()
    guard !isClosed else {
      lock.unlock()
      return
    }
    _state = .disconnected(exitCode: status)
    RedactedLogger.shared.info("ssh", "closed \(configuration.host):\(configuration.port) exit=\(status)")
    let callback = self.onStateChange
    let proxyConfigFile = proxyJumpConfigurationFile
    proxyJumpConfigurationFile = nil
    let askpassCleanup = askpassHelper
    askpassHelper = nil

    let activeTunnels = Array(tunnels.values)
    tunnels.removeAll()

    let readSrc = readSource
    readSource = nil

    let fdToCloseDirectly: Int32
    if readSrc == nil && masterFD >= 0 {
      fdToCloseDirectly = masterFD
    } else {
      fdToCloseDirectly = -1
    }
    masterFD = -1
    lock.unlock()

    if let readSrc = readSrc {
      readSrc.cancel()
    } else if fdToCloseDirectly >= 0 {
      Darwin.close(fdToCloseDirectly)
    }

    activeTunnels.forEach { $0.stop() }

    callback?(.disconnected(exitCode: status))
    if let askpassCleanup { askpassCleanup.cleanup() }
    withExtendedLifetime(proxyConfigFile) {}
  }

  fileprivate static func terminateProcess(_ proc: Process) {
    guard proc.isRunning else {
      proc.waitUntilExit()
      return
    }
    proc.terminate()
    let deadline = Date().addingTimeInterval(0.5)
    while proc.isRunning && Date() < deadline {
      usleep(10000) // 10ms
    }
    if proc.isRunning {
      _ = kill(proc.processIdentifier, SIGKILL)
    }
    proc.waitUntilExit()
  }

  // MARK: - Command Line Argument Construction (Strict Security)

  /// Builds command line options enforcing strict security:
  /// - StrictHostKeyChecking=yes
  /// - GlobalKnownHostsFile=/dev/null
  /// - UserKnownHostsFile=<explicit known_hosts>
  /// - UpdateHostKeys=no
  /// - CheckHostIP=no
  /// - BatchMode=yes
  /// - No password / keyboard-interactive fallback
  /// - Explicit host / port
  public static func buildSSHArguments(for config: NativeSSHConfiguration) -> [String] {
    precondition(config.proxyJump == nil, "ProxyJump sessions require their private generated SSH config.")
    return buildSSHArguments(for: config, proxyJumpConfigURL: nil, jumpAlias: nil)
  }

  static func buildSSHArguments(
    for config: NativeSSHConfiguration,
    proxyJumpConfigURL: URL?,
    jumpAlias: String?
  ) -> [String] {
    var args = strictSSHArguments(
      for: config,
      allocateTerminal: true,
      clearAllForwardings: true,
      proxyJumpConfigURL: proxyJumpConfigURL,
      jumpAlias: jumpAlias
    )
    args.append("\(config.username)@\(config.host)")
    return args
  }

  public static func validate(localTunnel: NativeSSHLocalTunnelConfiguration) throws {
    guard (1...65535).contains(localTunnel.localPort) else {
      throw NativeSSHError.invalidPort(localTunnel.localPort)
    }
    guard (1...65535).contains(localTunnel.remotePort) else {
      throw NativeSSHError.invalidPort(localTunnel.remotePort)
    }
    guard isValidTunnelTargetHost(localTunnel.remoteHost) else {
      throw NativeSSHError.invalidTunnelHost
    }
  }

  public static func buildLocalTunnelSSHArguments(
    configuration config: NativeSSHConfiguration,
    localTunnel: NativeSSHLocalTunnelConfiguration
  ) -> [String] {
    precondition(config.proxyJump == nil, "ProxyJump tunnels require their session's private generated SSH config.")
    return buildLocalTunnelSSHArguments(
      configuration: config,
      localTunnel: localTunnel,
      proxyJumpConfigURL: nil,
      jumpAlias: nil
    )
  }

  static func buildLocalTunnelSSHArguments(
    configuration config: NativeSSHConfiguration,
    localTunnel: NativeSSHLocalTunnelConfiguration,
    proxyJumpConfigURL: URL?,
    jumpAlias: String?
  ) -> [String] {
    var args = strictSSHArguments(
      for: config,
      allocateTerminal: false,
      clearAllForwardings: false,
      proxyJumpConfigURL: proxyJumpConfigURL,
      jumpAlias: jumpAlias
    )
    args.append(contentsOf: [
      "-N",
      "-o", "ExitOnForwardFailure=yes",
      "-L", localForwardArgument(localTunnel),
      "\(config.username)@\(config.host)",
    ])
    return args
  }

  /// Arguments for one fixed, non-interactive, read-only metrics command (FR-023).
  /// Same strict trust policy as sessions; no PTY, no forwardings. ProxyJump is unsupported.
  static func buildMetricsSSHArguments(for config: NativeSSHConfiguration) -> [String] {
    precondition(config.proxyJump == nil, "Metrics do not support ProxyJump.")
    var args = strictSSHArguments(
      for: config, allocateTerminal: false, clearAllForwardings: true,
      proxyJumpConfigURL: nil, jumpAlias: nil)
    args.append(contentsOf: ["\(config.username)@\(config.host)", RemoteHostMetricsParser.command])
    return args
  }

  private static func strictSSHArguments(
    for config: NativeSSHConfiguration,
    allocateTerminal: Bool,
    clearAllForwardings: Bool,
    proxyJumpConfigURL: URL?,
    jumpAlias: String?
  ) -> [String] {
    let hasProxyJumpConfig = proxyJumpConfigURL != nil && jumpAlias != nil
    precondition((proxyJumpConfigURL == nil) == (jumpAlias == nil), "ProxyJump config URL and alias must be supplied together.")
    precondition((config.proxyJump != nil) == hasProxyJumpConfig, "ProxyJump must use its private generated SSH config.")

    let usesAskpassCredential: Bool
    if case .keychainAskpass = config.authentication {
      usesAskpassCredential = true
    } else {
      usesAskpassCredential = false
    }

    var args = [allocateTerminal ? "-tt" : "-T"]
    if let proxyJumpConfigURL, let jumpAlias {
      args.append(contentsOf: ["-F", proxyJumpConfigURL.path, "-J", jumpAlias])
    } else {
      args.append(contentsOf: ["-F", "/dev/null"])
    }
    args.append(contentsOf: [
      "-p", String(config.port),
    ])
    if !usesAskpassCredential {
      // BatchMode suppresses all interaction; keep it only for agent/identity auth.
      args.append(contentsOf: ["-o", "BatchMode=yes"])
    }
    args.append(contentsOf: [
      "-o", "StrictHostKeyChecking=yes",
      "-o", "UserKnownHostsFile=\(config.knownHostsFileURL.path)",
      "-o", "GlobalKnownHostsFile=/dev/null",
      "-o", "UpdateHostKeys=no",
      "-o", "CheckHostIP=no",
      "-o", "ConnectTimeout=10",
      "-o", "ServerAliveInterval=30",
      "-o", "ServerAliveCountMax=3",
      "-o", "EscapeChar=none",
      "-o", "ForwardAgent=no",
      "-o", "ForwardX11=no",
    ])

    if clearAllForwardings {
      args.append(contentsOf: ["-o", "ClearAllForwardings=yes"])
    }

    switch config.authentication {
    case .agent(let socketURL):
      args.append(contentsOf: [
        "-o", "PasswordAuthentication=no",
        "-o", "KbdInteractiveAuthentication=no",
        "-o", "PreferredAuthentications=publickey",
        "-o", "IdentityFile=none",
        "-o", "IdentitiesOnly=no",
        "-o", "IdentityAgent=\(socketURL.path)",
      ])
    case .identityFile(let fileURL):
      args.append(contentsOf: [
        "-o", "PasswordAuthentication=no",
        "-o", "KbdInteractiveAuthentication=no",
        "-o", "PreferredAuthentications=publickey",
        "-i", fileURL.path,
        "-o", "IdentitiesOnly=yes",
        "-o", "IdentityAgent=none",
      ])
    case .keychainAskpass:
      // Credential-based authentication: one prompt attempt, delivered only
      // through the askpass helper (never argv, never the PTY).
      args.append(contentsOf: [
        "-o", "PasswordAuthentication=yes",
        "-o", "KbdInteractiveAuthentication=yes",
        "-o", "PreferredAuthentications=publickey,password,keyboard-interactive",
        "-o", "NumberOfPasswordPrompts=1",
      ])
      if case .keychainAskpass(_, _, let identityFile) = config.authentication, let identityFile {
        args.append(contentsOf: [
          "-i", identityFile.path,
          "-o", "IdentitiesOnly=yes",
          "-o", "IdentityAgent=none",
        ])
      } else {
        args.append(contentsOf: [
          "-o", "IdentityFile=none",
          "-o", "IdentitiesOnly=no",
          "-o", "IdentityAgent=none",
        ])
      }
    }

    return args
  }

  private static func localForwardArgument(_ configuration: NativeSSHLocalTunnelConfiguration) -> String {
    let remoteHost = configuration.remoteHost.contains(":")
      ? "[\(configuration.remoteHost)]"
      : configuration.remoteHost
    return "127.0.0.1:\(configuration.localPort):\(remoteHost):\(configuration.remotePort)"
  }

  private static func isValidTunnelTargetHost(_ host: String) -> Bool {
    guard !host.isEmpty,
          host.utf8.count <= 253,
          host == host.trimmingCharacters(in: .whitespacesAndNewlines),
          !host.hasPrefix("-") else {
      return false
    }

    let forbidden = CharacterSet.whitespacesAndNewlines
      .union(.controlCharacters)
      .union(CharacterSet(charactersIn: "\0@\";'`$|&<>{}()[]"))
    guard host.rangeOfCharacter(from: forbidden) == nil else { return false }

    if host.contains(":") {
      var address = in6_addr()
      return host.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
    }

    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard !labels.isEmpty, labels.count <= 127 else { return false }
    return labels.allSatisfy { label in
      guard !label.isEmpty, label.count <= 63,
            label.first?.isASCIIAlphanumeric == true,
            label.last?.isASCIIAlphanumeric == true else {
        return false
      }
      return label.allSatisfy { $0.isASCIIAlphanumeric || $0 == "-" }
    }
  }
}

/// Owns the OpenSSH process and loopback listener for one local tunnel.
public final class NativeSSHTunnel: @unchecked Sendable {
  public let id = UUID()
  public let configuration: NativeSSHLocalTunnelConfiguration

  private let sshConfiguration: NativeSSHConfiguration
  private let proxyJumpConfigurationFile: NativeSSHProxyJumpConfigurationFile?
  private let lock = NSLock()
  private var _state: NativeSSHTunnelState = .starting
  private var process: Process?
  private var isStopping = false
  private var askpassHelper: KeychainAskpassHelper?
  private let stateCallback: (@Sendable (NativeSSHTunnelState) -> Void)?

  public var state: NativeSSHTunnelState {
    lock.lock()
    defer { lock.unlock() }
    return _state
  }

  public var summary: NativeSSHTunnelSummary {
    lock.lock()
    defer { lock.unlock() }
    return NativeSSHTunnelSummary(id: id, configuration: configuration, state: _state)
  }

  fileprivate init(
    sshConfiguration: NativeSSHConfiguration,
    proxyJumpConfigurationFile: NativeSSHProxyJumpConfigurationFile?,
    tunnelConfiguration: NativeSSHLocalTunnelConfiguration,
    onStateChange: (@Sendable (NativeSSHTunnelState) -> Void)?
  ) {
    self.sshConfiguration = sshConfiguration
    self.proxyJumpConfigurationFile = proxyJumpConfigurationFile
    self.configuration = tunnelConfiguration
    self.stateCallback = onStateChange
  }

  deinit {
    stop()
  }

  fileprivate func start() throws {
    let tunnelProcess = Process()
    tunnelProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    tunnelProcess.arguments = NativeSSHSession.buildLocalTunnelSSHArguments(
      configuration: sshConfiguration,
      localTunnel: configuration,
      proxyJumpConfigURL: proxyJumpConfigurationFile?.fileURL,
      jumpAlias: proxyJumpConfigurationFile?.jumpAlias
    )
    tunnelProcess.environment = [
      "PATH": "/usr/bin:/bin",
      "LC_ALL": "C",
      "HOME": NSHomeDirectory(),
    ]
    switch sshConfiguration.authentication {
    case .agent(let socketURL):
      tunnelProcess.environment?["SSH_AUTH_SOCK"] = socketURL.path
    case .identityFile:
      tunnelProcess.environment?["SSH_AUTH_SOCK"] = ""
    case .keychainAskpass:
      // Tunnels reuse the owner session's strict configuration; the askpass
      // helper is inherited because forwarding uses no terminal prompts and
      // any credential error fails the tunnel child immediately.
      let helper = try KeychainAskpassHelper.install(for: sshConfiguration)
      askpassHelper = helper
      for (key, value) in helper.childEnvironment(for: sshConfiguration.authentication) {
        tunnelProcess.environment?[key] = value
      }
      tunnelProcess.environment?["SSH_ASKPASS_REQUIRE"] = "force"
    }
    tunnelProcess.standardInput = FileHandle.nullDevice
    tunnelProcess.standardOutput = FileHandle.nullDevice
    tunnelProcess.standardError = FileHandle.nullDevice
    tunnelProcess.terminationHandler = { [weak self] process in
      self?.handleTermination(status: process.terminationStatus)
    }

    lock.lock()
    guard _state == .starting, !isStopping else {
      lock.unlock()
      throw NativeSSHError.sessionNotRunning
    }
    process = tunnelProcess
    do {
      try tunnelProcess.run()
    } catch {
      process = nil
      _state = .failed(exitCode: -1)
      lock.unlock()
      throw NativeSSHError.connectionFailed(details: error.localizedDescription)
    }
    _state = .running
    lock.unlock()
    stateCallback?(.running)
  }

  public func stop() {
    lock.lock()
    guard _state != .stopped, !isStopping else {
      lock.unlock()
      return
    }
    isStopping = true
    let tunnelProcess = process
    process = nil
    let helperCleanup = askpassHelper
    askpassHelper = nil
    lock.unlock()

    if let tunnelProcess {
      NativeSSHSession.terminateProcess(tunnelProcess)
    }
    if let helperCleanup { helperCleanup.cleanup() }

    lock.lock()
    _state = .stopped
    isStopping = false
    lock.unlock()
    stateCallback?(.stopped)
  }

  private func handleTermination(status: Int32) {
    lock.lock()
    guard !isStopping, _state != .stopped else {
      lock.unlock()
      return
    }
    process = nil
    let helperCleanup = askpassHelper
    askpassHelper = nil
    let finalState: NativeSSHTunnelState = status == 0 ? .stopped : .failed(exitCode: status)
    _state = finalState
    lock.unlock()
    if let helperCleanup { helperCleanup.cleanup() }
    stateCallback?(finalState)
  }
}

private extension Character {
  var isASCIIAlphanumeric: Bool {
    isASCII && (isLetter || isNumber)
  }
}

/// Delivers a Keychain secret once through a private FIFO, never through argv or environment.
public final class KeychainAskpassHelper: @unchecked Sendable {
  static let scriptContents = """
    #!/bin/sh
    exec /bin/cat "$MRW_ASKPASS_FIFO"
    """

  private let directoryURL: URL
  private let scriptURL: URL
  private let fifoURL: URL
  private let lock = NSLock()
  private var cancelled = false

  static func isValidReference(service: String, account: String) -> Bool {
    KeychainCredentialReference.isValid(service: service, account: account)
  }

  static func install(
    for configuration: NativeSSHConfiguration,
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) throws -> KeychainAskpassHelper {
    guard case .keychainAskpass(let service, let account, _) = configuration.authentication,
      configuration.proxyJump == nil else { throw NativeSSHError.askpassUnavailable }
    guard !isCancelled() else { throw NativeSSHError.sessionNotRunning }
    let trust = NativeSSHHostTrustService(knownHostsFileURL: configuration.knownHostsFileURL)
    guard case .trusted = try trust.evaluateEndpoint(host: configuration.host, port: configuration.port, isCancelled: isCancelled),
      !isCancelled() else {
      throw NativeSSHError.hostVerificationFailed(details: "Host key is not trusted.")
    }
    return try install {
      guard !isCancelled() else { throw NativeSSHError.sessionNotRunning }
      return try KeychainCredentialStore().read(.init(service: service, account: account))
    }
  }

  static func install(secret: ProtectedSecret) throws -> KeychainAskpassHelper {
    try install { secret }
  }

  static func install(readSecret: @escaping @Sendable () throws -> ProtectedSecret) throws -> KeychainAskpassHelper {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("mrw-askpass-\(UUID().uuidString)", isDirectory: true)
    guard mkdir(directory.path, 0o700) == 0 else { throw NativeSSHError.askpassUnavailable }
    let script = directory.appendingPathComponent("mrw-askpass.sh")
    let fifo = directory.appendingPathComponent("secret.fifo")
    do {
      guard mkfifo(fifo.path, 0o600) == 0 else { throw NativeSSHError.askpassUnavailable }
      let fd = open(script.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o700)
      guard fd >= 0 else { throw NativeSSHError.askpassUnavailable }
      let bytes = Array(scriptContents.utf8)
      var offset = 0
      while offset < bytes.count {
        let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { break }
        offset += n
      }
      Darwin.close(fd)
      guard offset == bytes.count else { throw NativeSSHError.askpassUnavailable }
      let helper = KeychainAskpassHelper(directory: directory, script: script, fifo: fifo)
      DispatchQueue.global(qos: .userInitiated).async { helper.deliver(readSecret: readSecret) }
      return helper
    } catch {
      _ = unlink(script.path)
      _ = unlink(fifo.path)
      _ = rmdir(directory.path)
      throw error
    }
  }

  private init(directory: URL, script: URL, fifo: URL) {
    directoryURL = directory
    scriptURL = script
    fifoURL = fifo
  }

  private func deliver(readSecret: @escaping @Sendable () throws -> ProtectedSecret) {
    defer { _ = unlink(fifoURL.path) }
    // ssh opens the FIFO only after connect + key exchange (ConnectTimeout=10), so the wait for the reader
    // gets its own window; the write deadline starts when the reader actually opens. Still one-shot.
    let openDeadline = DispatchTime.now().uptimeNanoseconds + 60_000_000_000
    var deadline = openDeadline
    while DispatchTime.now().uptimeNanoseconds < openDeadline {
      lock.lock()
      let shouldStop = cancelled
      lock.unlock()
      if shouldStop { return }
      let fd = open(fifoURL.path, O_WRONLY | O_NONBLOCK | O_NOFOLLOW)
      if fd >= 0 {
        defer { Darwin.close(fd) }
        deadline = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
        guard fcntl(fd, F_SETNOSIGPIPE, 1) != -1 else { return }
        lock.lock()
        let shouldStop = cancelled
        lock.unlock()
        guard !shouldStop, let secret = try? readSecret() else { return }
        var bytes = secret.withBytes { $0 } ?? []
        defer { for index in bytes.indices { bytes[index] = 0 } }
        var offset = 0
        while offset < bytes.count {
          lock.lock()
          let shouldStop = cancelled
          lock.unlock()
          if shouldStop || DispatchTime.now().uptimeNanoseconds >= deadline { return }
          let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
          if n > 0 { offset += n }
          else if n < 0 && (errno == EINTR || errno == EAGAIN) { usleep(20_000) }
          else { return }
        }
        return
      }
      if errno != ENXIO && errno != EINTR { return }
      usleep(20_000)
    }
  }

  func childEnvironment(for authentication: NativeSSHAuthentication) -> [String: String] {
    guard case .keychainAskpass = authentication else { return [:] }
    return ["SSH_ASKPASS": scriptURL.path, "SSH_ASKPASS_REQUIRE": "force", "MRW_ASKPASS_FIFO": fifoURL.path]
  }

  public func cleanup() {
    lock.lock()
    cancelled = true
    _ = unlink(fifoURL.path)
    _ = unlink(scriptURL.path)
    _ = rmdir(directoryURL.path)
    lock.unlock()
  }

  deinit { cleanup() }
}
