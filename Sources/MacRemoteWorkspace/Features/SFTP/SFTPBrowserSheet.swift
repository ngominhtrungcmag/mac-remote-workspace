import AppCore
import SwiftUI

public struct SFTPBrowserSheet: View {
  let host: HostRecord
  @ObservedObject var transferQueue: SFTPTransferQueue
  @StateObject private var viewModel: SFTPBrowserViewModel

  @State private var renameText: String = ""
  @State private var confirmingRotation = false
  @State private var showingRenameDialog: Bool = false
  @State private var showingNewFolderDialog: Bool = false
  @State private var newFolderName: String = ""

  public init(host: HostRecord, transferQueue: SFTPTransferQueue) {
    self.host = host
    self.transferQueue = transferQueue
    _viewModel = StateObject(wrappedValue: SFTPBrowserViewModel(host: host))
  }

  public var body: some View {
    Group {
      if !viewModel.isConnected {
        connectionDialog
      } else {
        VStack(spacing: 0) {
          headerBar
          Divider()
          browserContentView
        }
        .frame(minWidth: 850, minHeight: 550)
      }
    }
    .confirmationDialog(
      AppLocalization.string("Delete remote item?"),
      isPresented: Binding(
        get: { !viewModel.entriesPendingDeletion.isEmpty },
        set: { if !$0 { viewModel.entriesPendingDeletion = [] } }
      ),
      titleVisibility: .visible
    ) {
      Button(AppLocalization.string("Delete"), role: .destructive) {
        viewModel.deleteConfirmedEntries()
      }
      Button(AppLocalization.string("Cancel"), role: .cancel) {
        viewModel.entriesPendingDeletion = []
      }
    } message: {
      Text(viewModel.entriesPendingDeletion.map { NativeSFTPClient.deleteConfirmationMessage(for: $0) }.joined(separator: "\n"))
    }
    .sheet(isPresented: $showingRenameDialog) {
      renameSheet
    }
    .sheet(isPresented: $showingNewFolderDialog) {
      newFolderSheet
    }
    .background(WindowCloseGuard {
      guard transferQueue.hasActiveTransfers else { return true }
      let alert = NSAlert()
      alert.messageText = AppLocalization.string("Close SFTP window with active transfers?")
      alert.informativeText = AppLocalization.string("Closing may interrupt transfers.")
      alert.addButton(withTitle: AppLocalization.string("Keep Window Open"))
      alert.addButton(withTitle: AppLocalization.string("Close Window"))
      return alert.runModal() == .alertSecondButtonReturn
    })
    .onDisappear {
      viewModel.disconnect()
    }
    .onChange(of: viewModel.authMethod) { _, newMethod in
      if newMethod == .keychain && viewModel.availableCredentials.isEmpty {
        viewModel.loadCredentials()
      }
    }
    .task {
      viewModel.loadCredentials()
    }
    .alert(AppLocalization.string("SFTP Error"), isPresented: Binding(
      get: { viewModel.errorMessage != nil },
      set: { if !$0 { viewModel.errorMessage = nil } }
    )) {
      Button(AppLocalization.string("OK"), role: .cancel) {
        viewModel.errorMessage = nil
      }
    } message: {
      Text(viewModel.errorMessage ?? AppLocalization.string("An unexpected error occurred."))
    }
  }

  // MARK: - Header

  private var headerBar: some View {
    HStack {
      Image(systemName: "folder.badge.gearshape")
        .font(.title2)
        .foregroundStyle(.tint)

      VStack(alignment: .leading, spacing: 2) {
        Text(AppLocalization.format("SFTP: %1$@", String(describing: host.displayName)))
          .font(.headline)
        Text("\(host.address):\(viewModel.port)")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }

      Spacer()

      EnvironmentBadge(environment: host.environment)

      if viewModel.isConnected {
        Button(AppLocalization.string("Disconnect")) {
          viewModel.disconnect()
        }
        .buttonStyle(WorkspaceSecondaryButtonStyle())
      }

      Button(AppLocalization.string("Close")) {
        NSApp.keyWindow?.performClose(nil)
      }
    }
    .padding(14)
  }

  // MARK: - Connection Dialog

  private var connectionDialog: some View {
    NavigationStack {
      Form {
        Section {
          HStack {
            EnvironmentBadge(environment: host.environment)
            Spacer()
            Text("\(host.address):\(viewModel.port)")
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
          }
        }

        if let challenge = viewModel.trustChallenge {
          Section(AppLocalization.string("Host Key Verification")) {
            trustChallengeBanner(challenge)
          }
        } else if let mismatch = viewModel.mismatchBlocked {
          Section(AppLocalization.string("Connection Blocked")) {
            mismatchBlockedBanner(mismatch)
          }
        } else {
          Section(AppLocalization.string("Connection")) {
            TextField(AppLocalization.string("User"), text: $viewModel.username)
              .disabled(viewModel.isConnecting)
              .accessibilityLabel(AppLocalization.string("SFTP Username"))

            TextField(AppLocalization.string("Port"), text: $viewModel.portString)
              .disabled(viewModel.isConnecting)
              .accessibilityLabel(AppLocalization.string("SFTP Port"))
          }

          Section(AppLocalization.string("Authentication")) {
            Picker(AppLocalization.string("Method"), selection: $viewModel.authMethod) {
              Text(AppLocalization.string("Password")).tag(SFTPAuthMethod.password)
              Text(AppLocalization.string("Keychain Credential")).tag(SFTPAuthMethod.keychain)
              Text(AppLocalization.string("SSH Agent")).tag(SFTPAuthMethod.agent)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(viewModel.isConnecting)

            switch viewModel.authMethod {
            case .password:
              SecureField(AppLocalization.string("Password"), text: $viewModel.password)
                .disabled(viewModel.isConnecting)
                .privacySensitive()
                .accessibilityLabel(AppLocalization.string("SFTP Password"))

              Toggle(AppLocalization.string("Save to Keychain"), isOn: $viewModel.savePasswordToKeychain)
                .toggleStyle(.checkbox)
                .disabled(viewModel.isConnecting)

              if viewModel.savePasswordToKeychain {
                TextField(AppLocalization.string("Keychain Label (optional)"), text: $viewModel.passwordCredentialLabel)
                  .disabled(viewModel.isConnecting)
              }

              Text(AppLocalization.string("Stored securely in Keychain."))
                .font(.caption)
                .foregroundStyle(.secondary)

            case .keychain:
              if viewModel.availableCredentials.isEmpty {
                Text(AppLocalization.string("No credentials saved. Add one in Security → Credentials."))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              } else {
                Picker(AppLocalization.string("Saved Credential"), selection: $viewModel.selectedCredentialID) {
                  Text(AppLocalization.string("Choose…")).tag(String?.none)
                  ForEach(viewModel.availableCredentials) { cred in
                    Text("\(cred.label) — \(cred.kind.localizedTitle)").tag(String?.some(cred.id))
                  }
                }
              }

              TextField(AppLocalization.string("Key File (optional)"), text: $viewModel.keyFilePath, prompt: Text("~/.ssh/id_ed25519"))
                .disabled(viewModel.isConnecting)

            case .agent:
              Label(AppLocalization.string("Using active agent from SSH_AUTH_SOCK"), systemImage: "key.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }

          if let validation = viewModel.validationError {
            Section {
              HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                  .foregroundStyle(.red)
                Text(validation)
                  .font(.caption)
                  .foregroundStyle(.red)
              }
            }
          }

          Section {
            Button(viewModel.isDiagnosing ? AppLocalization.string("Diagnosing…") : AppLocalization.string("Diagnose Connection")) {
              viewModel.performDiagnostics()
            }
            .disabled(viewModel.isConnecting || viewModel.isDiagnosing)

            if viewModel.isDiagnosing || viewModel.diagnosticsReport != nil {
              SSHConnectionDiagnosticsPanel(
                isRunning: viewModel.isDiagnosing,
                report: viewModel.diagnosticsReport
              )
            }
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle(AppLocalization.string("Connect to SFTP"))
      .navigationSubtitle(host.displayName)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(AppLocalization.string("Cancel")) {
            NSApp.keyWindow?.performClose(nil)
          }
          .keyboardShortcut(.cancelAction)
        }

        ToolbarItem(placement: .confirmationAction) {
          Button {
            viewModel.connect()
          } label: {
            if viewModel.isConnecting {
              HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(AppLocalization.string("Connecting…"))
              }
            } else {
              Text(AppLocalization.string("Connect"))
            }
          }
          .keyboardShortcut(.defaultAction)
          .disabled(viewModel.isConnecting)
        }
      }
      .frame(minWidth: 460, idealWidth: 480, maxWidth: 520, minHeight: 440, idealHeight: 520)
    }
  }

  private func trustChallengeBanner(_ challenge: SSHHostTrustChallenge) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(AppLocalization.string("Unknown Host Key Verification"), systemImage: "shield.lefthalf.filled")
        .font(.headline)
        .foregroundStyle(.orange)

      Text(AppLocalization.format("The authenticity of host '%1$@:%2$@' cannot be established.", String(describing: challenge.host), String(describing: challenge.port)))
        .font(.subheadline)

      VStack(alignment: .leading, spacing: 4) {
        Text(AppLocalization.format(
          "Algorithm: %1$@ (%2$@)",
          challenge.presentedKey.algorithm,
          challenge.presentedKey.bitLength.map { AppLocalization.format("%1$@ bits", String($0)) } ?? AppLocalization.string("unknown")
        ))
          .font(.caption)
        Text(AppLocalization.format("Fingerprint: %1$@", String(describing: challenge.presentedKey.fingerprintSHA256)))
          .font(.caption.monospaced())
          .textSelection(.enabled)
      }

      if let art = challenge.presentedKey.visualArt {
        Text(art)
          .font(.system(.caption2, design: .monospaced))
          .padding(8)
          .background(Color(NSColor.textBackgroundColor))
          .clipShape(RoundedRectangle(cornerRadius: 4))
      }

      HStack(spacing: 12) {
        Button(AppLocalization.string("Trust & Connect")) {
          viewModel.approveTrustChallengeAndConnect()
        }
        .buttonStyle(WorkspacePrimaryButtonStyle())

        Button(AppLocalization.string("Cancel")) {
          viewModel.cancelTrust()
        }
        .buttonStyle(WorkspaceSecondaryButtonStyle())
      }
    }
    .padding(20)
    .background(Color.orange.opacity(0.1))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .frame(maxWidth: 500)
  }

  private func mismatchBlockedBanner(_ mismatch: (recorded: [SSHHostKeyRecord], presented: SSHHostKeyRecord)) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(AppLocalization.string("Host Key Mismatch — Connection Blocked"), systemImage: "xmark.shield.fill")
        .font(.headline)
        .foregroundStyle(.red)

      Text(AppLocalization.string("The host key presented by the server differs from the key saved in your known_hosts file. This could indicate a server re-installation or an active Man-in-the-Middle attack."))
        .font(.subheadline)

      VStack(alignment: .leading, spacing: 4) {
        Text(AppLocalization.format("Presented: %1$@", String(describing: mismatch.presented.fingerprintSHA256)))
          .font(.caption.monospaced())
          .foregroundStyle(.red)
        if let firstRec = mismatch.recorded.first {
          Text(AppLocalization.format("Recorded: %1$@", String(describing: firstRec.fingerprintSHA256)))
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
      }

      Text(AppLocalization.string("To connect, you must verify the key with your server administrator and remove or rotate the old key in Security → Known Hosts."))
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack {
        Button(AppLocalization.string("Close")) {
          NSApp.keyWindow?.performClose(nil)
        }
        .buttonStyle(WorkspaceSecondaryButtonStyle())
        Button(AppLocalization.string("Replace Trusted Key…"), role: .destructive) {
          confirmingRotation = true
        }
        .buttonStyle(WorkspaceSecondaryButtonStyle())
      }
      .confirmationDialog(
        AppLocalization.string("Replace the trusted key for this host?"), isPresented: $confirmingRotation, titleVisibility: .visible
      ) {
        Button(AppLocalization.string("Replace Key (verified with administrator)"), role: .destructive) {
          viewModel.rotateTrustAndConnect()
        }
      } message: {
        Text(AppLocalization.format("New fingerprint: %1$@. Only continue if it matches what the server administrator gave you. This is recorded in the audit log.", String(describing: mismatch.presented.fingerprintSHA256)))
      }
    }
    .padding(20)
    .background(Color.red.opacity(0.1))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .frame(maxWidth: 520)
  }

  // MARK: - Browser Content

  private var browserContentView: some View {
    VStack(spacing: 0) {
      navigationToolbar
      Divider()

      if viewModel.isLoadingDirectory && viewModel.entries.isEmpty {
        ProgressView(AppLocalization.string("Loading remote directory…"))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if viewModel.entries.isEmpty {
        ContentUnavailableView(AppLocalization.string("This directory is empty"), systemImage: "folder",
          description: Text(AppLocalization.string("Upload files or create a folder to get started.")))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        fileTable
      }
    }
    .dropDestination(for: URL.self) { urls, _ in
      guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
      uploadFiles(urls)
      return true
    }
  }

  private var navigationToolbar: some View {
    HStack(spacing: 8) {
      Button(AppLocalization.string("Back"), systemImage: "chevron.left") { viewModel.navigateBack() }
      .labelStyle(.iconOnly)
      .disabled(!viewModel.canNavigateBack)
      .help(AppLocalization.string("Back"))

      Button(AppLocalization.string("Forward"), systemImage: "chevron.right") { viewModel.navigateForward() }
      .labelStyle(.iconOnly)
      .disabled(!viewModel.canNavigateForward)
      .help(AppLocalization.string("Forward"))

      Button(AppLocalization.string("Enclosing Folder"), systemImage: "arrow.up") { viewModel.navigateUp() }
      .labelStyle(.iconOnly)
      .disabled(!viewModel.canNavigateUp)
      .help(AppLocalization.string("Enclosing Folder"))

      // Breadcrumb path display
      breadcrumbBar

      Spacer()

      TextField(AppLocalization.string("Filter"), text: $viewModel.searchQuery)
        .frame(width: 140)
        .textFieldStyle(.roundedBorder)

      Button {
        showingNewFolderDialog = true
      } label: {
        Label(AppLocalization.string("New Folder"), systemImage: "folder.badge.plus")
      }
      .keyboardShortcut("n", modifiers: [.command, .shift])
      .help(AppLocalization.string("Create new folder"))

      Button {
        pickAndUploadFile()
      } label: {
        Label(AppLocalization.string("Upload"), systemImage: "arrow.up.doc")
      }
      .help(AppLocalization.string("Upload file to current folder"))

      Button(AppLocalization.string("Refresh directory"), systemImage: "arrow.clockwise") {
        viewModel.loadDirectory(path: viewModel.currentPath)
      }
      .labelStyle(.iconOnly)
      .help(AppLocalization.string("Refresh directory"))
    }
    .buttonStyle(.borderless)
    .padding(12)
    .modifier(WorkspaceChrome())
    .padding(12)
  }

  private var breadcrumbBar: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 4) {
        Button("/") {
          viewModel.loadDirectory(path: "/")
        }
        .buttonStyle(.borderless)

        let segments = viewModel.currentPath.split(separator: "/").map(String.init)
        ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
          Text("/")
            .foregroundStyle(.tertiary)
          let targetPath = "/" + segments[0...index].joined(separator: "/")
          Button(segment) {
            viewModel.loadDirectory(path: targetPath)
          }
          .buttonStyle(.borderless)
          .fontWeight(index == segments.count - 1 ? .bold : .regular)
        }
      }
      .font(.callout.monospaced())
    }
  }

  private var fileTable: some View {
    Table(viewModel.filteredEntries, selection: $viewModel.selectedEntryIDs) {
      TableColumn(AppLocalization.string("Name")) { entry in
        HStack(spacing: 6) {
          Image(systemName: iconName(for: entry))
            .foregroundStyle(iconColor(for: entry))

          Text(entry.name)
            .lineLimit(1)

          if entry.isSymlink, let target = entry.symlinkTarget {
            Image(systemName: "arrow.right")
              .font(.caption)
              .foregroundStyle(.tertiary)
            Text(target)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        .contentShape(Rectangle())
        .accessibilityActions {
          if entry.isDirectory {
            Button(AppLocalization.string("Open Folder")) { viewModel.navigateTo(entry: entry) }
          }
        }
        .accessibilityAddTraits(entry.isDirectory ? .isButton : [])
      }
      .width(min: 240, ideal: 320)

      TableColumn(AppLocalization.string("Size")) { entry in
        Text(entry.isDirectory ? "--" : formatByteSize(entry.size))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .width(ideal: 90)

      TableColumn(AppLocalization.string("Permissions")) { entry in
        Text(entry.permissions)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }
      .width(ideal: 110)

      TableColumn(AppLocalization.string("Modified")) { entry in
        Text(entry.modificationDateString ?? "--")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .width(ideal: 140)
    }
    .contextMenu(forSelectionType: String.self) { selection in
      let entries = viewModel.entries(for: selection)
      if entries.count == 1, let entry = entries.first {
        if !entry.isDirectory {
          Button(AppLocalization.string("Download…")) { pickAndDownloadFile(entry: entry) }
        }
        Button(AppLocalization.string("Rename…")) {
          renameText = entry.name
          viewModel.entryPendingRename = entry
          showingRenameDialog = true
        }
      }
      if !entries.isEmpty {
        Button(AppLocalization.string("Delete"), role: .destructive) {
          viewModel.entriesPendingDeletion = entries
        }
      }
    } primaryAction: { selection in
      guard let entry = viewModel.entries(for: selection).first, selection.count == 1 else { return }
      if entry.isDirectory { viewModel.navigateTo(entry: entry) }
      else { pickAndDownloadFile(entry: entry) }
    }
    .onDeleteCommand {
      viewModel.entriesPendingDeletion = viewModel.entries(for: viewModel.selectedEntryIDs)
    }
  }

  // MARK: - Actions

  private func pickAndUploadFile() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    if panel.runModal() == .OK { uploadFiles(panel.urls) }
  }

  private func uploadFiles(_ urls: [URL]) {
    var rejectedFolder = false
    for url in urls where url.isFileURL {
      if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != false {
        rejectedFolder = true
      } else {
        viewModel.upload(localURL: url, queue: transferQueue)
      }
    }
    if rejectedFolder { viewModel.errorMessage = AppLocalization.string("Folder uploads are not supported yet.") }
  }

  private func pickAndDownloadFile(entry: SFTPFileEntry) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = AppLocalization.string("Download Here")
    if panel.runModal() == .OK, let dirURL = panel.url {
      viewModel.download(entry: entry, localDirectoryURL: dirURL, queue: transferQueue)
    }
  }

  // MARK: - Dialogs

  private var renameSheet: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(AppLocalization.string("Rename Item"))
        .font(.headline)

      TextField(AppLocalization.string("New name"), text: $renameText)
        .textFieldStyle(.roundedBorder)

      HStack {
        Spacer()
        Button(AppLocalization.string("Cancel")) {
          showingRenameDialog = false
          viewModel.entryPendingRename = nil
        }
        .keyboardShortcut(.cancelAction)

        Button(AppLocalization.string("Rename")) {
          if let target = viewModel.entryPendingRename {
            viewModel.renameEntry(target, to: renameText)
          }
          showingRenameDialog = false
        }
        .keyboardShortcut(.defaultAction)
        .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 320)
  }

  private var newFolderSheet: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(AppLocalization.string("New Remote Folder"))
        .font(.headline)

      TextField(AppLocalization.string("Folder name"), text: $newFolderName)
        .textFieldStyle(.roundedBorder)

      HStack {
        Spacer()
        Button(AppLocalization.string("Cancel")) {
          showingNewFolderDialog = false
          newFolderName = ""
        }
        .keyboardShortcut(.cancelAction)

        Button(AppLocalization.string("Create")) {
          viewModel.createFolder(name: newFolderName)
          newFolderName = ""
          showingNewFolderDialog = false
        }
        .keyboardShortcut(.defaultAction)
        .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 320)
  }

  // MARK: - Formatters

  private func iconName(for entry: SFTPFileEntry) -> String {
    if entry.isDirectory { return "folder.fill" }
    if entry.isSymlink { return "link" }
    return "doc"
  }

  private func iconColor(for entry: SFTPFileEntry) -> Color {
    if entry.isDirectory { return .blue }
    if entry.isSymlink { return .purple }
    return .secondary
  }

  private func formatByteSize(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
  }
}

#if DEBUG
#Preview("SFTPBrowserSheet") {
  SFTPBrowserSheet(host: PreviewFixtures.host, transferQueue: SFTPTransferQueue())
}
#endif
