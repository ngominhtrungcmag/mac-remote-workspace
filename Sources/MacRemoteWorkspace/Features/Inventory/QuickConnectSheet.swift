import AppCore
import SwiftUI

/// Resolves Quick Connect presentation copy via `AppLocalization` so fallback English is used until S1-05 catalog sync.
func quickConnectText(_ key: String) -> String {
  AppLocalization.string(key)
}

/// Short-lived repository adapter that opens and closes `SQLiteHostRepository` on each operation.
/// Ensures Quick Connect RDP sessions never hold a leaked SQLite handle across session lifetime or reconnects,
/// while resolving fresh credential references and recording RDP host trust / audit events per session attempt.
final class QuickConnectRdpSessionResources: RdpHostTrustRepository, AuditRepository, @unchecked Sendable {
  private let openRepository: @Sendable () throws -> SQLiteHostRepository
  private let fallbackTrustRepository = InMemoryRdpHostTrustRepository()
  private let fallbackCredentialRefs: [CredentialRefRecord]

  init(
    fallbackCredentialRefs: [CredentialRefRecord] = [],
    openRepository: @escaping @Sendable () throws -> SQLiteHostRepository = {
      try SQLiteHostRepository.openApplicationRepository()
    }
  ) {
    self.fallbackCredentialRefs = fallbackCredentialRefs
    self.openRepository = openRepository
  }

  private func withRepository<T>(
    fallback: () throws -> T,
    _ body: (SQLiteHostRepository) throws -> T
  ) rethrows -> T {
    guard let repository = try? openRepository() else {
      return try fallback()
    }
    defer { try? repository.close() }
    return try body(repository)
  }

  func lookupCredentialRef(id: String) throws -> CredentialRefRecord? {
    try withRepository(fallback: { fallbackCredentialRefs.first { $0.id == id } }) { repository in
      try repository.listCredentialRefs().first { $0.id == id }
    }
  }

  func getRdpHostTrust(host: String, port: Int) throws -> RdpCertificateRecord? {
    try withRepository(fallback: { try fallbackTrustRepository.getRdpHostTrust(host: host, port: port) }) {
      try $0.getRdpHostTrust(host: host, port: port)
    }
  }

  func recordRdpHostTrust(record: RdpCertificateRecord) throws {
    try withRepository(fallback: { try fallbackTrustRepository.recordRdpHostTrust(record: record) }) {
      try $0.recordRdpHostTrust(record: record)
    }
  }

  func deleteRdpHostTrust(host: String, port: Int) throws {
    try withRepository(fallback: { try fallbackTrustRepository.deleteRdpHostTrust(host: host, port: port) }) {
      try $0.deleteRdpHostTrust(host: host, port: port)
    }
  }

  func listRdpHostTrust() throws -> [RdpCertificateRecord] {
    try withRepository(fallback: { try fallbackTrustRepository.listRdpHostTrust() }) {
      try $0.listRdpHostTrust()
    }
  }

  func recordAuditEvent(
    action: String,
    entityType: String,
    entityID: String?,
    outcome: AuditOutcome,
    errorCode: String?
  ) throws {
    try withRepository(fallback: {}) {
      try $0.recordAuditEvent(
        action: action,
        entityType: entityType,
        entityID: entityID,
        outcome: outcome,
        errorCode: errorCode
      )
    }
  }

  func listAuditEvents(limit: Int) throws -> [AuditEventRecord] {
    try withRepository(fallback: { [] }) {
      try $0.listAuditEvents(limit: limit)
    }
  }

  static func makeEmbeddedSessionFactory(
    target: QuickConnectTarget,
    username: String,
    credentialRefID: String,
    options: RdpConnectionOptions,
    fallbackCredentialRefs: [CredentialRefRecord] = [],
    keychainStore: CredentialSecretStore = KeychainCredentialStore(),
    openRepository: @escaping @Sendable () throws -> SQLiteHostRepository = {
      try SQLiteHostRepository.openApplicationRepository()
    }
  ) -> () -> NativeRdpSession {
    let resources = QuickConnectRdpSessionResources(
      fallbackCredentialRefs: fallbackCredentialRefs,
      openRepository: openRepository
    )
    return {
      let verifier = NativeRdpCertificateTrustService(repository: resources)
      let resolver = RdpCredentialResolver(
        keychainStore: keychainStore,
        credentialLookup: { id in try resources.lookupCredentialRef(id: id) }
      )
      return NativeRdpSession(
        configuration: RdpSessionConfiguration(
          host: target.host,
          port: target.port,
          username: username,
          credentialRefID: credentialRefID,
          sharedFolderPath: nil,
          options: options
        ),
        certificateVerifier: verifier,
        credentialResolver: resolver
      )
    }
  }
}

/// Ephemeral, process-local registry for Quick Connect SSH sessions.
/// Never persists to SQLite inventory, `session-layout.json`, or exports.
@MainActor
final class QuickConnectSessionRegistry: ObservableObject {
  static let shared = QuickConnectSessionRegistry()

  struct Entry: Equatable {
    let windowID: String
    let host: HostRecord
    let target: QuickConnectTarget
    let authentication: SSHSessionViewModel.AuthenticationChoice
  }

  @Published private(set) var entries: [String: Entry] = [:]

  func open(
    windowID: String = UUID().uuidString,
    target: QuickConnectTarget,
    environment: HostEnvironment = .development,
    authentication: SSHSessionViewModel.AuthenticationChoice
  ) -> Entry {
    let host = Self.makeTemporaryHost(for: target, id: "quick-connect-\(windowID)", environment: environment)
    let entry = Entry(
      windowID: windowID,
      host: host,
      target: target,
      authentication: authentication
    )
    entries[windowID] = entry
    return entry
  }

  func entry(for windowID: String) -> Entry? {
    entries[windowID]
  }

  func close(windowID: String) {
    entries.removeValue(forKey: windowID)
  }

  static func makeTemporaryHost(
    for target: QuickConnectTarget,
    id: String = "quick-connect-\(UUID().uuidString.lowercased())",
    environment: HostEnvironment = .development
  ) -> HostRecord {
    HostRecord(
      id: id,
      workspaceID: "quick-connect-ephemeral",
      groupID: nil,
      displayName: target.endpointString,
      address: target.host,
      environment: environment,
      version: 1,
      tags: [],
      protocols: [target.connectionProtocol.rawValue]
    )
  }
}

/// Pure, testable form model for Quick Connect target parsing, previewing, and authentication validation.
/// Validation errors never echo raw target strings or secrets (C4).
@MainActor
final class QuickConnectFormModel: ObservableObject {
  enum SSHAuthMethod: String, CaseIterable, Identifiable {
    case password
    case keychainCredential
    case sshAgent

    var id: Self { self }
  }

  private var isSyncingProtocolAndScheme = false

  @Published var rawInput: String = "" {
    didSet {
      if rawInput != oldValue {
        submitError = nil
        syncProtocolSelectionWithSchemeIfPresent()
      }
    }
  }

  @Published var selectedProtocol: QuickConnectProtocol = .ssh {
    didSet {
      if selectedProtocol != oldValue {
        submitError = nil
        syncSchemeIfPresentWithSelectedProtocol()
      }
    }
  }

  @Published var environment: HostEnvironment = .development
  @Published var sshUsernameOverride: String = NSUserName()
  @Published var sshAuthMethod: SSHAuthMethod = .password
  @Published var sshPassword: String = ""
  @Published var sshKeyFilePath: String = ""
  @Published var selectedCredentialID: String?
  @Published var rdpLaunchMode: RdpLaunchMode
  @Published var rdpUsername: String = ""
  @Published var credentialRefs: [CredentialRefRecord] = []
  @Published var submitError: String?
  @Published var launchState: RdpLaunchState = .idle

  init(
    defaultSSHUsername: String = UserDefaults.standard.string(forKey: "defaultSSHUsername") ?? "",
    defaultProtocol: String = UserDefaults.standard.string(forKey: HostRecord.preferredProtocolKey) ?? "ssh",
    defaultRdpLaunchMode: RdpLaunchMode = RdpLaunchMode(
      rawValue: UserDefaults.standard.string(forKey: "rdpLaunchMode") ?? ""
    ) ?? .external
  ) {
    let trimmedDefaultUser = defaultSSHUsername.trimmingCharacters(in: .whitespacesAndNewlines)
    self.sshUsernameOverride = trimmedDefaultUser.isEmpty ? NSUserName() : trimmedDefaultUser
    self.selectedProtocol = defaultProtocol == "rdp" ? .rdp : .ssh
    self.rdpLaunchMode = defaultRdpLaunchMode
  }

  /// Live parse result for the current input and selected protocol.
  var parseResult: Result<QuickConnectTarget, QuickConnectValidationError> {
    do {
      let target = try QuickConnectTarget.parse(rawInput, explicitProtocol: selectedProtocol)
      return .success(target)
    } catch let error as QuickConnectValidationError {
      return .failure(error)
    } catch {
      return .failure(.invalidSyntax)
    }
  }

  var parsedTarget: QuickConnectTarget? {
    if case .success(let target) = parseResult {
      return target
    }
    return nil
  }

  /// Live validation error shown when input is non-empty and invalid, or when submission failed.
  var validationErrorMessage: String? {
    if let submitError {
      return submitError
    }
    let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if case .failure(let error) = parseResult {
      return error.localizedDescription
    }
    return nil
  }

  /// Resolved SSH username: URI username takes precedence when present; otherwise uses the form field.
  var effectiveSSHUsername: String {
    if let parsedUser = parsedTarget?.username, !parsedUser.isEmpty {
      return parsedUser
    }
    return sshUsernameOverride.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var isConnectingExternalRDP: Bool {
    launchState == .launching
  }

  var canConnect: Bool {
    guard !isConnectingExternalRDP, let target = parsedTarget else { return false }
    switch target.connectionProtocol {
    case .ssh:
      guard (try? QuickConnectTarget(
        connectionProtocol: .ssh,
        host: target.host,
        port: target.port,
        username: effectiveSSHUsername
      )) != nil else {
        return false
      }
      switch sshAuthMethod {
      case .password:
        return !sshPassword.isEmpty
      case .keychainCredential:
        guard let selectedCredentialID else { return false }
        return credentialRefs.contains(where: { $0.id == selectedCredentialID })
      case .sshAgent:
        return true
      }
    case .rdp:
      switch rdpLaunchMode {
      case .embedded:
        let user = rdpUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, let selectedCredentialID else { return false }
        return credentialRefs.contains(where: { $0.id == selectedCredentialID })
      case .external:
        return true
      }
    }
  }

  func updateCredentialRefs(_ records: [CredentialRefRecord]) {
    let sorted = records.sorted { a, b in
      if (a.kind == .rdpPassword) != (b.kind == .rdpPassword) {
        return a.kind == .rdpPassword
      }
      return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
    }
    credentialRefs = sorted
    if let current = selectedCredentialID, sorted.contains(where: { $0.id == current }) {
      return
    }
    selectedCredentialID = sorted.first?.id
  }

  enum ValidatedConnectionPlan: Equatable {
    case ssh(target: QuickConnectTarget, environment: HostEnvironment, authentication: SSHSessionViewModel.AuthenticationChoice)
    case rdpEmbedded(target: QuickConnectTarget, environment: HostEnvironment, username: String, credentialRefID: String)
    case rdpExternal(target: QuickConnectTarget, endpoint: String)
  }

  /// Validates the full form and returns a connection plan without side effects.
  /// Preserves `rawInput` on error and never includes raw input in error messages (C4).
  func validateForConnect() -> ValidatedConnectionPlan? {
    submitError = nil
    let baseTarget: QuickConnectTarget
    switch parseResult {
    case .success(let target):
      baseTarget = target
    case .failure(let error):
      submitError = error.localizedDescription
      return nil
    }

    switch baseTarget.connectionProtocol {
    case .ssh:
      let resolvedTarget: QuickConnectTarget
      do {
        resolvedTarget = try QuickConnectTarget(
          connectionProtocol: .ssh,
          host: baseTarget.host,
          port: baseTarget.port,
          username: effectiveSSHUsername
        )
      } catch let error as QuickConnectValidationError {
        submitError = error.localizedDescription
        return nil
      } catch {
        submitError = QuickConnectValidationError.invalidUsername.localizedDescription
        return nil
      }

      let authChoice: SSHSessionViewModel.AuthenticationChoice
      switch sshAuthMethod {
      case .password:
        guard !sshPassword.isEmpty else {
          submitError = AppLocalization.string("Password cannot be empty")
          return nil
        }
        let secret = ProtectedSecret(data: Data(sshPassword.utf8))
        // Never persist temporary Quick Connect passwords to Keychain (G1).
        authChoice = .password(secret: secret, saveToKeychain: false, label: nil)

      case .keychainCredential:
        guard let selectedCredentialID,
              let record = credentialRefs.first(where: { $0.id == selectedCredentialID }) else {
          submitError = AppLocalization.string("Choose a saved Keychain credential, or manage credentials in Security → Credentials.")
          return nil
        }
        let trimmedKeyPath = sshKeyFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let identityURL: URL? = trimmedKeyPath.isEmpty
          ? nil
          : URL(fileURLWithPath: (trimmedKeyPath as NSString).expandingTildeInPath)
        authChoice = .keychainCredential(reference: record, identityFileURL: identityURL)

      case .sshAgent:
        authChoice = .sshAgent
      }

      return .ssh(target: resolvedTarget, environment: environment, authentication: authChoice)

    case .rdp:
      switch rdpLaunchMode {
      case .embedded:
        let user = rdpUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty else {
          submitError = RdpCredentialError.emptyUsername.localizedDescription
          return nil
        }
        guard let selectedCredentialID,
              credentialRefs.contains(where: { $0.id == selectedCredentialID }) else {
          submitError = RdpCredentialError.missingCredentialReference.localizedDescription
          return nil
        }
        return .rdpEmbedded(
          target: baseTarget,
          environment: environment,
          username: user,
          credentialRefID: selectedCredentialID
        )

      case .external:
        guard let endpoint = try? RdpLauncher.formatEndpoint(
          address: baseTarget.host,
          port: UInt16(baseTarget.port)
        ) else {
          submitError = QuickConnectValidationError.invalidPort.localizedDescription
          return nil
        }
        return .rdpExternal(target: baseTarget, endpoint: endpoint)
      }
    }
  }

  func clearSensitiveFields() {
    sshPassword = ""
  }

  private func syncProtocolSelectionWithSchemeIfPresent() {
    guard !isSyncingProtocolAndScheme else { return }
    let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    isSyncingProtocolAndScheme = true
    defer { isSyncingProtocolAndScheme = false }
    if trimmed.hasPrefix("ssh://") && selectedProtocol != .ssh {
      selectedProtocol = .ssh
    } else if trimmed.hasPrefix("rdp://") && selectedProtocol != .rdp {
      selectedProtocol = .rdp
    }
  }

  private func syncSchemeIfPresentWithSelectedProtocol() {
    guard !isSyncingProtocolAndScheme else { return }
    let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = trimmed.lowercased()
    let newPrefix = "\(selectedProtocol.rawValue)://"
    let updated: String?
    if lower.hasPrefix("ssh://") && selectedProtocol != .ssh {
      updated = newPrefix + String(trimmed.dropFirst("ssh://".count))
    } else if lower.hasPrefix("rdp://") && selectedProtocol != .rdp {
      updated = newPrefix + String(trimmed.dropFirst("rdp://".count))
    } else {
      updated = nil
    }
    if let updated {
      isSyncingProtocolAndScheme = true
      defer { isSyncingProtocolAndScheme = false }
      rawInput = updated
    }
  }
}

/// Modal sheet for Quick Connect (S1-02, G1).
/// Parses and previews temporary SSH/RDP targets and launches them through existing session flows
/// without saving the host to SQLite inventory or exports.
struct QuickConnectSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openWindow) private var openWindow

  @StateObject private var model: QuickConnectFormModel
  @FocusState private var targetFieldFocused: Bool

  private let launcher: RdpClientLaunching

  private let credentialReferenceSource: () throws -> [CredentialRefRecord]

  init(
    launcher: RdpClientLaunching = RdpLauncher(),
    model: QuickConnectFormModel = QuickConnectFormModel(),
    credentialReferenceSource: @escaping () throws -> [CredentialRefRecord] = {
      let repository = try SQLiteHostRepository.openApplicationRepository()
      defer { try? repository.close() }
      return try repository.listCredentialRefs()
    }
  ) {
    self.launcher = launcher
    _model = StateObject(wrappedValue: model)
    self.credentialReferenceSource = credentialReferenceSource
  }

  private var activeProtocol: QuickConnectProtocol {
    model.parsedTarget?.connectionProtocol ?? model.selectedProtocol
  }

  var body: some View {
    NavigationStack {
      Form {
        targetSection
        previewSection
        if activeProtocol == .ssh {
          sshAuthenticationSection
        } else {
          rdpConfigurationSection
        }
      }
      .formStyle(.grouped)
      .navigationTitle(quickConnectText("Quick Connect"))
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(AppLocalization.string("Cancel")) {
            model.clearSensitiveFields()
            dismiss()
          }
          .keyboardShortcut(.cancelAction)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button {
            connect()
          } label: {
            Label(
              AppLocalization.string("Connect"),
              systemImage: activeProtocol == .ssh ? "terminal" : "display"
            )
          }
          .buttonStyle(WorkspacePrimaryButtonStyle())
          .keyboardShortcut(.defaultAction)
          .disabled(!model.canConnect || (activeProtocol == .rdp && model.rdpLaunchMode == .external && !launcher.isClientAvailable()))
          .accessibilityLabel(AppLocalization.string("Connect"))
        }
      }
      .frame(minWidth: 500, minHeight: 460)
      .onAppear {
        targetFieldFocused = true
        loadCredentialRefs()
      }
      .onDisappear {
        model.clearSensitiveFields()
      }
    }
  }

  // MARK: - Sections

  private var targetSection: some View {
    Section {
      TextField(
        AppLocalization.string("Address"),
        text: $model.rawInput,
        prompt: Text("ssh://user@host:22, rdp://host:3389, or host")
      )
      .focused($targetFieldFocused)
      .font(.system(.body, design: .monospaced))
      .onSubmit {
        if model.canConnect {
          connect()
        } else {
          _ = model.validateForConnect()
        }
      }
      .accessibilityLabel(AppLocalization.string("Host address"))

      Picker(AppLocalization.string("Protocol"), selection: $model.selectedProtocol) {
        Text("SSH").tag(QuickConnectProtocol.ssh)
        Text("RDP").tag(QuickConnectProtocol.rdp)
      }
      .pickerStyle(.segmented)
      .accessibilityLabel(AppLocalization.string("Protocol"))

      Picker(AppLocalization.string("Environment"), selection: $model.environment) {
        ForEach(HostEnvironment.allCases) { env in
          Text(env.localizedTitle).tag(env)
        }
      }

      if let error = model.validationErrorMessage {
        HStack(spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
      }
    } header: {
      Text(AppLocalization.string("Host & Endpoint"))
    } footer: {
      Text(quickConnectText("Connects without saving this host to your workspace inventory. Host trust verification is still enforced before authentication."))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var previewSection: some View {
    Section(AppLocalization.string("Preview")) {
      if let target = model.parsedTarget {
        LabeledContent(AppLocalization.string("Protocol")) {
          Text(target.connectionProtocol == .ssh ? "SSH" : "RDP")
            .font(.callout.bold())
        }
        LabeledContent(AppLocalization.string("Host")) {
          Text(target.host)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
        }
        LabeledContent(AppLocalization.string("Port")) {
          Text(String(target.port))
            .font(.system(.body, design: .monospaced))
        }
        if target.connectionProtocol == .ssh {
          LabeledContent(AppLocalization.string("Username")) {
            Text(model.effectiveSSHUsername.isEmpty ? "—" : model.effectiveSSHUsername)
              .font(.system(.body, design: .monospaced))
          }
        }
        LabeledContent(AppLocalization.string("Full Endpoint")) {
          Text(
            target.connectionProtocol == .ssh && !model.effectiveSSHUsername.isEmpty
              ? "ssh://\(model.effectiveSSHUsername)@\(target.endpointString)"
              : target.canonicalURIString
          )
          .font(.system(.callout, design: .monospaced))
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        }
      } else {
        Text(quickConnectText("Enter a valid target such as ssh://user@host:22 or rdp://host:3389."))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var sshAuthenticationSection: some View {
    Section(AppLocalization.string("SSH Connection")) {
      if model.parsedTarget?.username == nil {
        TextField(AppLocalization.string("Username"), text: $model.sshUsernameOverride)
          .accessibilityLabel(AppLocalization.string("SSH username"))
      }

      Picker(AppLocalization.string("Authentication"), selection: $model.sshAuthMethod) {
        Text(AppLocalization.string("Password")).tag(QuickConnectFormModel.SSHAuthMethod.password)
        Text(AppLocalization.string("Keychain credential")).tag(QuickConnectFormModel.SSHAuthMethod.keychainCredential)
        Text(AppLocalization.string("SSH agent")).tag(QuickConnectFormModel.SSHAuthMethod.sshAgent)
      }
      .accessibilityLabel(AppLocalization.string("Authentication method"))

      switch model.sshAuthMethod {
      case .password:
        SecureField(AppLocalization.string("Password"), text: $model.sshPassword)
          .privacySensitive()
          .accessibilityLabel(AppLocalization.string("SSH Password"))
      case .keychainCredential:
        if model.credentialRefs.isEmpty {
          Text(AppLocalization.string("No saved Keychain credentials. Add one in Security → Credentials."))
            .font(.caption)
            .foregroundStyle(.secondary)
          Button(AppLocalization.string("Open Security → Credentials")) {
            dismiss()
            NotificationCenter.default.post(name: .openCredentialsVault, object: nil)
          }
        } else {
          Picker(AppLocalization.string("Credential"), selection: $model.selectedCredentialID) {
            ForEach(model.credentialRefs) { record in
              Text("\(record.label) — \(record.kind.localizedTitle)").tag(Optional(record.id))
            }
          }
          TextField(
            AppLocalization.string("Key file (optional)"),
            text: $model.sshKeyFilePath,
            prompt: Text("~/.ssh/id_ed25519")
          )
          .accessibilityLabel(AppLocalization.string("Optional private key file path for passphrase authentication"))
        }
      case .sshAgent:
        Label(AppLocalization.string("Using active agent from SSH_AUTH_SOCK"), systemImage: "key.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var rdpConfigurationSection: some View {
    Section(AppLocalization.string("Remote Desktop (RDP)")) {
      Picker(AppLocalization.string("Mode"), selection: $model.rdpLaunchMode) {
        ForEach(RdpLaunchMode.allCases) { mode in
          Text(mode.localizedTitle).tag(mode)
        }
      }
      .pickerStyle(.segmented)

      if model.rdpLaunchMode == .embedded {
        TextField(AppLocalization.string("Username"), text: $model.rdpUsername)
          .accessibilityLabel(AppLocalization.string("RDP Username"))

        if model.credentialRefs.isEmpty {
          Text(AppLocalization.string("No saved Keychain credentials. Add one in Security → Credentials."))
            .font(.caption)
            .foregroundStyle(.secondary)
          Button(AppLocalization.string("Open Security → Credentials")) {
            dismiss()
            NotificationCenter.default.post(name: .openCredentialsVault, object: nil)
          }
        } else {
          Picker(AppLocalization.string("Keychain Credential"), selection: $model.selectedCredentialID) {
            ForEach(model.credentialRefs) { record in
              Text("\(record.label) — \(record.kind.localizedTitle)").tag(Optional(record.id))
            }
          }
        }
      } else {
        if launcher.isClientAvailable() {
          HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(.green)
            Text(AppLocalization.string("Microsoft Windows App is available"))
              .font(.callout)
          }
        } else {
          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
              Text(AppLocalization.string("Microsoft Windows App not found"))
                .font(.callout.bold())
            }
            Text(AppLocalization.string("Windows App (or Microsoft Remote Desktop) was not found in Applications. Please install it, or copy the endpoint above to connect manually."))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        if case .launching = model.launchState {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(AppLocalization.string("Launching Windows App…"))
              .font(.callout)
          }
        } else if case .failed(let message) = model.launchState {
          HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            Text(message).font(.caption).foregroundStyle(.red)
          }
        }
      }
    }
  }

  // MARK: - Actions

  private func loadCredentialRefs() {
    model.updateCredentialRefs((try? credentialReferenceSource()) ?? [])
  }

  private func connect() {
    guard let plan = model.validateForConnect() else { return }

    switch plan {
    case .ssh(let target, let environment, let authentication):
      let entry = QuickConnectSessionRegistry.shared.open(
        target: target,
        environment: environment,
        authentication: authentication
      )
      SSHWindowOpenRequests.shared.request(hostID: entry.windowID)
      openWindow(id: "quick-connect-ssh-session", value: entry.windowID)
      model.clearSensitiveFields()
      dismiss()

    case .rdpEmbedded(let target, let environment, let username, let credentialRefID):
      let tempHost = QuickConnectSessionRegistry.makeTemporaryHost(
        for: target,
        environment: environment
      )
      let options = RdpConnectionPreferences().globalOptions
      let makeSession = QuickConnectRdpSessionResources.makeEmbeddedSessionFactory(
        target: target,
        username: username,
        credentialRefID: credentialRefID,
        options: options,
        fallbackCredentialRefs: model.credentialRefs
      )
      let windowID = UUID().uuidString
      RdpSessionWindowRegistry.shared.open(windowID: windowID, host: tempHost, makeSession: makeSession)
      openWindow(id: "rdp-session", value: windowID)
      model.clearSensitiveFields()
      dismiss()

    case .rdpExternal(_, let endpoint):
      model.launchState = .launching
      Task {
        do {
          try await launcher.launch(endpoint: endpoint)
          model.launchState = .launched
          model.clearSensitiveFields()
          dismiss()
        } catch {
          model.launchState = .failed(error.localizedDescription)
        }
      }
    }
  }
}

/// Window content for an ephemeral Quick Connect SSH session.
/// Uses the standard `SSHSessionViewModel`, `HostTrustReviewView`, `KeyMismatchView`, and `SSHTerminalView`
/// without persisting any host record, SSH settings, or session-restore layout.
struct QuickConnectSSHSessionWindowView: View {
  @ObservedObject private var registry = QuickConnectSessionRegistry.shared
  let windowID: String

  var body: some View {
    if let entry = registry.entry(for: windowID) {
      QuickConnectSSHSessionContentView(entry: entry)
        .onDisappear {
          registry.close(windowID: windowID)
        }
    } else {
      UnavailableSessionView(title: AppLocalization.string("SSH session unavailable"), symbol: "terminal")
    }
  }
}

private struct QuickConnectSSHSessionContentView: View {
  @Environment(\.dismiss) private var dismiss
  let entry: QuickConnectSessionRegistry.Entry

  @StateObject private var viewModel: SSHSessionViewModel
  @ObservedObject private var openRequests = SSHWindowOpenRequests.shared
  @State private var openLifecycle = SSHSessionOpenLifecycle()
  @State private var connectToken = 0
  @State private var confirmingRotation = false
  @State private var localPortString = "5432"
  @State private var tunnelRemoteHost = "127.0.0.1"
  @State private var tunnelRemotePortString = "5432"
  @State private var tunnelValidationError: String?

  init(entry: QuickConnectSessionRegistry.Entry) {
    self.entry = entry
    _viewModel = StateObject(wrappedValue: SSHSessionViewModel(host: entry.host))
  }

  private var username: String {
    entry.target.username ?? NSUserName()
  }

  private var portString: String {
    String(entry.target.port)
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

  private var isAuthRejectionOutput: Bool {
    viewModel.terminalOutput.localizedCaseInsensitiveContains("Permission denied")
      || viewModel.terminalOutput.localizedCaseInsensitiveContains("Authentication failed")
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if viewModel.host.environment == .production {
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
        }

        HStack {
          Text("\(username)@\(entry.target.endpointString)")
            .font(.system(.subheadline, design: .monospaced))
          Spacer()
          actionButton
        }
        .padding(12)
        .background(.bar)

        Divider()

        SessionStatusBar(
          viewModel: viewModel,
          username: username,
          portString: portString,
          isAuthRejectionOutput: isAuthRejectionOutput
        )
        Divider()

        if isRunning || !viewModel.localTunnels.isEmpty {
          TunnelPanelView(
            viewModel: viewModel,
            isRunning: isRunning,
            localPortString: $localPortString,
            tunnelRemoteHost: $tunnelRemoteHost,
            tunnelRemotePortString: $tunnelRemotePortString,
            tunnelValidationError: $tunnelValidationError
          )
          Divider()
        }

        mainContentView
      }
      .frame(minWidth: 700, minHeight: 540)
      .navigationTitle(AppLocalization.format("SSH: %1$@", entry.target.endpointString))
      .toolbar {
        ToolbarItem(placement: .principal) {
          EnvironmentBadge(environment: viewModel.host.environment)
        }
      }
      .interactiveDismissDisabled(viewModel.hasLiveSession)
      .background(WindowCloseGuard {
        guard viewModel.hasLiveSession else { return true }
        let alert = NSAlert()
        alert.messageText = AppLocalization.string("Close and disconnect?")
        alert.addButton(withTitle: AppLocalization.string("Keep Session"))
        alert.addButton(withTitle: AppLocalization.string("Disconnect and Close"))
        return alert.runModal() == .alertSecondButtonReturn
      })
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
        viewModel.terminateSync()
      }
      .onReceive(openRequests.$revision) { _ in
        guard openRequests.consume(hostID: entry.windowID, hasActiveSession: isActiveAttempt) else { return }
        connectToken += 1
      }
      .task(id: connectToken) {
        if openLifecycle.consume(requestToken: connectToken, status: viewModel.status) {
          startConnection()
        }
      }
      .onDisappear {
        viewModel.disconnect()
      }
    }
  }

  @ViewBuilder
  private var actionButton: some View {
    if viewModel.status == .idle {
      Button(AppLocalization.string("Connect")) { startConnection() }
        .buttonStyle(WorkspacePrimaryButtonStyle())
    } else if case .disconnected(let exitCode) = viewModel.status {
      let isAuthFailure = exitCode == 255 && isAuthRejectionOutput
      Button(isAuthFailure ? AppLocalization.string("Retry") : AppLocalization.string("Reconnect")) {
        startConnection()
      }
      .buttonStyle(WorkspacePrimaryButtonStyle())
    } else if case .failed = viewModel.status {
      Button(AppLocalization.string("Retry")) { startConnection() }
        .buttonStyle(WorkspacePrimaryButtonStyle())
    } else if isVerifying || isConnecting {
      Button(AppLocalization.string("Cancel")) { viewModel.disconnect() }
        .buttonStyle(WorkspaceSecondaryButtonStyle())
    } else if isRunning {
      Button(AppLocalization.string("Disconnect")) { viewModel.disconnect() }
        .buttonStyle(WorkspaceSecondaryButtonStyle())
    }
  }

  @ViewBuilder
  private var mainContentView: some View {
    switch viewModel.status {
    case .hostTrustRequired(let challenge):
      HostTrustReviewView(viewModel: viewModel, challenge: challenge)
    case .hostKeyMismatch(let recordedKeys, let presentedKey):
      KeyMismatchView(
        viewModel: viewModel,
        recordedKeys: recordedKeys,
        presentedKey: presentedKey,
        confirmingRotation: $confirmingRotation
      )
    default:
      SSHTerminalView(viewModel: viewModel, isActive: isRunning)
    }
  }

  private func startConnection() {
    viewModel.connect(
      username: username,
      port: entry.target.port,
      authentication: entry.authentication,
      proxyJump: nil
    )
  }
}

#if DEBUG
#Preview("QuickConnectSheet") {
  QuickConnectSheet()
}
#endif
