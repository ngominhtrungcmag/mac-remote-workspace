import AppCore
import SwiftUI

/// Sheet providing interactive terminal view, honest connection state, host trust verification dialogs, and lifecycle controls.
struct SSHSessionSheet: View {
  @Environment(\.dismiss) private var dismiss
  @StateObject private var viewModel: SSHSessionViewModel
  private let group: HostGroupRecord?
  private let embedded: Bool
  private let connectOnOpenToken: Int
  @State private var didPrepareConnection = false
  @State private var openLifecycle = SSHSessionOpenLifecycle()
  @State private var hasSavedSettings = false
  @State private var canAutoConnect = false
  private let onRunningChange: ((Bool) -> Void)?
  private let onLiveChange: ((Bool) -> Void)?
  private let onActiveChange: ((Bool) -> Void)?
  private let onUsernameChange: ((String) -> Void)?

  @State private var form = SSHConnectionFormState()
  @State private var confirmingRotation = false
  @State private var localPortString = "5432"
  @State private var tunnelRemoteHost = "127.0.0.1"
  @State private var tunnelRemotePortString = "5432"
  @State private var tunnelValidationError: String?
  @State private var isDiagnosingConnection = false
  @State private var diagnosticsReport: SSHConnectionDiagnosticReport?
  @State private var credentialRepository: SQLiteHostRepository?
  @State private var snippetRepository: SQLiteHostRepository?
  @State private var isShowingCommandSnippets = false
  @State private var snippetStorageError: String?
  @State private var showConnectionSettings = false
  @State private var confirmClose = false

  init(
    host: HostRecord,
    group: HostGroupRecord? = nil,
    embedded: Bool = false,
    connectOnOpen: Bool = false,
    connectOnOpenToken: Int? = nil,
    onUsernameChange: ((String) -> Void)? = nil,
    onLiveChange: ((Bool) -> Void)? = nil,
    onActiveChange: ((Bool) -> Void)? = nil,
    onRunningChange: ((Bool) -> Void)? = nil
  ) {
    self.embedded = embedded
    self.connectOnOpenToken = connectOnOpenToken ?? (connectOnOpen ? 1 : 0)
    self.onRunningChange = onRunningChange
    self.onUsernameChange = onUsernameChange
    self.onLiveChange = onLiveChange
    self.onActiveChange = onActiveChange
    self.group = group?.id == host.groupID ? group : nil
    _viewModel = StateObject(wrappedValue: SSHSessionViewModel(host: host))
  }

  private var parsedPort: Int? {
    guard let port = Int(form.portString), (1...65535).contains(port) else {
      return nil
    }
    return port
  }

  private var isPortValid: Bool {
    parsedPort != nil
  }

  private var parsedJumpPort: Int? {
    guard let port = Int(form.jumpPortString), (1...65535).contains(port) else { return nil }
    return port
  }

  private var isUsernameValid: Bool {
    let trimmed = form.username.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && !trimmed.hasPrefix("-")
  }

  var body: some View {
    if embedded {
      sessionContent
    } else {
      NavigationStack {
        sessionContent
          .navigationTitle(AppLocalization.format("SSH: %1$@", String(describing: viewModel.host.displayName)))
          .interactiveDismissDisabled(isRunning)
          .confirmationDialog(AppLocalization.string("Disconnect and close?"), isPresented: $confirmClose) {
            Button(AppLocalization.string("Disconnect and Close"), role: .destructive) {
              viewModel.disconnect()
              dismiss()
            }
            Button(AppLocalization.string("Keep Session"), role: .cancel) {}
          } message: {
            Text(AppLocalization.format("The running SSH session to %1$@ will end.", String(describing: viewModel.host.displayName)))
          }
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button(AppLocalization.string("Close")) {
                if isRunning { confirmClose = true } else { dismiss() }
              }
            }
            ToolbarItem(placement: .primaryAction) { snippetsButton }
          }
      }
    }
  }

  private var snippetsButton: some View {
    Button(AppLocalization.string("Snippets"), systemImage: "text.alignleft", action: openCommandSnippets)
      .help(AppLocalization.string("Manage host and group command snippets"))
      .accessibilityLabel(AppLocalization.format("Command snippets for %1$@", String(describing: viewModel.host.displayName)))
      .disabled(isShowingCommandSnippets)
  }

  private var sessionContent: some View {
      VStack(spacing: 0) {
        // Environment warning banner
        if viewModel.host.environment == .production {
          productionWarningBanner
        }

        // Configuration bar (collapsed once connected)
        if hasSavedSettings && !showConnectionSettings && !shouldShowConnectionForm {
          HStack {
            Text("\(form.username)@\(viewModel.host.address):\(form.portString)")
              .font(.system(.subheadline, design: .monospaced))
            Text(authenticationTitle)
              .foregroundStyle(.secondary)
            Spacer()
            Button(AppLocalization.string("Edit")) { showConnectionSettings = true }
            connectActionButton
          }
          .padding(12)
          .background(.bar)
        } else {
          ViewThatFits(in: .vertical) {
            ConnectionFormView(form: form, isConnectionConfigurationLocked: isConnectionConfigurationLocked, isDiagnosingConnection: isDiagnosingConnection, performDiagnostics: performDiagnostics) { connectActionButton }
            ScrollView {
              ConnectionFormView(form: form, isConnectionConfigurationLocked: isConnectionConfigurationLocked, isDiagnosingConnection: isDiagnosingConnection, performDiagnostics: performDiagnostics) { connectActionButton }
            }
            .frame(maxHeight: 280)
          }
        }
        if isDiagnosingConnection || diagnosticsReport != nil {
          SSHConnectionDiagnosticsPanel(isRunning: isDiagnosingConnection, report: diagnosticsReport)
        }
        Divider()

        // Status header
        SessionStatusBar(viewModel: viewModel, username: form.username, portString: form.portString, isAuthRejectionOutput: isAuthRejectionOutput)
        Divider()

        if isRunning || !viewModel.localTunnels.isEmpty {
          TunnelPanelView(viewModel: viewModel, isRunning: isRunning, localPortString: $localPortString, tunnelRemoteHost: $tunnelRemoteHost, tunnelRemotePortString: $tunnelRemotePortString, tunnelValidationError: $tunnelValidationError)
          Divider()
        }

        // Main content area: host trust challenge, host key mismatch, or terminal
        mainContentView
        Divider()

        if embedded { snippetsButton.padding(10) }
      }
      .frame(minWidth: 700, minHeight: 540)
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
        viewModel.terminateSync()
      }
      .onChange(of: form.username, initial: true) { _, value in onUsernameChange?(value) }
      .onChange(of: viewModel.status) { _, _ in
        let running = isRunning
        if running { showConnectionSettings = false }
        onRunningChange?(running)
        onLiveChange?(viewModel.hasLiveSession)
        onActiveChange?(isActiveAttempt)
      }
      .onChange(of: viewModel.newlySavedCredential) { _, newRecord in
        if let newRecord {
          loadCredentialRefs()
          form.selectedCredentialID = newRecord.id
        }
      }
      .onDisappear {
        form.password = ""
        viewModel.disconnect()
        closeSnippetRepository()
        closeCredentialRepository()
      }
      .sheet(isPresented: $isShowingCommandSnippets, onDismiss: closeSnippetRepository) {
        if let repository = snippetRepository {
          CommandSnippetsSheet(
            host: viewModel.host,
            group: group,
            repository: repository,
            isSessionActive: { isSessionRunning },
            sendToSession: { viewModel.send($0) }
          )
        } else {
          ContentUnavailableView(
            AppLocalization.string("Snippets unavailable"),
            systemImage: "exclamationmark.triangle",
            description: Text(AppLocalization.string("The local snippet database could not be opened."))
          )
          .frame(minWidth: 480, minHeight: 240)
        }
      }
      .alert(AppLocalization.string("Command snippets unavailable"), isPresented: snippetStorageErrorPresented) {
        Button(AppLocalization.string("OK"), role: .cancel) { snippetStorageError = nil }
      } message: {
        Text(snippetStorageError ?? AppLocalization.string("The snippet store could not be opened."))
      }
      .onChange(of: form.portString) { _, _ in
        diagnosticsReport = nil
      }
      .onChange(of: form.proxyJumpEnabled) { _, _ in
        diagnosticsReport = nil
      }
      .onChange(of: form.jumpHost) { _, _ in
        diagnosticsReport = nil
      }
      .onChange(of: form.jumpPortString) { _, _ in
        diagnosticsReport = nil
      }
      .onChange(of: form.authenticationMode) { _, newMode in
        form.validationError = nil
        if newMode == .keychainCredential && form.credentialRefs.isEmpty {
          loadCredentialRefs()
        }
      }
      .task(id: connectOnOpenToken) {
        if !didPrepareConnection {
          didPrepareConnection = true
          applyPreset()
          loadCredentialRefs()
        }
        if openLifecycle.consume(requestToken: connectOnOpenToken, status: viewModel.status), canAutoConnect,
           (form.authenticationMode != .keychainCredential || form.credentialRefs.contains(where: { $0.id == form.selectedCredentialID })) {
          performConnect()
        }
      }
  }

  // MARK: - Subviews

  @ViewBuilder
  private var productionWarningBanner: some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.yellow)
      Text(AppLocalization.string("Caution: You are connecting to a PRODUCTION environment host. All remote terminal actions directly affect production systems."))
        .font(.caption)
        .bold()
      Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color.yellow.opacity(0.15))
    .overlay(
      Rectangle()
        .frame(height: 1)
        .foregroundStyle(.yellow.opacity(0.3)),
      alignment: .bottom
    )
  }

  @ViewBuilder
  private var connectActionButton: some View {
    if viewModel.status == .idle {
      Button(AppLocalization.string("Connect")) { performConnect() }
        .buttonStyle(WorkspacePrimaryButtonStyle())
        .disabled(isDiagnosingConnection)
    } else if case .disconnected(let exitCode) = viewModel.status {
      let isAuthFailure = exitCode == 255 && isAuthRejectionOutput
      Button(isAuthFailure ? AppLocalization.string("Retry") : AppLocalization.string("Reconnect")) { performConnect() }
        .buttonStyle(WorkspacePrimaryButtonStyle())
        .disabled(isDiagnosingConnection)
    } else if case .failed = viewModel.status {
      Button(AppLocalization.string("Retry")) { performConnect() }
        .buttonStyle(WorkspacePrimaryButtonStyle())
        .disabled(isDiagnosingConnection)
    } else if isVerifying || isConnecting {
      Button(AppLocalization.string("Cancel")) { viewModel.disconnect() }
        .buttonStyle(WorkspaceSecondaryButtonStyle())
    } else if isRunning {
      Button(AppLocalization.string("Disconnect")) { viewModel.disconnect() }
        .buttonStyle(WorkspaceSecondaryButtonStyle())
    }
  }

  private var isAuthRejectionOutput: Bool {
    viewModel.terminalOutput.localizedCaseInsensitiveContains("Permission denied") ||
    viewModel.terminalOutput.localizedCaseInsensitiveContains("Authentication failed")
  }

  private func performConnect() {
    diagnosticsReport = nil
    guard isUsernameValid else {
      form.validationError = AppLocalization.string("Username is required and cannot start with '-'")
      return
    }
    guard let port = parsedPort else {
      form.validationError = AppLocalization.string("Port must be a valid integer between 1 and 65535")
      return
    }
    let jump: NativeSSHProxyJumpEndpoint?
    if form.proxyJumpEnabled {
      let trimmedJumpHost = form.jumpHost.trimmingCharacters(in: .whitespacesAndNewlines)
      let trimmedJumpUsername = form.jumpUsername.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedJumpHost.isEmpty else {
        form.validationError = AppLocalization.string("Jump host is required when ProxyJump is enabled.")
        return
      }
      guard !trimmedJumpUsername.isEmpty, !trimmedJumpUsername.hasPrefix("-") else {
        form.validationError = AppLocalization.string("Jump user is required and cannot start with '-'.")
        return
      }
      guard let jumpPort = parsedJumpPort else {
        form.validationError = AppLocalization.string("Jump port must be between 1 and 65535.")
        return
      }
      jump = NativeSSHProxyJumpEndpoint(
        host: trimmedJumpHost,
        port: jumpPort,
        username: trimmedJumpUsername
      )
    } else {
      jump = nil
    }
    form.validationError = nil
    let authenticationChoice: SSHSessionViewModel.AuthenticationChoice
    switch form.authenticationMode {
    case .password:
      guard !form.password.isEmpty else {
        form.validationError = AppLocalization.string("Password cannot be empty")
        return
      }
      let secret = ProtectedSecret(data: Data(form.password.utf8))
      let trimmedLabel = form.passwordCredentialLabel.trimmingCharacters(in: .whitespacesAndNewlines)
      authenticationChoice = .password(
        secret: secret,
        saveToKeychain: form.savePasswordToKeychain,
        label: trimmedLabel.isEmpty ? nil : trimmedLabel
      )
    case .keychainCredential:
      guard let selectedCredentialID = form.selectedCredentialID,
        let record = form.credentialRefs.first(where: { $0.id == selectedCredentialID }) else {
        form.validationError = AppLocalization.string("Choose a saved Keychain credential, or manage credentials in Security → Credentials.")
        return
      }
      let trimmedKeyPath = form.credentialKeyFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
      let identityFileURL: URL? =
        trimmedKeyPath.isEmpty
        ? nil
        : URL(fileURLWithPath: (trimmedKeyPath as NSString).expandingTildeInPath)
      authenticationChoice = .keychainCredential(reference: record, identityFileURL: identityFileURL)
    case .sshAgent:
      authenticationChoice = .sshAgent
    }
    viewModel.connect(
      username: form.username.trimmingCharacters(in: .whitespacesAndNewlines),
      port: port,
      authentication: authenticationChoice,
      proxyJump: jump
    )
  }

  private func performDiagnostics() {
    let host: String
    let port: Int
    if form.proxyJumpEnabled {
      let trimmedJumpHost = form.jumpHost.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedJumpHost.isEmpty else {
        form.validationError = AppLocalization.string("Jump host is required when ProxyJump is enabled.")
        return
      }
      guard let jumpPort = parsedJumpPort else {
        form.validationError = AppLocalization.string("Jump port must be between 1 and 65535.")
        return
      }
      host = trimmedJumpHost
      port = jumpPort
    } else {
      guard let targetPort = parsedPort else {
        form.validationError = AppLocalization.string("Port must be a valid integer between 1 and 65535")
        return
      }
      host = viewModel.host.address
      port = targetPort
    }
    form.validationError = nil
    diagnosticsReport = nil
    isDiagnosingConnection = true
    Task {
      let report = await Task.detached(priority: .userInitiated) {
        SSHConnectionDiagnosticProbe.run(host: host, port: port)
      }.value
      diagnosticsReport = report
      isDiagnosingConnection = false
    }
  }

  private var isSessionRunning: Bool {
    if case .running = viewModel.status { return true }
    return false
  }

  private var snippetStorageErrorPresented: Binding<Bool> {
    Binding(
      get: { snippetStorageError != nil },
      set: { if !$0 { snippetStorageError = nil } }
    )
  }

  private func openCommandSnippets() {
    do {
      snippetRepository = try SQLiteHostRepository.openApplicationRepository()
      isShowingCommandSnippets = true
    } catch {
      snippetRepository = nil
      snippetStorageError = error.localizedDescription
    }
  }

  private func closeSnippetRepository() {
    guard let repository = snippetRepository else { return }
    snippetRepository = nil
    do {
      try repository.close()
    } catch {
      snippetStorageError = error.localizedDescription
    }
  }

  // MARK: - Credential Metadata (US-005)

  private var authenticationTitle: String {
    switch form.authenticationMode {
    case .password: AppLocalization.string("Password")
    case .keychainCredential: AppLocalization.string("Keychain credential")
    case .sshAgent: AppLocalization.string("SSH agent")
    }
  }

  private var shouldShowConnectionForm: Bool {
    if form.validationError != nil { return true }
    if viewModel.status == .idle && (connectOnOpenToken <= 0 || !canAutoConnect ||
      (form.authenticationMode == .keychainCredential && !form.credentialRefs.contains(where: { $0.id == form.selectedCredentialID }))) { return true }
    switch viewModel.status {
    case .failed, .disconnected: return true
    default: return false
    }
  }

  private func applyPreset() {
    let saved: SSHConnectionSettings?
    do {
      saved = try openCredentialRepository().sshConnectionSettings(hostID: viewModel.host.id)
    } catch {
      form.validationError = error.localizedDescription
      return
    }
    hasSavedSettings = saved != nil
    canAutoConnect = saved?.canConnectWithoutPrompt ?? false
    let preset = saved ?? SSHConnectionPreset()
    form.username = preset.username
    form.portString = String(preset.port)
    form.credentialKeyFilePath = preset.keyFilePath
    form.selectedCredentialID = preset.credentialID
    form.authenticationMode = switch preset.auth {
    case .password: .password
    case .keychainCredential: .keychainCredential
    case .sshAgent: .sshAgent
    }
    if let jump = preset.proxyJump {
      form.proxyJumpEnabled = true
      form.proxyJumpExpanded = true
      if let endpoint = SSHConnectionFormState.jumpComponents(jump, defaultUser: NSUserName()) {
        form.jumpHost = endpoint.host
        form.jumpUsername = endpoint.user
        form.jumpPortString = String(endpoint.port)
      } else {
        // Keep ProxyJump enabled so invalid saved data can never fall back to a direct connection.
        form.jumpHost = ""
      }
    }
  }

  private func loadCredentialRefs() {
    do {
      let repository = try openCredentialRepository()
      form.credentialRefs = try repository.listCredentialRefs()
      if form.selectedCredentialID == nil {
        form.selectedCredentialID = form.credentialRefs.first?.id
      }
    } catch {
      form.credentialRefs = []
      credentialRepository = nil
      if form.authenticationMode == .keychainCredential {
        form.validationError = AppLocalization.format("Credential metadata unavailable: %1$@", error.localizedDescription)
      }
    }
  }

  @discardableResult
  private func openCredentialRepository() throws -> SQLiteHostRepository {
    if let credentialRepository {
      return credentialRepository
    }
    let opened = try SQLiteHostRepository.openApplicationRepository()
    credentialRepository = opened
    return opened
  }

  private func closeCredentialRepository() {
    guard let repository = credentialRepository else { return }
    credentialRepository = nil
    do {
      try repository.close()
    } catch {
      snippetStorageError = error.localizedDescription
    }
  }

  // MARK: - Main Content Area

  @ViewBuilder
  private var mainContentView: some View {
    switch viewModel.status {
    case .hostTrustRequired(let challenge):
      HostTrustReviewView(viewModel: viewModel, challenge: challenge)
    case .hostKeyMismatch(let recordedKeys, let presentedKey):
      KeyMismatchView(viewModel: viewModel, recordedKeys: recordedKeys, presentedKey: presentedKey, confirmingRotation: $confirmingRotation)
    default:
      terminalArea
    }
  }

  // MARK: - Host Trust Review (US-006 / FR-006 / TC-004)

  // MARK: - Terminal Area

  private var terminalArea: some View {
    VStack(spacing: 0) {
      SSHTerminalView(viewModel: viewModel, isActive: isRunning)
    }
  }

  private var isVerifying: Bool {
    if case .verifyingHost = viewModel.status { return true }
    return false
  }

  private var isConnecting: Bool {
    if case .connecting = viewModel.status { return true }
    return false
  }

  private var isRunning: Bool {
    if case .running = viewModel.status { return true }
    return false
  }

  private var isActiveAttempt: Bool {
    switch viewModel.status {
    case .verifyingHost, .hostTrustRequired, .hostKeyMismatch, .connecting, .running:
      return true
    case .idle, .disconnected, .failed:
      return false
    }
  }

  private var isConnectionConfigurationLocked: Bool {
    isDiagnosingConnection || isActiveAttempt
  }



}

#if DEBUG
#Preview("SSHSessionSheet") {
  SSHSessionSheet(host: PreviewFixtures.host)
}
#endif

/// Each explicit Open request token is consumed once and only when no session or trust review is in flight.
struct SSHSessionOpenLifecycle {
  private(set) var lastHandledToken = 0

  mutating func consume(requestToken: Int, status: SSHSessionViewModel.SessionStatus) -> Bool {
    guard requestToken > lastHandledToken else { return false }
    lastHandledToken = requestToken
    switch status {
    case .idle, .disconnected, .failed:
      return true
    case .verifyingHost, .hostTrustRequired, .hostKeyMismatch, .connecting, .running:
      return false
    }
  }
}
