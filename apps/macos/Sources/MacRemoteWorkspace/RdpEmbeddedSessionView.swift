import AppCore
import SwiftUI

/// Embedded native RDP session viewer with Metal rendering, host certificate verification,
/// floating session toolbar, and crash recovery (US-021, FR-021).
public struct RdpEmbeddedSessionView: View {
  @Environment(\.dismiss) private var dismiss

  let host: HostRecord
  let session: NativeRdpSession
  let renderer: RdpMetalRenderer
  /// Creates a fresh session for the host; a finished session cannot be reused. When nil, no Reconnect action is offered.
  let onReconnect: (() -> Void)?

  @StateObject private var model: RdpEmbeddedSessionModel

  private var isConnected: Bool { model.state == .connected }
  private var canReconnect: Bool {
    guard onReconnect != nil else { return false }
    switch model.state {
    case .failed, .disconnected: return true
    default: return false
    }
  }

  public init(
    host: HostRecord,
    session: NativeRdpSession,
    renderer: RdpMetalRenderer = RdpMetalRenderer(),
    onReconnect: (() -> Void)? = nil
  ) {
    self.host = host
    self.session = session
    self.renderer = renderer
    self.onReconnect = onReconnect
    _model = StateObject(wrappedValue: RdpEmbeddedSessionModel(session: session, renderer: renderer))
  }

  public var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      // Metal Rendering View
      RdpMetalView(
        renderer: renderer,
        frameRevision: model.frameRevision,
        onResize: { resolution in
          model.updateResolution(resolution)
        },
        // The AppKit view stays first responder, so input must be gated here, not only by hit testing.
        onKeyEvent: { event in
          guard session.state == .connected else { return }
          session.sendKeyEvent(event)
        },
        onPointerEvent: { x, y, flags in
          guard session.state == .connected else { return }
          session.sendPointerEvent(x: x, y: y, buttonFlags: flags)
        },
        onClipboardFocus: { session.setClipboardFocused($0) }
      )
      .ignoresSafeArea()
      .allowsHitTesting(isConnected)

      if !isConnected {
        Color.black.opacity(0.55).ignoresSafeArea()
      }

      if let error = model.renderError {
        rendererFailureOverlay(error)
      }

      // Floating Session Toolbar
      VStack {
        ScrollView(.horizontal) {
          floatingToolbar
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 12)
        Spacer()
        if let message = model.clipboardStatus, isConnected {
          RdpClipboardStatusView(message: message, busy: model.clipboardBusy) {
            session.cancelClipboardFiles()
          }
          .padding(16)
        }
      }

      // State Overlays
      switch model.state {
      case .idle, .resolving, .connecting, .authenticating:
        if model.renderError == nil { connectingOverlay }

      case .verifyingCertificate(let challenge):
        certificateTrustSheet(challenge: challenge)

      case .disconnected(let reason):
        if reason == .helperCrashed {
          helperCrashedBanner
        } else if reason == .certificateRejected {
          certificateRejectedBanner
        } else {
          disconnectedBanner(reason: reason)
        }

      case .failed(let error):
        errorOverlay(error: error)

      case .interrupted:
        statusOverlay(AppLocalization.string("Connection interrupted. Trying to recover…"))

      case .disconnecting:
        statusOverlay(AppLocalization.string("Disconnecting…"))

      case .connected:
        if !model.hasReceivedFrame { firstFrameOverlay }
      }
    }
    .background(WindowCloseGuard {
      switch model.state {
      case .idle, .disconnected, .failed: return true
      default:
        let alert = NSAlert()
        alert.messageText = AppLocalization.string("Close and disconnect?")
        alert.addButton(withTitle: AppLocalization.string("Keep Session"))
        alert.addButton(withTitle: AppLocalization.string("Disconnect and Close"))
        return alert.runModal() == .alertSecondButtonReturn
      }
    })
    .frame(minWidth: 800, minHeight: 600)
    .navigationTitle(AppLocalization.format("Remote Desktop — %1$@", String(describing: host.displayName)))
    .onAppear { model.start() }
    .onDisappear { model.stop() }
  }

  // MARK: - Floating Toolbar

  private var floatingToolbar: some View {
    HStack(spacing: 12) {
      Label(host.displayName, systemImage: "display")
        .font(.callout.bold())
        .foregroundStyle(.primary)

      EnvironmentBadge(environment: host.environment)

      Divider()
        .frame(height: 16)

      Button {
        for event in RdpScancodeMapper.ctrlAltDelSequence() {
          session.sendKeyEvent(event)
        }
      } label: {
        Label(AppLocalization.string("Send Ctrl+Alt+Del"), systemImage: "keyboard")
      }
      .buttonStyle(.borderless)
      .disabled(!isConnected)
      .accessibilityLabel(AppLocalization.string("Send Ctrl+Alt+Del"))

      Button {
        NSApp.keyWindow?.toggleFullScreen(nil)
      } label: {
        Label(AppLocalization.string("Full Screen"), systemImage: "arrow.up.left.and.arrow.down.right")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(AppLocalization.string("Toggle Full Screen"))

      if onReconnect != nil {
        Button {
          onReconnect?()
        } label: {
          Label(AppLocalization.string("Reconnect"), systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .disabled(!canReconnect)
        .accessibilityLabel(AppLocalization.string("Reconnect with a new session"))
      }

      Button(role: .destructive) {
        dismiss()
      } label: {
        Label(AppLocalization.string("Disconnect"), systemImage: "xmark.circle")
      }
      .buttonStyle(.borderless)
      .tint(.red)
      .accessibilityLabel(AppLocalization.string("Disconnect and close"))
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .buttonStyle(.borderless)
    .modifier(WorkspaceChrome())
    .padding(.horizontal, 16)
  }

  // MARK: - State Overlays

  private var connectingOverlay: some View {
    VStack(spacing: 16) {
      ProgressView()
        .controlSize(.large)
      Text(connectingStatusText)
        .font(.headline)
    }
    .padding(32)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 16))
  }

  private var firstFrameOverlay: some View {
    VStack(spacing: 14) {
      if !model.firstFrameTimedOut { ProgressView().controlSize(.large) }
      Text(model.firstFrameTimedOut ? AppLocalization.string("Connected, but no desktop frame has arrived.") : AppLocalization.string("Connected. Waiting for the desktop frame…"))
        .font(.headline)
      if model.firstFrameTimedOut, onReconnect != nil {
        Button(AppLocalization.string("Reconnect")) { onReconnect?() }.buttonStyle(WorkspacePrimaryButtonStyle())
      }
      Text(AppLocalization.string("The session remains open while the server starts its desktop."))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(28)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 16))
    .accessibilityElement(children: .contain)
  }

  private func rendererFailureOverlay(_ message: String) -> some View {
    VStack(spacing: 16) {
      Image(systemName: "display.trianglebadge.exclamationmark")
        .font(.largeTitle)
        .foregroundStyle(.red)
      Text(AppLocalization.string("Remote Desktop Display Failed")).font(.title2.bold())
      Text(message).multilineTextAlignment(.center).font(.subheadline)
      HStack {
        Button(AppLocalization.string("Close")) { dismiss() }
        if onReconnect != nil {
          Button(AppLocalization.string("Reconnect")) { onReconnect?() }.buttonStyle(WorkspacePrimaryButtonStyle())
        }
      }
    }
    .padding(28)
    .frame(maxWidth: 480)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 16))
  }

  private func statusOverlay(_ text: String) -> some View {
    VStack(spacing: 16) {
      ProgressView().controlSize(.large)
      Text(text).font(.headline)
    }
    .padding(32)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 16))
    .accessibilityElement(children: .combine)
  }

  private var connectingStatusText: String {
    switch model.state {
    case .resolving: return AppLocalization.string("Resolving host…")
    case .connecting: return AppLocalization.string("Connecting to Windows desktop…")
    case .authenticating: return AppLocalization.string("Signing in…")
    default: return AppLocalization.string("Connecting…")
    }
  }

  private func certificateTrustSheet(challenge: RdpCertificateTrustChallenge) -> some View {
    VStack(spacing: 20) {
      HStack(spacing: 12) {
        Image(systemName: "lock.shield.fill")
          .font(.largeTitle)
          .foregroundStyle(.yellow)
        VStack(alignment: .leading, spacing: 4) {
          Text(AppLocalization.string("Verify Windows Server Identity"))
            .font(.title2.bold())
          Text(AppLocalization.string("First connection to this server. Compare the fingerprint with your administrator before trusting."))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }

      VStack(alignment: .leading, spacing: 12) {
        LabeledContent(AppLocalization.string("Target Host"), value: "\(challenge.host):\(challenge.port)")
        LabeledContent(AppLocalization.string("Common Name (CN)"), value: challenge.presentedCertificate.subjectCN)
        LabeledContent(AppLocalization.string("Issuer"), value: challenge.presentedCertificate.issuerCN)

        VStack(alignment: .leading, spacing: 6) {
          Text(AppLocalization.string("SHA-256 fingerprint"))
            .font(.caption.bold())
            .foregroundStyle(.secondary)
          Text(groupedFingerprint(challenge.presentedCertificate.formattedFingerprint))
            .font(.system(.body, design: .monospaced))
            .accessibilityLabel(AppLocalization.format("SHA-256 fingerprint %1$@", String(describing: challenge.presentedCertificate.formattedFingerprint.replacingOccurrences(of: ":", with: " "))))
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
      }
      .padding()
      .background(Color(.windowBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 10))

      HStack(spacing: 16) {
        // Reject is the safe default (Esc); trusting needs an explicit click, never Return.
        Button(AppLocalization.string("Reject & Disconnect"), role: .cancel) {
          session.rejectCertificate()
        }
        .buttonStyle(WorkspacePrimaryButtonStyle())
        .keyboardShortcut(.cancelAction)

        Button(AppLocalization.string("Trust & Connect")) {
          Task {
            do {
              try await session.confirmTrustAndAuthenticate()
            } catch let error as RdpSessionError {
              model.fail(error)
            } catch {
              model.fail(.protocolViolation(error.localizedDescription))
            }
          }
        }
        .buttonStyle(WorkspaceSecondaryButtonStyle())
      }
    }
    .padding(24)
    .frame(maxWidth: 520)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 16))
    .shadow(radius: 20)
  }

  /// Groups "AA:BB:..." into lines of 8 pairs.
  private func groupedFingerprint(_ formatted: String) -> String {
    let pairs = formatted.split(separator: ":").map(String.init)
    return stride(from: 0, to: pairs.count, by: 8)
      .map { pairs[$0..<min($0 + 8, pairs.count)].joined(separator: ":") }
      .joined(separator: "\n")
  }

  private var helperCrashedBanner: some View {
    VStack(spacing: 16) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.largeTitle)
        .foregroundStyle(.orange)
      Text(AppLocalization.string("Remote Desktop Stopped"))
        .font(.title2.bold())
      Text(AppLocalization.string("The remote desktop engine stopped unexpectedly. Your app is fine — reconnect to continue."))
        .multilineTextAlignment(.center)
        .font(.subheadline)
        .foregroundStyle(.secondary)

      HStack(spacing: 12) {
        Button(AppLocalization.string("Close")) {
          dismiss()
        }
        if onReconnect != nil {
          Button(AppLocalization.string("Reconnect")) { onReconnect?() }
            .buttonStyle(WorkspacePrimaryButtonStyle())
        }
      }
    }
    .padding(28)
    .frame(maxWidth: 480)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 16))
    .shadow(radius: 16)
  }

  private var certificateRejectedBanner: some View {
    VStack(spacing: 16) {
      Image(systemName: "xmark.shield.fill")
        .font(.largeTitle)
        .foregroundStyle(.red)
      Text(AppLocalization.string("Connection Cancelled"))
        .font(.title2.bold())
      Text(AppLocalization.string("You rejected the server's certificate, so no credentials were sent."))
        .multilineTextAlignment(.center)
        .font(.subheadline)
        .foregroundStyle(.secondary)

      Button(AppLocalization.string("Close")) {
        dismiss()
      }
      .buttonStyle(WorkspacePrimaryButtonStyle())
    }
    .padding(28)
    .frame(maxWidth: 440)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 16))
  }

  private func disconnectedBanner(reason: RdpDisconnectReason) -> some View {
    VStack(spacing: 16) {
      Image(systemName: "power")
        .font(.largeTitle)
        .foregroundStyle(.secondary)
      Text(AppLocalization.string("Session Disconnected"))
        .font(.title2.bold())
      Button(AppLocalization.string("Close")) {
        dismiss()
      }
      .buttonStyle(WorkspacePrimaryButtonStyle())
    }
    .padding(24)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 14))
  }

  private func errorOverlay(error: RdpSessionError) -> some View {
    VStack(spacing: 16) {
      Image(systemName: "xmark.circle.fill")
        .font(.largeTitle)
        .foregroundStyle(.red)
      Text(AppLocalization.string("Connection Failed"))
        .font(.title2.bold())
      Text(error.localizedDescription)
        .multilineTextAlignment(.center)
        .font(.subheadline)
        .foregroundStyle(.secondary)

      HStack(spacing: 12) {
        Button(AppLocalization.string("Close")) {
          dismiss()
        }
        if onReconnect != nil {
          Button(AppLocalization.string("Retry")) { onReconnect?() }
            .buttonStyle(WorkspacePrimaryButtonStyle())
        }
      }
    }
    .padding(28)
    .frame(maxWidth: 460)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 16))
  }
}

@MainActor
private final class RdpEmbeddedSessionModel: ObservableObject {
  @Published private(set) var state: NativeRdpSessionState = .idle
  @Published private(set) var hasReceivedFrame = false
  @Published private(set) var firstFrameTimedOut = false
  @Published private(set) var renderError: String?
  @Published private(set) var clipboardStatus: String?
  @Published private(set) var clipboardBusy = false
  @Published private(set) var frameRevision: UInt64 = 0

  private let session: NativeRdpSession
  private let renderer: RdpMetalRenderer
  private let uploader: RdpFrameUploader
  private var started = false
  private var stopped = false
  private var firstFrameTimeout: Task<Void, Never>?
  private var requestedResolution: RdpDisplayResolution?

  init(session: NativeRdpSession, renderer: RdpMetalRenderer) {
    self.session = session
    self.renderer = renderer
    self.uploader = RdpFrameUploader(renderer: renderer)
  }

  func start() {
    guard !started else { return }
    started = true
    if let error = renderer.availabilityError {
      renderError = error.localizedDescription
      return
    }

    session.onClipboardStatus = { [weak self] message, busy in
      Task { @MainActor [weak self] in
        guard let self, !self.stopped else { return }
        self.clipboardStatus = message
        self.clipboardBusy = busy
      }
    }
    session.onStateChange = { [weak self] state in
      Task { @MainActor [weak self] in self?.update(state) }
    }
    let uploader = uploader
    let onFrameUploaded: @Sendable (String?) -> Void = { [weak model = self] error in
      Task { @MainActor [weak model] in model?.frameUploaded(error: error) }
    }
    session.onFrameReady = { [uploader, onFrameUploaded] frame in
      uploader.upload(frame, onUpdate: onFrameUploaded)
    }
    Task {
      do {
        try await session.connect()
      } catch let error as RdpSessionError {
        fail(error)
      } catch {
        fail(.protocolViolation(error.localizedDescription))
      }
    }
  }

  func stop() {
    guard !stopped else { return }
    stopped = true
    firstFrameTimeout?.cancel()
    session.onStateChange = nil
    session.onFrameReady = nil
    session.onClipboardStatus = nil
    session.setClipboardFocused(false)
    uploader.clear()
    Task { await session.disconnect() }
  }

  func fail(_ error: RdpSessionError) {
    guard !stopped else { return }
    state = .failed(error: error)
  }

  func updateResolution(_ resolution: RdpDisplayResolution) {
    requestedResolution = resolution
    if state == .connected { session.updateResolution(resolution) }
  }

  private func update(_ state: NativeRdpSessionState) {
    guard !stopped else { return }
    self.state = state
    if state == .connected, let requestedResolution {
      session.updateResolution(requestedResolution)
    }
    guard state == .connected, !hasReceivedFrame else {
      firstFrameTimeout?.cancel()
      firstFrameTimedOut = false
      return
    }
    firstFrameTimeout?.cancel()
    firstFrameTimeout = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 15_000_000_000)
      guard !Task.isCancelled, let self, !self.stopped,
        self.state == .connected, !self.hasReceivedFrame
      else { return }
      self.firstFrameTimedOut = true
    }
  }

  private func frameUploaded(error: String?) {
    guard !stopped else { return }
    if let error {
      renderError = error
    } else {
      hasReceivedFrame = true
      firstFrameTimedOut = false
      firstFrameTimeout?.cancel()
      frameRevision &+= 1
      renderError = nil
    }
  }
}

private final class RdpFrameUploader: @unchecked Sendable {
  private let renderer: RdpMetalRenderer
  private let lock = NSLock()
  private var active = true
  private var notificationPending = false

  init(renderer: RdpMetalRenderer) { self.renderer = renderer }

  func upload(_ frame: RdpFramebuffer, onUpdate: @escaping @Sendable (String?) -> Void) {
    let update = lock.withLock { () -> (Bool, String?) in
      guard active else { return (false, nil) }
      var failure: String?
      do {
        try renderer.uploadFrame(frame)
      } catch {
        failure = error.localizedDescription
      }
      guard !notificationPending else { return (false, nil) }
      notificationPending = true
      return (true, failure)
    }
    guard update.0 else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.lock.withLock { self.notificationPending = false }
      onUpdate(update.1)
    }
  }

  func clear() {
    lock.withLock {
      active = false
      renderer.clear()
    }
  }
}
