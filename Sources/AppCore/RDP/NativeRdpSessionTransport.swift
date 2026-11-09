import Foundation

/// Reasons for an RDP session disconnect.
public enum RdpDisconnectReason: Sendable, Equatable {
  case userInitiated
  case networkDrop
  case helperCrashed
  case authenticationFailed
  case certificateRejected
}

/// Errors raised by the RDP session transport.
public enum RdpSessionError: Error, Equatable, AppCoreLocalizedError {
  case unavailable
  case invalidEndpoint(String)
  case dnsResolutionFailed(String)
  case tcpConnectionFailed(String)
  case tlsHandshakeFailed(String)
  case certificateMismatch(details: String)
  case credentialUnavailable(String)
  case protocolViolation(String)
  case helperProcessFailed(String)

  public func displayDescription(locale: Locale?) -> String? {
    switch self {
    case .unavailable:
      return AppCoreLocalization.string("Embedded RDP is not available. Use an external RDP client.", locale: locale)
    case .invalidEndpoint(let msg):
      return AppCoreLocalization.format(
        "Invalid RDP endpoint: %1$@", AppCoreLocalization.string(msg, locale: locale), locale: locale)
    case .dnsResolutionFailed(let host):
      return AppCoreLocalization.format("DNS resolution failed for RDP host: %1$@", host, locale: locale)
    case .tcpConnectionFailed(let reason):
      return AppCoreLocalization.format("TCP connection to RDP port failed: %1$@", reason, locale: locale)
    case .tlsHandshakeFailed(let reason):
      return AppCoreLocalization.format("TLS handshake with Windows host failed: %1$@", reason, locale: locale)
    case .certificateMismatch(let details):
      return AppCoreLocalization.format("Strict RDP certificate verification failed: %1$@. Connection blocked.", details, locale: locale)
    case .credentialUnavailable(let reason):
      return AppCoreLocalization.format("RDP credentials unavailable: %1$@", reason, locale: locale)
    case .protocolViolation(let msg):
      return AppCoreLocalization.format(
        "RDP protocol violation: %1$@", AppCoreLocalization.string(msg, locale: locale), locale: locale)
    case .helperProcessFailed(let msg):
      return AppCoreLocalization.format("RDP helper process failure: %1$@", msg, locale: locale)
    }
  }
}

/// Observable lifecycle states of a native RDP session.
public enum NativeRdpSessionState: Sendable, Equatable {
  case idle
  case resolving
  case connecting
  case verifyingCertificate(challenge: RdpCertificateTrustChallenge)
  case authenticating
  case connected
  case interrupted
  case disconnecting
  case disconnected(reason: RdpDisconnectReason)
  case failed(error: RdpSessionError)
}

/// Input and clipboard policy for an RDP session (S1-03, AG-010, AG-012).
/// Reusable gate for both local user input and future supervised agent control.
public enum RdpInputPolicy: String, Codable, Sendable, Equatable, CaseIterable {
  case interactive
  case viewOnly

  public var isViewOnly: Bool { self == .viewOnly }
  public var allowsInput: Bool { self == .interactive }
  public var allowsClipboard: Bool { self == .interactive }
}

/// Configuration required to establish a native RDP session.
public struct RdpSessionConfiguration: Sendable, Equatable {
  public let id: UUID
  public let host: String
  public let port: Int
  public let username: String
  public let credentialRefID: String?
  public let options: RdpConnectionOptions
  public let initialResolution: RdpDisplayResolution
  public var inputPolicy: RdpInputPolicy
  /// Mac folder shared with Windows as `\\tsclient\<name>`; nil = no device redirection.
  public var sharedFolderPath: String?

  public init(
    id: UUID = UUID(),
    host: String,
    port: Int = 3389,
    username: String,
    credentialRefID: String?,
    initialResolution: RdpDisplayResolution = RdpDisplayResolution(width: 1920, height: 1080, scaleFactor: 100),
    sharedFolderPath: String? = nil,
    options: RdpConnectionOptions = RdpConnectionOptions(),
    inputPolicy: RdpInputPolicy = .interactive
  ) {
    self.id = id
    self.host = host
    self.port = port
    self.username = username
    self.credentialRefID = credentialRefID
    self.options = options
    self.initialResolution = options.initialResolution(initialResolution)
    self.inputPolicy = inputPolicy
    self.sharedFolderPath = sharedFolderPath
  }
}

/// Protocol contract for the RDP session transport layer.
public protocol RdpSessionTransport: AnyObject, Sendable {
  var id: UUID { get }
  var state: NativeRdpSessionState { get }
  var inputPolicy: RdpInputPolicy { get }
  var isViewOnly: Bool { get }
  var onStateChange: (@Sendable (NativeRdpSessionState) -> Void)? { get set }
  var onInputPolicyChange: (@Sendable (RdpInputPolicy) -> Void)? { get set }
  var onFrameReady: (@Sendable (RdpFramebuffer) -> Void)? { get set }

  func connect() async throws
  func disconnect() async
  func setInputPolicy(_ policy: RdpInputPolicy)
  func setViewOnly(_ viewOnly: Bool)
  func sendKeyEvent(_ event: RdpKeyboardEvent)
  func sendPointerEvent(x: UInt16, y: UInt16, buttonFlags: UInt16)
  func updateResolution(_ resolution: RdpDisplayResolution)
}

/// Embedded RDP session backed by FreeRDP running in a separate `RdpSessionHelper` process,
/// so a FreeRDP crash surfaces as `.disconnected(.helperCrashed)` instead of killing the app.
///
/// State machine: idle -> resolving -> connecting -> [verifyingCertificate] -> authenticating
/// -> connected -> disconnected/failed. `connect()` returns once the session is connected, a
/// trust decision is pending (state `.verifyingCertificate`), or it failed (throws).
public final class NativeRdpSession: RdpSessionTransport, @unchecked Sendable {
  public let id: UUID
  public let configuration: RdpSessionConfiguration
  private let certificateVerifier: RdpHostCertificateVerifier
  private let credentialResolver: RdpCredentialResolving

  private let lock = NSLock()
  private var _state: NativeRdpSessionState = .idle
  private var _inputPolicy: RdpInputPolicy
  private var activeChallenge: RdpCertificateTrustChallenge?
  private let helperURL: URL?
  private var client: RdpHelperProcess?
  private var isClosed = false
  private var milestone: CheckedContinuation<Void, Error>?
  /// Set by the RDP thread before it rejects, so the end-of-session error is specific.
  private var pendingFailure: RdpSessionError?
  private let trustDecision = DispatchSemaphore(value: 0)
  private var trustAccepted = false
  private var _onStateChange: (@Sendable (NativeRdpSessionState) -> Void)?
  private var _onInputPolicyChange: (@Sendable (RdpInputPolicy) -> Void)?
  private var _onReleaseHeldInput: (@Sendable () -> Void)?
  private struct HeldKey: Hashable, Comparable {
    let scancode: UInt16
    let isExtended: Bool

    static func < (lhs: HeldKey, rhs: HeldKey) -> Bool {
      if lhs.scancode != rhs.scancode { return lhs.scancode < rhs.scancode }
      return !lhs.isExtended && rhs.isExtended
    }
  }

  private static let pointerButtonPairs: [(down: UInt16, up: UInt16)] = [
    (0x01, 0x02),
    (0x04, 0x08),
    (0x09, 0x0A),
  ]

  private var heldKeys: Set<HeldKey> = []
  private var heldButtons: Set<UInt16> = []
  private var lastPointerPosition: (x: UInt16, y: UInt16) = (0, 0)
  private var clipboardFocused = false
  private var effectiveClipboardFocused = false
  private var _onClipboardStatus: (@Sendable (String, Bool) -> Void)?
  private var _onFrameReady: (@Sendable (RdpFramebuffer) -> Void)?

  public var onStateChange: (@Sendable (NativeRdpSessionState) -> Void)? {
    get { lock.withLock { _onStateChange } }
    set { lock.withLock { _onStateChange = newValue } }
  }
  public var onInputPolicyChange: (@Sendable (RdpInputPolicy) -> Void)? {
    get { lock.withLock { _onInputPolicyChange } }
    set { lock.withLock { _onInputPolicyChange = newValue } }
  }
  /// Invoked synchronously right before transitioning to `.viewOnly` so the active input source
  /// can flush any held key/button release events through the transport before the input gate closes.
  public var onReleaseHeldInput: (@Sendable () -> Void)? {
    get { lock.withLock { _onReleaseHeldInput } }
    set { lock.withLock { _onReleaseHeldInput = newValue } }
  }
  public var onFrameReady: (@Sendable (RdpFramebuffer) -> Void)? {
    get { lock.withLock { _onFrameReady } }
    set { lock.withLock { _onFrameReady = newValue } }
  }

  public var onClipboardStatus: (@Sendable (String, Bool) -> Void)? {
    get { lock.withLock { _onClipboardStatus } }
    set { lock.withLock { _onClipboardStatus = newValue } }
  }

  public var inputPolicy: RdpInputPolicy {
    lock.withLock { _inputPolicy }
  }

  public var isViewOnly: Bool {
    inputPolicy.isViewOnly
  }

  public func setViewOnly(_ viewOnly: Bool) {
    setInputPolicy(viewOnly ? .viewOnly : .interactive)
  }

  public func setInputPolicy(_ policy: RdpInputPolicy) {
    let transitionResult = lock.withLock { () -> (
      changed: Bool,
      releaseCallback: (@Sendable () -> Void)?,
      policyCallback: (@Sendable (RdpInputPolicy) -> Void)?
    ) in
      guard !isClosed, _inputPolicy != policy else {
        return (false, nil, nil)
      }
      if policy.isViewOnly {
        if _state == .connected, let client {
          flushHeldInputLocked(to: client)
        } else {
          heldKeys.removeAll()
          heldButtons.removeAll()
        }
      }
      _inputPolicy = policy
      let newEffectiveFocus = clipboardFocused && policy.allowsClipboard
      let focusChanged = effectiveClipboardFocused != newEffectiveFocus
      effectiveClipboardFocused = newEffectiveFocus
      if focusChanged {
        client?.setClipboardFocused(newEffectiveFocus)
      }
      if !policy.allowsClipboard {
        client?.cancelClipboardFiles()
      }
      return (
        true,
        policy.isViewOnly ? _onReleaseHeldInput : nil,
        _onInputPolicyChange
      )
    }
    guard transitionResult.changed else { return }
    transitionResult.releaseCallback?()
    transitionResult.policyCallback?(policy)
  }

  private func flushHeldInputLocked(to helper: RdpHelperProcess) {
    let keysToRelease = heldKeys.sorted()
    heldKeys.removeAll()
    for key in keysToRelease {
      helper.sendKey(RdpKeyboardEvent(scancode: key.scancode, isExtended: key.isExtended, isKeyUp: true))
    }
    let pos = lastPointerPosition
    for pair in Self.pointerButtonPairs where heldButtons.contains(pair.down) {
      helper.sendPointer(x: pos.x, y: pos.y, buttonFlags: pair.up)
    }
    heldButtons.removeAll()
  }

  public func cancelClipboardFiles() { lock.withLock { client }?.cancelClipboardFiles() }

  public func setClipboardFocused(_ focused: Bool) {
    lock.withLock {
      clipboardFocused = focused
      let newEffectiveFocus = focused && _inputPolicy.allowsClipboard
      guard effectiveClipboardFocused != newEffectiveFocus else { return }
      effectiveClipboardFocused = newEffectiveFocus
      client?.setClipboardFocused(newEffectiveFocus)
    }
  }

  /// Test hook: pid of the running helper.
  var helperProcessIdentifier: Int32? { lock.withLock { client }?.processIdentifier }

  public var state: NativeRdpSessionState {
    lock.lock()
    defer { lock.unlock() }
    return _state
  }

  public init(
    configuration: RdpSessionConfiguration,
    certificateVerifier: RdpHostCertificateVerifier,
    credentialResolver: RdpCredentialResolving,
    helperURL: URL? = nil
  ) {
    self.helperURL = helperURL
    self.id = configuration.id
    self.configuration = configuration
    self._inputPolicy = configuration.inputPolicy
    self.certificateVerifier = certificateVerifier
    self.credentialResolver = credentialResolver
  }

  deinit {
    disconnectSync()
  }

  /// Applies a state unless the session was already closed by the user.
  private func transition(to newState: NativeRdpSessionState, force: Bool = false) {
    lock.lock()
    if isClosed && !force { lock.unlock(); return }
    _state = newState
    let callback = _onStateChange
    lock.unlock()
    switch newState {
    case .connected: RedactedLogger.shared.info("rdp", "session connected \(configuration.host):\(configuration.port)")
    case .failed: RedactedLogger.shared.error("rdp", "session failed \(configuration.host):\(configuration.port)")
    case .disconnected: RedactedLogger.shared.info("rdp", "session closed \(configuration.host):\(configuration.port)")
    default: break
    }
    callback?(newState)
  }

  private func resumeMilestone(_ result: Result<Void, Error>) {
    lock.lock()
    let continuation = milestone
    milestone = nil
    lock.unlock()
    continuation?.resume(with: result)
  }

  private func awaitMilestone(starting body: () -> Void) async throws {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
      lock.lock()
      milestone = c
      lock.unlock()
      body()
    }
  }

  // MARK: - Connection Lifecycle

  public func connect() async throws {
    transition(to: .resolving)
    guard !configuration.host.isEmpty, (1...65535).contains(configuration.port) else {
      let error = RdpSessionError.invalidEndpoint("Host or port is invalid.")
      transition(to: .failed(error: error))
      throw error
    }
    let sharedFolder: URL?
    do {
      sharedFolder = try configuration.sharedFolderPath.map(RdpSharedFolder.validate)
    } catch {
      let error = RdpSessionError.invalidEndpoint("Shared folder is not an accessible folder.")
      transition(to: .failed(error: error))
      throw error
    }
    let alreadyStarted = lock.withLock { client != nil || isClosed }
    guard !alreadyStarted else {
      throw RdpSessionError.protocolViolation("Session already started; create a new session to reconnect.")
    }
    transition(to: .connecting)

    guard let url = helperURL ?? RdpHelperProcess.defaultHelperURL() else {
      let error = RdpSessionError.helperProcessFailed("RdpSessionHelper executable not found next to the app.")
      transition(to: .failed(error: error))
      throw error
    }
    let client = RdpHelperProcess(
      helperURL: url, host: configuration.host, port: configuration.port,
      resolution: configuration.initialResolution, sharedFolder: sharedFolder?.path, options: configuration.options,
      callbacks: .init(
        onCertificate: { [weak self] cert, changed in
          // verification may wait for the user; keep the helper reader thread free for the watchdog
          guard let session = self else { return }
          let thread = Thread { session.verifyAndAnswer(cert, changed: changed) }
          thread.name = "mrw.rdp.trust"
          thread.start()
        },
        onConnected: { [weak self] in
          self?.transition(to: .connected)
          self?.resumeMilestone(.success(()))
        },
        onFrame: { [weak self] frame in self?.forwardFrame(frame) },
        onEnded: { [weak self] code, message, wasConnected in
          self?.handleEnded(code: code, message: message, wasConnected: wasConnected)
        },
        onCrash: { [weak self] wasConnected in self?.handleHelperCrash(wasConnected: wasConnected) },
        onClipboardStatus: { [weak self] message, busy in
          self?.lock.withLock { self?._onClipboardStatus }?(message, busy)
        }
      ))
    lock.withLock {
      self.client = client
      let effective = clipboardFocused && _inputPolicy.allowsClipboard
      effectiveClipboardFocused = effective
      client.setClipboardFocused(effective)
    }
    do {
      // start inside the body so no helper message can arrive before the milestone is armed
      try await awaitMilestone {
        // closeAndAbort may have run before `client` was visible to it; never start a helper then.
        if lock.withLock({ isClosed }) {
          resumeMilestone(.failure(RdpSessionError.helperProcessFailed("Session closed before start.")))
          return
        }
        do {
          try client.start()
          lock.withLock {
            let effective = clipboardFocused && _inputPolicy.allowsClipboard
            effectiveClipboardFocused = effective
            client.setClipboardFocused(effective)
            if !_inputPolicy.allowsClipboard {
              client.cancelClipboardFiles()
            }
          }
        } catch {
          resumeMilestone(.failure(error))
        }
      }
    } catch {
      if let rdp = error as? RdpSessionError { transition(to: .failed(error: rdp)) }
      throw error
    }
  }

  /// Decides trust on its own thread and answers the helper; credentials leave the app only on acceptance.
  private func verifyAndAnswer(_ cert: RdpCertificateRecord, changed: Bool) {
    let decision = verifyOnRdpThread(cert, changed: changed)
    lock.withLock { client }?.sendTrust(decision?.credentials)
  }

  /// Blocks until trust is decided (explicit user decision for unknown certificates).
  private func verifyOnRdpThread(_ cert: RdpCertificateRecord, changed: Bool) -> RdpTrustDecision? {
    if changed {
      return fail(.certificateMismatch(details: "Server certificate changed (\(cert.sha256Fingerprint))"))
    }
    let verifier = certificateVerifier
    let status: RdpHostTrustStatus
    do {
      status = try Self.blocking { try await verifier.evaluateTrust(host: cert.host, port: cert.port, presented: cert) }
    } catch {
      return fail(.certificateMismatch(details: error.localizedDescription))
    }
    switch status {
    case .trusted:
      return resolveCredentialsAfterTrust()
    case .mismatch(let recorded, let presented):
      return fail(.certificateMismatch(
        details: "Expected SHA-256 \(recorded.sha256Fingerprint), presented \(presented.sha256Fingerprint)"))
    case .unknown(let challenge):
      lock.lock()
      activeChallenge = challenge
      trustAccepted = false
      lock.unlock()
      transition(to: .verifyingCertificate(challenge: challenge))
      resumeMilestone(.success(()))
      trustDecision.wait()  // blocks the RDP thread until explicit user decision (or abort)
      lock.lock()
      let accepted = trustAccepted && !isClosed
      lock.unlock()
      return accepted ? resolveCredentialsAfterTrust() : nil
    }
  }

  private func resolveCredentialsAfterTrust() -> RdpTrustDecision? {
    transition(to: .authenticating)
    do {
      let creds = try credentialResolver.resolveCredentials(
        rawUsername: configuration.username, credentialRefID: configuration.credentialRefID)
      return RdpTrustDecision(credentials: creds)
    } catch {
      return fail(.credentialUnavailable(error.localizedDescription))
    }
  }

  private func fail(_ error: RdpSessionError) -> RdpTrustDecision? {
    lock.lock()
    pendingFailure = error
    lock.unlock()
    return nil
  }

  private func handleEnded(code: UInt32, message: String, wasConnected: Bool) {
    lock.lock()
    let closed = isClosed
    let specific = pendingFailure
    lock.unlock()
    if closed {
      resumeMilestone(.failure(CancellationError()))
      return
    }
    if wasConnected {
      transition(to: .disconnected(reason: .networkDrop))
      return
    }
    let error = specific ?? mapFreeRdpError(code: code, message: message).0
    transition(to: .failed(error: error))
    resumeMilestone(.failure(error))
  }

  private func forwardFrame(_ frame: RdpFramebuffer) {
    let callback = lock.withLock { !isClosed && _state == .connected ? _onFrameReady : nil }
    callback?(frame)
  }

  /// Helper died without reporting an end: surface it and release anything waiting on it.
  private func handleHelperCrash(wasConnected: Bool) {
    lock.lock()
    let closed = isClosed
    activeChallenge = nil
    lock.unlock()
    decideTrust(false)
    if closed {
      resumeMilestone(.failure(CancellationError()))
      return
    }
    if wasConnected {
      transition(to: .disconnected(reason: .helperCrashed))
      return
    }
    let error = RdpSessionError.helperProcessFailed("RDP helper exited unexpectedly.")
    transition(to: .failed(error: error))
    resumeMilestone(.failure(error))
  }

  /// Called after user explicitly confirms trust on first connect.
  public func confirmTrustAndAuthenticate() async throws {
    let challenge = lock.withLock { () -> RdpCertificateTrustChallenge? in
      defer { activeChallenge = nil }
      return activeChallenge
    }
    guard let challenge else {
      throw RdpSessionError.protocolViolation("No active certificate challenge to confirm.")
    }
    do {
      try await certificateVerifier.approveChallenge(challenge)
    } catch {
      decideTrust(false)
      throw error
    }
    try await awaitMilestone { decideTrust(true) }
  }

  /// Called if user rejects an unknown certificate.
  public func rejectCertificate() {
    lock.lock()
    activeChallenge = nil
    lock.unlock()
    closeAndAbort()
    transition(to: .disconnected(reason: .certificateRejected), force: true)
  }

  private func decideTrust(_ accepted: Bool) {
    lock.lock()
    trustAccepted = accepted
    lock.unlock()
    trustDecision.signal()
  }

  /// Bridges an async call to the dedicated RDP thread (never the cooperative pool).
  private static func blocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task {
      box.result = await Result { try await work() }
      done.signal()
    }
    done.wait()
    return try box.result!.get()
  }

  // MARK: - Input & Display Forwarding

  public func sendKeyEvent(_ event: RdpKeyboardEvent) {
    lock.withLock {
      guard !isClosed, _state == .connected, _inputPolicy.allowsInput, let client else { return }
      let key = HeldKey(scancode: event.scancode, isExtended: event.isExtended)
      if event.isKeyUp {
        heldKeys.remove(key)
      } else {
        heldKeys.insert(key)
      }
      client.sendKey(event)
    }
  }

  public func sendPointerEvent(x: UInt16, y: UInt16, buttonFlags: UInt16) {
    lock.withLock {
      guard !isClosed, _state == .connected, _inputPolicy.allowsInput, let client else { return }
      lastPointerPosition = (x, y)
      if let pair = Self.pointerButtonPairs.first(where: { $0.down == buttonFlags }) {
        heldButtons.insert(pair.down)
      } else if let pair = Self.pointerButtonPairs.first(where: { $0.up == buttonFlags }) {
        heldButtons.remove(pair.down)
      }
      client.sendPointer(x: x, y: y, buttonFlags: buttonFlags)
    }
  }

  public func updateResolution(_ resolution: RdpDisplayResolution) {
    lock.withLock {
      guard !isClosed, _state == .connected, configuration.options.displayMode == .window, let client else { return }
      client.resize(resolution)
    }
  }

  // MARK: - Disconnect

  public func disconnect() async {
    let client = closeAndAbort()
    if let client {
      await Task.detached { _ = client.waitUntilFinished(timeout: 5) }.value
    }
    let wasClosedByReject = lock.withLock { _state == .disconnected(reason: .certificateRejected) }
    if !wasClosedByReject { transition(to: .disconnected(reason: .userInitiated), force: true) }
  }

  private func disconnectSync() {
    closeAndAbort()
  }

  /// Marks closed, unblocks any pending trust wait, aborts FreeRDP. Returns the client if first close.
  @discardableResult
  private func closeAndAbort() -> RdpHelperProcess? {
    lock.lock()
    let first = !isClosed
    isClosed = true
    let client = self.client
    heldKeys.removeAll()
    heldButtons.removeAll()
    activeChallenge = nil
    _onFrameReady = nil
    _onInputPolicyChange = nil
    _onReleaseHeldInput = nil
    lock.unlock()
    guard first else { return nil }
    decideTrust(false)
    client?.abort()
    resumeMilestone(.failure(CancellationError()))
    return client
  }
}

private final class ResultBox<T>: @unchecked Sendable {
  var result: Result<T, Error>?
}
