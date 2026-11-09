import AppKit
import Darwin
import Foundation

/// App-side handle of one `RdpSessionHelper` child process (replaces the in-process FreeRDP client).
/// Watchdog: when the socket hits EOF without an `ended` message the helper crashed -> `onCrash`.
final class RdpHelperProcess: @unchecked Sendable {
  struct Callbacks {
    /// Runs on the reader thread: must not block. Answer with `sendTrust`.
    var onCertificate: @Sendable (RdpCertificateRecord, _ changed: Bool) -> Void
    var onConnected: @Sendable () -> Void
    var onFrame: @Sendable (RdpFramebuffer) -> Void
    var onEnded: @Sendable (_ lastErrorCode: UInt32, _ message: String, _ connected: Bool) -> Void
    /// Helper vanished without reporting an end (crash, kill, bad protocol).
    var onCrash: @Sendable (_ wasConnected: Bool) -> Void
    var onClipboardStatus: (@Sendable (String, Bool) -> Void)? = nil
  }

  /// Helper binary lives next to the app executable (Contents/MacOS). Under `swift test` the
  /// executable is Xcode's xctest tool, so also look beside the loaded .xctest bundle.
  static func defaultHelperURL() -> URL? {
    guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
    let testDirs = Bundle.allBundles.filter { $0.bundleURL.pathExtension == "xctest" }
      .map { $0.bundleURL.deletingLastPathComponent() }
    return ([dir] + testDirs).map { $0.appendingPathComponent("RdpSessionHelper") }
      .first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }

  private let helperURL: URL
  private let startMessage: RdpHelperMessage
  private let callbacks: Callbacks
  private let process = Process()
  let clipboardDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("mrw-rdp-session-" + UUID().uuidString, isDirectory: true)
  private var clipboardFocused = false
  private var appActive = false
  private let finished = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var channel: RdpHelperChannel?
  private var connected = false
  private var ended = false
  private var observers: [NSObjectProtocol] = []

  var processIdentifier: Int32? { lock.withLock { process.isRunning ? process.processIdentifier : nil } }

  init(
    helperURL: URL, host: String, port: Int, resolution: RdpDisplayResolution, sharedFolder: String? = nil, options: RdpConnectionOptions = RdpConnectionOptions(),
    callbacks: Callbacks
  ) {
    self.helperURL = helperURL
    self.callbacks = callbacks
    startMessage = .start(
      host: host, port: port, width: resolution.width, height: resolution.height,
      scaleFactor: resolution.scaleFactor, clipboardDirectory: clipboardDirectory.path,
      sharedFolder: sharedFolder, options: options)
  }

  deinit {
    observers.forEach(NotificationCenter.default.removeObserver)
    try? FileManager.default.removeItem(at: clipboardDirectory)
  }

  /// Spawns the helper. Throws if it cannot be launched.
  func start() throws {
    guard mkdir(clipboardDirectory.path, 0o700) == 0 else { throw RdpClipboardFileError.io }
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
      throw RdpSessionError.helperProcessFailed("socketpair failed (errno \(errno))")
    }
    // Parent end must not leak into the child, or the child would never see EOF when we die.
    _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
    let childEnd = FileHandle(fileDescriptor: fds[1], closeOnDealloc: false)
    process.executableURL = helperURL
    process.arguments = []  // never secrets in argv
    // Pass only safe OS/runtime variables; never leak parent credentials or custom env.
    process.environment = [
      "HOME": NSHomeDirectory(),
      "TMPDIR": NSTemporaryDirectory(),
      "USER": NSUserName(),
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    ]
    process.standardInput = childEnd
    process.standardOutput = childEnd
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      Darwin.close(fds[0])
      Darwin.close(fds[1])
      throw RdpSessionError.helperProcessFailed(error.localizedDescription)
    }
    Darwin.close(fds[1])  // so the child's death is EOF for us
    let channel = RdpHelperChannel(fd: fds[0])
    let initialActive = lock.withLock { () -> Bool in
      self.channel = channel
      return appActive && clipboardFocused
    }
    channel.send(startMessage)
    channel.send(.clipboardActive(initialActive))
    if !initialActive {
      channel.send(.cancelClipboardFiles)
    }
    observeAppActivity()

    let thread = Thread { [self] in readLoop(channel) }
    thread.name = "mrw.rdp.helper"
    thread.start()
  }

  private func readLoop(_ channel: RdpHelperChannel) {
    defer {
      DispatchQueue.main.async { [clipboardDirectory] in
      let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
      if !urls.isEmpty, urls.allSatisfy({ $0.resolvingSymlinksInPath().path.hasPrefix(clipboardDirectory.resolvingSymlinksInPath().path + "/") }) {
        NSPasteboard.general.clearContents()
      }
      }
      try? FileManager.default.removeItem(at: clipboardDirectory)
      finished.signal()
    }
    while let message = try? channel.receive() {
      switch message {
      case .certificate(let host, let port, let sha, let subject, let issuer, let changed):
        callbacks.onCertificate(
          RdpCertificateRecord(host: host, port: port, sha256Fingerprint: sha, subjectCN: subject, issuerCN: issuer),
          changed)
      case .connected:
        lock.withLock { connected = true }
        callbacks.onConnected()
        pushClipboardActive()
      case .clipboardStatus(let message, let busy):
        callbacks.onClipboardStatus?(message, busy)
      case .frame(let w, let h, let bpr, let data):
        callbacks.onFrame(RdpFramebuffer(width: w, height: h, bytesPerRow: bpr, pixelFormat: .bgra8Unorm, data: data))
      case .ended(let code, let text, let wasConnected):
        lock.withLock { ended = true }
        callbacks.onEnded(code, text, wasConnected)
        channel.close()
        process.waitUntilExit()
        return
      default:
        break  // app->helper messages are never valid here
      }
    }
    // EOF or protocol violation without `ended`: treat as crash.
    channel.close()
    process.terminate()
    process.waitUntilExit()
    let (wasEnded, wasConnected) = lock.withLock { (ended, connected) }
    if !wasEnded { callbacks.onCrash(wasConnected) }
  }

  private func observeAppActivity() {
    let nc = NotificationCenter.default
    observers = [
      nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
        self?.setAppActive(true)
      },
      nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil) { [weak self] _ in
        self?.setAppActive(false)
      },
    ]
    DispatchQueue.main.async { [weak self] in self?.setAppActive(NSApp?.isActive ?? false) }
  }

  private func setAppActive(_ active: Bool) {
    lock.withLock { appActive = active }
    pushClipboardActive()
  }

  private func pushClipboardActive() {
    send(.clipboardActive(lock.withLock { appActive && clipboardFocused }))
  }

  func setClipboardFocused(_ focused: Bool) {
    lock.withLock { clipboardFocused = focused }
    pushClipboardActive()
  }

  func cancelClipboardFiles() { send(.cancelClipboardFiles) }

  private func send(_ message: RdpHelperMessage) {
    lock.withLock { channel }?.send(message)
  }

  /// Credentials are sent only on acceptance, i.e. after the app's own trust decision.
  func sendTrust(_ credentials: RdpResolvedCredentials?) {
    if let c = credentials {
      send(.trustDecision(accepted: true, username: c.username, domain: c.domain, password: c.password))
    } else {
      send(.trustDecision(accepted: false, username: nil, domain: nil, password: nil))
    }
  }

  func sendKey(_ e: RdpKeyboardEvent) {
    send(.key(scancode: e.scancode, isExtended: e.isExtended, isKeyUp: e.isKeyUp))
  }

  func sendPointer(x: UInt16, y: UInt16, buttonFlags: UInt16) {
    send(.pointer(x: x, y: y, buttonFlags: buttonFlags))
  }

  func resize(_ r: RdpDisplayResolution) {
    send(.resize(width: r.width, height: r.height, scaleFactor: r.scaleFactor))
  }

  /// Asks the helper to stop; hard-kills it if it has not exited within 5 s.
  func abort() {
    send(.abort)
    let process = process
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
  }

  /// Returns false on timeout.
  func waitUntilFinished(timeout: TimeInterval) -> Bool {
    if finished.wait(timeout: .now() + timeout) == .success {
      finished.signal()
      return true
    }
    return false
  }
}
