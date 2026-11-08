import AppCore
import Combine
import Foundation
import SwiftUI

/// View model managing an interactive native SSH session lifecycle, host trust review, and terminal I/O.
@MainActor
public final class SSHSessionViewModel: ObservableObject {
  enum TrustEndpointRole: Equatable, Sendable {
    case jumpHost
    case targetHost
  }

  public enum SessionStatus: Equatable {
    case idle
    case verifyingHost(host: String, port: Int)
    case hostTrustRequired(challenge: SSHHostTrustChallenge)
    case hostKeyMismatch(recordedKeys: [SSHHostKeyRecord], presentedKey: SSHHostKeyRecord)
    case connecting
    case running
    case disconnected(exitCode: Int32?)
    case failed(String)
  }

  /// Explicit user authentication choice for one connection attempt.
  public enum AuthenticationChoice: Equatable, Sendable {
    /// Use the active ssh-agent (SSH_AUTH_SOCK).
    case sshAgent
    /// Use a Keychain-backed credential for password or key-passphrase auth.
    case keychainCredential(reference: CredentialRefRecord, identityFileURL: URL?)
    /// Enter password directly: optionally saved to Keychain with a label, or session-scoped.
    case password(secret: ProtectedSecret, saveToKeychain: Bool, label: String?)
  }

  @Published public private(set) var status: SessionStatus = .idle
  @Published private(set) var trustEndpointRole: TrustEndpointRole?
  public private(set) var terminalOutput: String = ""
  @Published public var inputBuffer: String = ""
  @Published public private(set) var localTunnels: [NativeSSHTunnelSummary] = []
  @Published public private(set) var tunnelError: String?
  @Published public private(set) var newlySavedCredential: CredentialRefRecord?

  public let host: HostRecord
  var hasProxyJump: Bool { pendingConnectionTarget?.proxyJump != nil }
  private var session: NativeSSHSession?
  /// True while an SSH session (or connection attempt) is live; used by the quit confirmation (FR-028).
  var hasLiveSession: Bool { session != nil || status == .connecting }

  private let sessionCoordinator = NativeSSHSessionCoordinator()
  private var reconnectBackoff = SSHReconnectBackoff(jitter: 0.5)
  private let passwordAuthService: SSHPasswordAuthenticationServiceProtocol
  private final class EphemeralHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var reference: KeychainCredentialReference?

    func set(_ ref: KeychainCredentialReference?) {
      lock.lock()
      defer { lock.unlock() }
      reference = ref
    }

    func take() -> KeychainCredentialReference? {
      lock.lock()
      defer { lock.unlock() }
      let ref = reference
      reference = nil
      return ref
    }
  }
  private let ephemeralHolder = EphemeralHolder()

  // Track active pending trust challenge and target connection parameters
  private var activeChallenge: SSHHostTrustChallenge?
  private var activeChallengeRole: TrustEndpointRole?
  private var pendingConnectionTarget: PendingConnectionTarget?

  private struct PendingConnectionTarget: Sendable {
    let username: String
    let port: Int
    let knownHostsURL: URL
    let authenticationChoice: AuthenticationChoice
    let proxyJump: NativeSSHProxyJumpEndpoint?
  }

  private var outputBuffer = SSHOutputBuffer(capacity: 102400) // 100 KB bounded buffer
  /// Raw bytes for the VT emulator; bounded (1 MiB) while no terminal view is attached.
  private var rawBuffer = SSHOutputBuffer(capacity: 1_048_576)
  /// Set by the terminal view; receives raw PTY bytes on the main actor.
  var terminalFeed: (([UInt8]) -> Void)?
  /// Set by the terminal view; clears the emulator on (re)connect.
  var terminalReset: (() -> Void)?
  private final class DrainTimerHolder: @unchecked Sendable {
    private var timer: Timer?

    func setTimer(_ t: Timer) {
      timer?.invalidate()
      timer = t
    }

    func invalidate() {
      timer?.invalidate()
      timer = nil
    }
  }

  private let drainTimerHolder = DrainTimerHolder()
  private let maxTerminalCharacters: Int = 100_000

  private let ioQueue = DispatchQueue(label: "com.macremoteworkspace.ssh.io", qos: .userInitiated)

  public init(
    host: HostRecord,
    passwordAuthService: SSHPasswordAuthenticationServiceProtocol = SSHPasswordAuthenticationService()
  ) {
    self.host = host
    self.passwordAuthService = passwordAuthService
    startDrainTimer()
    AppLifecycle.shared.register(self)
  }

  deinit {
    drainTimerHolder.invalidate()
    let currentSession = session
    cleanupEphemeralCredential()
    if let currentSession {
      DispatchQueue.global(qos: .utility).async {
        currentSession.close()
      }
    }
  }

  nonisolated private func cleanupEphemeralCredential() {
    guard let ref = ephemeralHolder.take() else { return }
    passwordAuthService.cleanupEphemeralCredential(ref)
  }

  private func startDrainTimer() {
    let t = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.drainOutput()
      }
    }
    drainTimerHolder.setTimer(t)
  }

  private func drainOutput() {
    if let feed = terminalFeed {
      let raw = rawBuffer.drainBytes()
      if !raw.isEmpty { feed([UInt8](raw)) }
    }
    let drained = outputBuffer.drainDecodableString()
    guard !drained.isEmpty else { return }
    appendOutput(drained)
  }

  // MARK: - Safe Connection Workflow (Host Trust First)

  /// Initiates connection by verifying host trust out-of-band before SSH authentication starts.
  public func connect(
    username: String = NSUserName(),
    port: Int = 22,
    knownHostsURL: URL? = nil,
    authentication: AuthenticationChoice = .sshAgent,
    proxyJump: NativeSSHProxyJumpEndpoint? = nil
  ) {
    guard status == .idle || isTerminalState else { return }
    let wait = reconnectBackoff.remaining()
    if wait > 0 {
      status = .failed(AppLocalization.format(
        "Too many failed attempts. Retry in %1$@ seconds.",
        String(Int(wait.rounded(.up)))
      ))
      return
    }

    // Invalidate sessionID at START of connect before closing old session or any prerequisite validation.
    let thisSessionID = sessionCoordinator.reset()
    self.activeChallenge = nil
    self.activeChallengeRole = nil
    self.trustEndpointRole = nil
    self.pendingConnectionTarget = nil
    self.cleanupEphemeralCredential()

    self.outputBuffer = SSHOutputBuffer(capacity: 102400)
    self.rawBuffer = SSHOutputBuffer(capacity: 1_048_576)
    terminalReset?()
    terminalOutput = ""
    inputBuffer = ""
    localTunnels = []
    tunnelError = nil

    // Close any previous session safely off main thread
    if let oldSession = self.session {
      self.session = nil
      DispatchQueue.global(qos: .utility).async {
        oldSession.close()
      }
    }

    if proxyJump != nil {
      guard case .sshAgent = authentication else {
        status = .failed(AppLocalization.string("ProxyJump requires SSH agent authentication."))
        return
      }
    }

    let hostsURL = knownHostsURL ?? NativeSSHHostTrustService.defaultKnownHostsURL

    // Validate authentication prerequisites before network activity
    switch authentication {
    case .sshAgent:
      let sockPath = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] ?? ""
      guard !sockPath.isEmpty, FileManager.default.fileExists(atPath: sockPath) else {
        status = .failed(AppLocalization.string("No active SSH agent found (SSH_AUTH_SOCK is missing or invalid). Please start an agent or add your keys."))
        return
      }
    case .keychainCredential(let record, _):
      guard KeychainCredentialReference.decode(record.keychainItemID) != nil else {
        status = .failed(AppLocalization.string("The saved credential reference is damaged. Recreate the credential in Security → Credentials."))
        return
      }
    case .password:
      break
    }

    self.pendingConnectionTarget = PendingConnectionTarget(
      username: username,
      port: port,
      knownHostsURL: hostsURL,
      authenticationChoice: authentication,
      proxyJump: proxyJump
    )

    if let proxyJump {
      beginHostTrustEvaluation(
        host: proxyJump.host,
        port: proxyJump.port,
        role: .jumpHost,
        sessionID: thisSessionID
      )
    } else {
      beginTargetTrustEvaluation(sessionID: thisSessionID)
    }
  }

  private func beginHostTrustEvaluation(
    host endpointHost: String,
    port endpointPort: Int,
    role: TrustEndpointRole,
    sessionID: UUID
  ) {
    guard let pending = pendingConnectionTarget else { return }
    status = .verifyingHost(host: endpointHost, port: endpointPort)
    trustEndpointRole = role

    let trustService = NativeSSHHostTrustService(knownHostsFileURL: pending.knownHostsURL, audit: NativeSSHHostTrustService.appAuditSink)
    let coordinator = sessionCoordinator
    let isCancelled: @Sendable () -> Bool = { !coordinator.isValid(sessionID) }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard coordinator.isValid(sessionID) else { return }
      do {
        let trustStatus = try trustService.evaluateEndpoint(
          host: endpointHost,
          port: endpointPort,
          isCancelled: isCancelled
        )
        DispatchQueue.main.async { [weak self] in
          self?.consumeTrustStatus(trustStatus, role: role, sessionID: sessionID)
        }
      } catch {
        DispatchQueue.main.async { [weak self] in
          guard let self, coordinator.isValid(sessionID) else { return }
          self.status = .failed(AppLocalization.format("Host key verification failed: %1$@", error.localizedDescription))
        }
      }
    }
  }

  private func beginTargetTrustEvaluation(sessionID: UUID) {
    guard let pending = pendingConnectionTarget else { return }
    status = .verifyingHost(host: host.address, port: pending.port)
    trustEndpointRole = .targetHost

    let trustService = NativeSSHHostTrustService(knownHostsFileURL: pending.knownHostsURL, audit: NativeSSHHostTrustService.appAuditSink)
    let targetHost = host.address
    let coordinator = sessionCoordinator
    let isCancelled: @Sendable () -> Bool = { !coordinator.isValid(sessionID) }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard coordinator.isValid(sessionID) else { return }
      do {
        let trustStatus: SSHHostTrustStatus
        if let jump = pending.proxyJump {
          let resolvedAuth = try self?.resolveAuthentication(
            pending.authenticationChoice,
            username: pending.username
          )
          guard let resolvedAuth else { return }
          let configuration = NativeSSHConfiguration(
            host: targetHost,
            port: pending.port,
            username: pending.username,
            knownHostsFileURL: pending.knownHostsURL,
            authentication: resolvedAuth,
            proxyJump: jump
          )
          trustStatus = try NativeSSHProxyJumpProbe.evaluateTargetHost(
            configuration: configuration,
            trustService: trustService,
            isCancelled: isCancelled
          )
        } else {
          trustStatus = try trustService.evaluateEndpoint(
            host: targetHost,
            port: pending.port,
            isCancelled: isCancelled
          )
        }
        DispatchQueue.main.async { [weak self] in
          self?.consumeTrustStatus(trustStatus, role: .targetHost, sessionID: sessionID)
        }
      } catch {
        DispatchQueue.main.async { [weak self] in
          guard let self, coordinator.isValid(sessionID) else { return }
          self.status = .failed(AppLocalization.format("Host key verification failed: %1$@", error.localizedDescription))
        }
      }
    }
  }

  private func consumeTrustStatus(_ trustStatus: SSHHostTrustStatus, role: TrustEndpointRole, sessionID: UUID) {
    guard sessionCoordinator.isValid(sessionID), let pending = pendingConnectionTarget else { return }
    switch trustStatus {
    case .trusted:
      activeChallenge = nil
      activeChallengeRole = nil
      if role == .jumpHost {
        // Only after the jump key is already trusted may its credentials be used to probe the target.
        beginTargetTrustEvaluation(sessionID: sessionID)
      } else {
        launchSSHSession(
          username: pending.username,
          port: pending.port,
          knownHostsURL: pending.knownHostsURL,
          authenticationChoice: pending.authenticationChoice,
          proxyJump: pending.proxyJump,
          sessionID: sessionID
        )
      }
    case .unknown(let challenge):
      activeChallenge = challenge
      activeChallengeRole = role
      trustEndpointRole = role
      status = .hostTrustRequired(challenge: challenge)
    case .mismatch(let recorded, let presented):
      activeChallenge = nil
      activeChallengeRole = role
      trustEndpointRole = role
      cleanupEphemeralCredential()
      status = .hostKeyMismatch(recordedKeys: recorded, presentedKey: presented)
    }
  }

  // MARK: - Trust Decision Handling

  /// User accepts and trusts the presented host key.
  /// Persists into known_hosts and proceeds with connection under strict checking.
  public func approveTrustChallenge() {
    guard case .hostTrustRequired(let challenge) = status,
          let active = self.activeChallenge,
          active.id == challenge.id,
          let challengeRole = self.activeChallengeRole,
          let target = self.pendingConnectionTarget else {
      return
    }

    let expectedEndpoint: (host: String, port: Int)
    switch challengeRole {
    case .jumpHost:
      guard let jump = target.proxyJump else {
        failStaleTrustChallenge()
        return
      }
      expectedEndpoint = (jump.host, jump.port)
    case .targetHost:
      expectedEndpoint = (host.address, target.port)
    }

    guard challenge.host == expectedEndpoint.host, challenge.port == expectedEndpoint.port else {
      self.activeChallenge = nil
      self.activeChallengeRole = nil
      self.pendingConnectionTarget = nil
      self.cleanupEphemeralCredential()
      self.status = .failed(AppLocalization.string("Host trust challenge no longer matches the active connection."))
      return
    }

    let thisSessionID = sessionCoordinator.reset()
    let trustService = NativeSSHHostTrustService(knownHostsFileURL: target.knownHostsURL, audit: NativeSSHHostTrustService.appAuditSink)
    let coordinator = self.sessionCoordinator
    let isCancelled: @Sendable () -> Bool = { !coordinator.isValid(thisSessionID) }

    self.status = .connecting
    self.activeChallenge = nil

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard coordinator.isValid(thisSessionID) else { return }

      do {
        try trustService.approveChallenge(
          challenge,
          expectedHost: expectedEndpoint.host,
          expectedPort: expectedEndpoint.port,
          isCancelled: isCancelled,
          authorizePersistence: { persist in
            try coordinator.performIfValid(thisSessionID, operation: persist)
          }
        )

        guard coordinator.isValid(thisSessionID) else { return }

        DispatchQueue.main.async { [weak self] in
          guard let self = self, coordinator.isValid(thisSessionID) else { return }
          self.activeChallengeRole = nil
          if challengeRole == .jumpHost {
            self.beginTargetTrustEvaluation(sessionID: thisSessionID)
          } else {
            self.launchSSHSession(
              username: target.username,
              port: target.port,
              knownHostsURL: target.knownHostsURL,
              authenticationChoice: target.authenticationChoice,
              proxyJump: target.proxyJump,
              sessionID: thisSessionID
            )
          }
        }
      } catch {
        DispatchQueue.main.async { [weak self] in
          guard let self = self, coordinator.isValid(thisSessionID) else { return }
          self.status = .failed(AppLocalization.format("Failed to persist host trust: %1$@", error.localizedDescription))
        }
      }
    }
  }

  /// Explicit, user-confirmed replacement of the recorded key for the endpoint that mismatched
  /// (target or jump host). Audited as ssh.hostkey.rotated; then continues like `approveTrustChallenge`.
  public func rotateMismatchedHostKey() {
    guard case .hostKeyMismatch(_, let presented) = status,
          let role = activeChallengeRole,
          let target = pendingConnectionTarget else { return }
    let endpoint: (host: String, port: Int)
    switch role {
    case .jumpHost:
      guard let jump = target.proxyJump else { failStaleTrustChallenge(); return }
      endpoint = (jump.host, jump.port)
    case .targetHost:
      endpoint = (host.address, target.port)
    }
    let challenge = SSHHostTrustChallenge(host: endpoint.host, port: endpoint.port, presentedKey: presented)
    let sessionID = sessionCoordinator.reset()
    let trustService = NativeSSHHostTrustService(knownHostsFileURL: target.knownHostsURL, audit: NativeSSHHostTrustService.appAuditSink)
    let coordinator = sessionCoordinator
    let isCancelled: @Sendable () -> Bool = { !coordinator.isValid(sessionID) }
    status = .connecting

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      do {
        try trustService.rotateKnownHostKey(
          challenge, expectedHost: endpoint.host, expectedPort: endpoint.port, isCancelled: isCancelled)
        DispatchQueue.main.async { [weak self] in
          guard let self, coordinator.isValid(sessionID) else { return }
          self.activeChallengeRole = nil
          if role == .jumpHost {
            self.beginTargetTrustEvaluation(sessionID: sessionID)
          } else {
            self.launchSSHSession(
              username: target.username, port: target.port, knownHostsURL: target.knownHostsURL,
              authenticationChoice: target.authenticationChoice, proxyJump: target.proxyJump, sessionID: sessionID)
          }
        }
      } catch {
        DispatchQueue.main.async { [weak self] in
          guard let self, coordinator.isValid(sessionID) else { return }
          self.status = .failed(AppLocalization.format("Failed to rotate host key: %1$@", error.localizedDescription))
        }
      }
    }
  }

  /// User rejects the trust challenge or cancels. No authentication attempt is made.
  public func rejectTrustChallenge() {
    sessionCoordinator.invalidate()
    self.activeChallenge = nil
    self.activeChallengeRole = nil
    self.trustEndpointRole = nil
    self.pendingConnectionTarget = nil
    self.cleanupEphemeralCredential()
    self.status = .disconnected(exitCode: nil)
  }

  private func failStaleTrustChallenge() {
    activeChallenge = nil
    activeChallengeRole = nil
    pendingConnectionTarget = nil
    trustEndpointRole = nil
    cleanupEphemeralCredential()
    status = .failed(AppLocalization.string("Host trust challenge no longer matches the active connection."))
  }

  // MARK: - Internal Session Launch

  nonisolated private func resolveAuthentication(
    _ choice: AuthenticationChoice,
    username: String
  ) throws -> NativeSSHAuthentication {
    switch choice {
    case .sshAgent:
      let sockPath = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] ?? ""
      guard !sockPath.isEmpty, FileManager.default.fileExists(atPath: sockPath) else {
        throw NativeSSHError.connectionFailed(details: AppLocalization.string("No active SSH agent found (SSH_AUTH_SOCK is missing or invalid)."))
      }
      return .agent(socketURL: URL(fileURLWithPath: sockPath))

    case .keychainCredential(let record, let identityFileURL):
      guard let reference = KeychainCredentialReference.decode(record.keychainItemID) else {
        throw NativeSSHError.connectionFailed(details: AppLocalization.string("The saved credential reference is damaged."))
      }
      return .keychainAskpass(
        service: reference.service,
        account: reference.account,
        identityFile: identityFileURL
      )

    case .password(let secret, let saveToKeychain, let label):
      let defaultLabel = "\(host.displayName) (\(username))"
      let prepared = try passwordAuthService.preparePasswordAuthentication(
        secret: secret,
        saveToKeychain: saveToKeychain,
        label: label,
        defaultLabel: defaultLabel
      )
      if let ephemeral = prepared.ephemeralReference {
        self.ephemeralHolder.set(ephemeral)
      }
      if let saved = prepared.savedRecord {
        DispatchQueue.main.async { [weak self] in
          self?.newlySavedCredential = saved
        }
      }
      return prepared.authentication
    }
  }

  private func launchSSHSession(
    username: String,
    port: Int,
    knownHostsURL: URL,
    authenticationChoice: AuthenticationChoice,
    proxyJump: NativeSSHProxyJumpEndpoint?,
    sessionID: UUID
  ) {
    let resolvedAuth: NativeSSHAuthentication
    do {
      resolvedAuth = try resolveAuthentication(authenticationChoice, username: username)
    } catch let error as CredentialStoreError {
      cleanupEphemeralCredential()
      status = .failed(error.localizedDescription)
      return
    } catch {
      cleanupEphemeralCredential()
      status = .failed(AppLocalization.format("Authentication setup failed: %1$@", error.localizedDescription))
      return
    }

    let config = NativeSSHConfiguration(
      host: host.address,
      port: port,
      username: username,
      knownHostsFileURL: knownHostsURL,
      authentication: resolvedAuth,
      proxyJump: proxyJump,
      initialTerminalSize: NativeSSHTerminalSize(rows: 24, columns: 80),
      termEnvironment: "xterm-256color"
    )

    do {
      try NativeSSHSession.validate(configuration: config)
    } catch {
      cleanupEphemeralCredential()
      status = .failed(error.localizedDescription)
      return
    }

    let newSession = NativeSSHSession(configuration: config)
    self.session = newSession
    self.status = .connecting

    let buf = self.outputBuffer
    let raw = self.rawBuffer
    newSession.onOutput = { data in
      buf.append(data)
      raw.append(data)
    }

    newSession.onStateChange = { [weak self, weak newSession] state in
      DispatchQueue.main.async { [weak self] in
        guard let self = self, self.sessionCoordinator.isValid(sessionID) else { return }
        let currentState = newSession?.state ?? state
        switch currentState {
        case .idle:
          self.status = .idle
        case .connecting:
          self.status = .connecting
        case .running:
          self.reconnectBackoff.reset()
          self.status = .running
        case .disconnected(let code):
          self.drainOutput()
          self.localTunnels = []
          self.cleanupEphemeralCredential()
          self.status = .disconnected(exitCode: code)
        case .failed(let msg):
          self.drainOutput()
          self.cleanupEphemeralCredential()
          self.reconnectBackoff.recordFailure()
          self.status = .failed(msg)
        }
      }
    }

    let coordinator = self.sessionCoordinator
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      do {
        try newSession.start()
      } catch {
        DispatchQueue.main.async { [weak self] in
          guard let self = self, coordinator.isValid(sessionID) else { return }
          self.cleanupEphemeralCredential()
          self.reconnectBackoff.recordFailure()
          self.status = .failed(error.localizedDescription)
        }
      }
    }
  }

  /// Disconnect and terminate the underlying session process safely off main thread.
  public func disconnect() {
    sessionCoordinator.invalidate()
    reconnectBackoff.reset()  // explicit cancel clears throttle
    self.activeChallenge = nil
    self.activeChallengeRole = nil
    self.trustEndpointRole = nil
    self.pendingConnectionTarget = nil
    self.cleanupEphemeralCredential()
    localTunnels = []
    tunnelError = nil
    let currentSession = session
    session = nil
    if let currentSession {
      DispatchQueue.global(qos: .utility).async {
        currentSession.close()
      }
    }
    drainOutput()
    status = .disconnected(exitCode: nil)
  }

  /// Synchronous bounded close for application termination ONLY (caller is NSApplication.willTerminateNotification).
  public func terminateSync() {
    sessionCoordinator.invalidate()
    self.activeChallenge = nil
    self.activeChallengeRole = nil
    self.trustEndpointRole = nil
    self.pendingConnectionTarget = nil
    self.cleanupEphemeralCredential()
    localTunnels = []
    tunnelError = nil
    drainTimerHolder.invalidate()
    let currentSession = session
    session = nil
    currentSession?.close()
    drainOutput()
    status = .disconnected(exitCode: nil)
  }

  /// Start a strictly authenticated local forward from the active SSH session.
  public func startLocalTunnel(localPort: Int, remoteHost: String, remotePort: Int) {
    guard status == .running, let session else {
      tunnelError = AppLocalization.string("Connect to the SSH host before starting a tunnel.")
      return
    }

    tunnelError = nil
    let tunnelConfiguration = NativeSSHLocalTunnelConfiguration(
      localPort: localPort,
      remoteHost: remoteHost,
      remotePort: remotePort
    )
    let currentSession = session
    ioQueue.async { [weak self, currentSession] in
      do {
        _ = try currentSession.startLocalTunnel(configuration: tunnelConfiguration) { [weak self, currentSession] _ in
          DispatchQueue.main.async { [weak self, currentSession] in
            guard let self, self.session === currentSession else { return }
            self.localTunnels = currentSession.localTunnelSummaries
          }
        }
        DispatchQueue.main.async { [weak self, currentSession] in
          guard let self, self.session === currentSession else { return }
          self.localTunnels = currentSession.localTunnelSummaries
        }
      } catch {
        DispatchQueue.main.async { [weak self, currentSession] in
          guard let self, self.session === currentSession else { return }
          self.tunnelError = error.localizedDescription
          self.localTunnels = currentSession.localTunnelSummaries
        }
      }
    }
  }

  /// Explicitly stop a tunnel while keeping its owner SSH session alive.
  public func stopLocalTunnel(id: UUID) {
    guard let session else { return }
    let currentSession = session
    ioQueue.async { [weak self, currentSession] in
      _ = currentSession.stopLocalTunnel(id: id)
      DispatchQueue.main.async { [weak self, currentSession] in
        guard let self, self.session === currentSession else { return }
        self.localTunnels = currentSession.localTunnelSummaries
      }
    }
  }

  /// Send terminal input string over PTY.
  public func sendInput() {
    guard !inputBuffer.isEmpty else { return }
    let toSend = inputBuffer
    inputBuffer = ""
    send(toSend)
  }

  /// Send raw string to the PTY serially with error handling.
  public func send(_ text: String) {
    guard let session = session else { return }
    ioQueue.async { [weak self, weak session] in
      guard let session = session else { return }
      do {
        try session.write(string: text)
      } catch {
        DispatchQueue.main.async { [weak self] in
          guard let self = self, self.session === session else { return }
          self.appendOutput("\n[I/O error: \(terminalDiagnostic(error))]\n")
        }
      }
    }
  }

  /// Send raw emulator-generated bytes (keystrokes, escape replies) to the PTY.
  func sendRaw(_ bytes: ArraySlice<UInt8>) {
    guard let session = session, !bytes.isEmpty else { return }
    let data = Data(bytes)
    ioQueue.async { [weak self, weak session] in
      guard let session = session else { return }
      do {
        try session.write(data: data)
      } catch {
        DispatchQueue.main.async { [weak self] in
          guard let self = self, self.session === session else { return }
          self.appendOutput("\n[I/O error: \(terminalDiagnostic(error))]\n")
        }
      }
    }
  }

  /// Send common control characters serially with error handling.
  public func sendControlCharacter(_ char: Character) {
    guard let ascii = char.asciiValue else { return }
    let ctrlCode = ascii & 0x1F
    let data = Data([ctrlCode])
    guard let session = session else { return }
    ioQueue.async { [weak self, weak session] in
      guard let session = session else { return }
      do {
        try session.write(data: data)
      } catch {
        DispatchQueue.main.async { [weak self] in
          guard let self = self, self.session === session else { return }
          self.appendOutput("\n[I/O error: \(terminalDiagnostic(error))]\n")
        }
      }
    }
  }

  /// Resize remote terminal dimensions.
  public func resize(rows: UInt16, columns: UInt16) {
    guard let session = session else { return }
    ioQueue.async { [weak self, weak session] in
      guard let session = session else { return }
      do {
        try session.resize(rows: rows, columns: columns)
      } catch {
        DispatchQueue.main.async { [weak self] in
          guard let self = self, self.session === session else { return }
          self.appendOutput("\n[Resize error: \(terminalDiagnostic(error))]\n")
        }
      }
    }
  }

  func appendOutput(_ newText: String) {
    terminalOutput.append(newText)
    if terminalOutput.count > maxTerminalCharacters {
      let excess = terminalOutput.count - maxTerminalCharacters
      terminalOutput.removeFirst(excess)
    }
  }

  private func terminalDiagnostic(_ error: Error) -> String {
    (error as? AppCoreLocalizedError)?.displayDescription(locale: Locale(identifier: "en"))
      ?? error.localizedDescription
  }

  private var isTerminalState: Bool {
    switch status {
    case .disconnected, .failed:
      return true
    default:
      return false
    }
  }
}
