import AppCore
import SwiftUI

extension Notification.Name {
  /// Asks the shell to navigate to Security → Credentials.
  static let openCredentialsVault = Notification.Name("openCredentialsVault")
}

enum RdpLaunchMode: String, CaseIterable, Identifiable {
  case embedded = "Embedded (Native)"
  case external = "External Windows App"
  var id: String { rawValue }
  var localizedTitle: String { AppLocalization.string(rawValue) }
}

struct RdpLaunchSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openWindow) private var openWindow
  let host: HostRecord
  let launcher: RdpClientLaunching

  @AppStorage("rdpLaunchMode") private var launchMode: RdpLaunchMode = .external
  @State private var portString: String = "3389"
  @State private var launchState: RdpLaunchState = .idle
  @State private var copiedNotice: Bool = false
  @State private var username: String = ""
  @State private var credentialRefs: [CredentialRefRecord] = []
  @State private var selectedCredentialID: String?
  @State private var embeddedError: String?
  @State private var didPrepareConnection = false
  @State private var sharedFolderPath: String?

  init(host: HostRecord, launcher: RdpClientLaunching = RdpLauncher()) {
    self.host = host
    self.launcher = launcher
  }

  private var parsedPort: UInt16? {
    guard let port = UInt16(portString), (1...65535).contains(port) else {
      return nil
    }
    return port
  }

  private var portValidationError: String? {
    if parsedPort == nil {
      return AppLocalization.string("Port must be an integer between 1 and 65535.")
    }
    return nil
  }

  private var endpointString: String? {
    guard let port = parsedPort else { return nil }
    return try? RdpLauncher.formatEndpoint(address: host.address, port: port)
  }

  private var isClientAvailable: Bool {
    launcher.isClientAvailable()
  }

  var body: some View {
    NavigationStack {
        Form {
          Section {
            HStack { EnvironmentBadge(environment: host.environment); Spacer() }
          }
          Section(AppLocalization.string("Connection Mode")) {
            Picker(AppLocalization.string("Mode"), selection: $launchMode) {
              ForEach(RdpLaunchMode.allCases) { mode in
                Text(mode.localizedTitle).tag(mode)
              }
            }
            .pickerStyle(.segmented)

            if launchMode == .embedded {
              Text(AppLocalization.string("Embedded RDP authenticates with NLA using a saved Apple Keychain credential. Use DOMAIN\\user or user@domain for domain accounts."))
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
              Text(AppLocalization.string("Opens the connection in Microsoft Windows App, which must be installed."))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }

          Section(AppLocalization.string("Host & Endpoint")) {
            LabeledContent(AppLocalization.string("Host")) {
              Text(host.displayName)
                .bold()
            }
            LabeledContent(AppLocalization.string("Address")) {
              Text(host.address)
                .monospaced()
            }
            VStack(alignment: .leading, spacing: 4) {
              TextField(AppLocalization.string("Port"), text: $portString)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .onSubmit { submitPrimaryAction() }
                .accessibilityLabel(AppLocalization.string("RDP Port"))

              if let portValidationError {
                Text(portValidationError)
                  .font(.caption)
                  .foregroundStyle(.red)
              }
            }

            LabeledContent(AppLocalization.string("Full Endpoint")) {
              HStack(spacing: 8) {
                if let endpointString {
                  Text(endpointString)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                  Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(endpointString, forType: .string)
                    copiedNotice = true
                  } label: {
                    Label(AppLocalization.string("Copy"), systemImage: copiedNotice ? "checkmark" : "doc.on.doc")
                  }
                  .buttonStyle(.borderless)
                  .accessibilityLabel(AppLocalization.string("Copy endpoint to clipboard"))
                } else {
                  Text(AppLocalization.string("Invalid port"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
              }
            }
          }

          if launchMode == .embedded {
            Section(AppLocalization.string("Authentication")) {
              TextField(AppLocalization.string("Username"), text: $username)
                .accessibilityLabel(AppLocalization.string("RDP Username"))
              if credentialRefs.isEmpty {
                Text(AppLocalization.string("No saved Keychain credentials. Add one in Security → Credentials."))
                  .font(.caption)
                Button(AppLocalization.string("Open Security → Credentials")) {
                  dismiss()
                  NotificationCenter.default.post(name: .openCredentialsVault, object: nil)
                }
                  .foregroundStyle(.red)
              } else {
                Picker(AppLocalization.string("Keychain Credential"), selection: $selectedCredentialID) {
                  ForEach(credentialRefs) { record in
                    Text("\(record.label) — \(record.kind.localizedTitle)").tag(Optional(record.id))
                  }
                }
              }
              if let embeddedError {
                Text(embeddedError)
                  .font(.caption)
                  .foregroundStyle(.red)
              }
            }
          }

          if launchMode == .embedded {
            Section(AppLocalization.string("Shared Folder")) {
              Toggle(AppLocalization.string("Share a Mac folder with Windows"), isOn: Binding(
                get: { sharedFolderPath != nil },
                set: { enabled in
                  if enabled {
                    chooseSharedFolder()
                  } else {
                    sharedFolderPath = nil
                    UserDefaults.standard.removeObject(forKey: sharedFolderKey)
                  }
                }
              ))
              if let path = sharedFolderPath {
                let folder = URL(fileURLWithPath: path)
                HStack {
                  VStack(alignment: .leading) {
                    Text(folder.lastPathComponent)
                    Text(path)
                      .lineLimit(1)
                      .truncationMode(.middle)
                      .foregroundStyle(.secondary)
                  }
                  Button(AppLocalization.string("Choose…")) { chooseSharedFolder() }
                }
                let windowsPath = "\\\\tsclient\\" + RdpSharedFolder.driveName(for: folder)
                Text(AppLocalization.format(
                  "Windows can read and change files in this folder. It appears as %@.", windowsPath
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
              }
            }
          }

          if launchMode == .external {
            Section(AppLocalization.string("RDP Client Status")) {
              if isClientAvailable {
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
            }

            Section(AppLocalization.string("Session Lifecycle & Security")) {
              VStack(alignment: .leading, spacing: 6) {
                Text(AppLocalization.string("External Client Handoff"))
                  .font(.caption.bold())
                Text(AppLocalization.string("No credentials, passwords, or arbitrary URI attributes are passed to the external client. Sign in inside Windows App."))
                  .font(.caption)
                  .foregroundStyle(.secondary)
                Text(AppLocalization.string("Notice: Mac Remote Workspace can track that the client was launched, but remote connection status, authentication, and session lifetime remain strictly inside Windows App."))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }

              switch launchState {
              case .idle:
                EmptyView()
              case .launching:
                HStack(spacing: 8) {
                  ProgressView()
                    .controlSize(.small)
                  Text(AppLocalization.string("Launching Windows App…"))
                    .font(.callout)
                }
              case .launched:
                HStack(spacing: 8) {
                  Image(systemName: "arrow.up.forward.app.fill")
                    .foregroundStyle(.blue)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(AppLocalization.string("Windows App launched"))
                      .font(.callout.bold())
                    Text(AppLocalization.string("Connection status unavailable (managed externally)."))
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }
              case .failed(let message):
                HStack(spacing: 8) {
                  Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(AppLocalization.string("Launch failed"))
                      .font(.callout.bold())
                    Text(message)
                      .font(.caption)
                      .foregroundStyle(.red)
                  }
                }
              }
            }
          }
        }
        .formStyle(.grouped)
        .navigationTitle(launchMode == .embedded ? AppLocalization.string("Embedded RDP Session") : AppLocalization.string("Launch External RDP"))
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button(AppLocalization.string("Close")) {
              dismiss()
            }
          }

          ToolbarItem(placement: .confirmationAction) {
            if launchMode == .embedded {
              Button {
                startEmbeddedSession()
              } label: {
                Label(AppLocalization.string("Connect"), systemImage: "display")
              }
              .keyboardShortcut(.defaultAction)
              .disabled(endpointString == nil || credentialRefs.isEmpty)
              .accessibilityLabel(AppLocalization.string("Connect embedded RDP"))
            } else {
              Button {
                performLaunch()
              } label: {
                Label(AppLocalization.string("Launch Windows App"), systemImage: "arrow.up.forward.app")
              }
              .keyboardShortcut(.defaultAction)
              .disabled(!isClientAvailable || endpointString == nil || launchState == .launching)
              .accessibilityLabel(AppLocalization.string("Launch Windows App"))
            }
          }
        }
        .frame(minWidth: 480, minHeight: 520)
        .task {
          guard !didPrepareConnection else { return }
          didPrepareConnection = true
          loadCredentialRefs()
          if launchMode == .external {
            submitPrimaryAction()
          } else if let defaults = try? SQLiteHostRepository.openApplicationRepository().rdpProfileDefaults(hostID: host.id),
                    let ref = defaults.credentialRefID,
                    credentialRefs.contains(where: { $0.id == ref }),
                    !defaults.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            startEmbeddedSession()
          }
        }
    }
  }

  private func submitPrimaryAction() {
    guard endpointString != nil else { return }
    if launchMode == .embedded {
      if !credentialRefs.isEmpty { startEmbeddedSession() }
    } else if isClientAvailable, launchState != .launching {
      performLaunch()
    }
  }

  private var sharedFolderKey: String { "rdpSharedFolder.\(host.id)" }

  private func chooseSharedFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = AppLocalization.string("Share")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    sharedFolderPath = url.path
    UserDefaults.standard.set(url.path, forKey: sharedFolderKey)
  }

  private func loadCredentialRefs() {
    if let path = UserDefaults.standard.string(forKey: sharedFolderKey) {
      if let folder = try? RdpSharedFolder.validate(path) {
        sharedFolderPath = folder.path
      } else {
        UserDefaults.standard.removeObject(forKey: sharedFolderKey)
      }
    }
    let loaded = (try? SQLiteHostRepository.openApplicationRepository().listCredentialRefs()) ?? []
    credentialRefs = loaded.sorted { a, b in
      if (a.kind == .rdpPassword) != (b.kind == .rdpPassword) {
        return a.kind == .rdpPassword
      }
      return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
    }
    if selectedCredentialID == nil { selectedCredentialID = credentialRefs.first?.id }
    if let d = try? SQLiteHostRepository.openApplicationRepository().rdpProfileDefaults(hostID: host.id) {
      portString = String(d.port)
      if username.isEmpty { username = d.username }
      if let ref = d.credentialRefID, credentialRefs.contains(where: { $0.id == ref }) {
        selectedCredentialID = ref
      }
    }
  }

  private func startEmbeddedSession() {
    guard let port = parsedPort else { return }
    let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !user.isEmpty else {
      embeddedError = RdpCredentialError.emptyUsername.localizedDescription
      return
    }
    guard let refID = selectedCredentialID, credentialRefs.contains(where: { $0.id == refID }) else {
      embeddedError = RdpCredentialError.missingCredentialReference.localizedDescription
      return
    }
    let validatedFolder: URL?
    if let sharedFolderPath {
      do {
        validatedFolder = try RdpSharedFolder.validate(sharedFolderPath)
      } catch {
        embeddedError = AppLocalization.string("Shared folder is not an accessible folder.")
        return
      }
    } else {
      validatedFolder = nil
    }
    embeddedError = nil
    let repo = (try? SQLiteHostRepository.openApplicationRepository())
    try? repo?.upsertRdpProfile(
      hostID: host.id, port: Int(port), username: user, credentialRefID: refID)
    let verifier = repo.map { NativeRdpCertificateTrustService(repository: $0) }
      ?? NativeRdpCertificateTrustService(repository: InMemoryRdpHostTrustRepository())
    let refs = credentialRefs
    let resolver = RdpCredentialResolver(credentialLookup: { id in refs.first { $0.id == id } })
    let address = host.address
    let makeSession = {
      NativeRdpSession(
        configuration: RdpSessionConfiguration(
          host: address, port: Int(port), username: user, credentialRefID: refID,
          sharedFolderPath: validatedFolder?.path),
        certificateVerifier: verifier,
        credentialResolver: resolver
      )
    }
    let windowID = UUID().uuidString
    RdpSessionWindowRegistry.shared.open(windowID: windowID, host: host, makeSession: makeSession)
    openWindow(id: "rdp-session", value: windowID)
    dismiss()
  }

  private func performLaunch() {
    guard let endpoint = endpointString else {
      launchState = .failed(AppLocalization.string("Please enter a valid port between 1 and 65535."))
      return
    }
    launchState = .launching
    Task {
      do {
        try await launcher.launch(endpoint: endpoint)
        launchState = .launched
        dismiss()
      } catch {
        launchState = .failed(error.localizedDescription)
      }
    }
  }
}

enum RdpLaunchState: Equatable {
  case idle
  case launching
  case launched
  case failed(String)
}

#if DEBUG
#Preview("RdpLaunchSheet") {
  RdpLaunchSheet(host: PreviewFixtures.host)
}
#endif
