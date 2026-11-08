import AppCore
import SwiftUI

struct HostEditorSheet: View {
  @Environment(\.dismiss) private var dismiss
  @FocusState private var nameFocused: Bool
  @State private var displayName: String
  @State private var address: String
  @State private var environment: HostEnvironment
  @State private var workspaceID: String
  @State private var groupID: String
  @State private var tagsText: String
  @State private var sshEnabled: Bool
  @State private var rdpEnabled: Bool
  @State private var fieldErrors: [HostEditorValidation.Field: String] = [:]
  @State private var validationError: String?
  @State private var preset: SSHConnectionPreset
  @State private var portString: String
  @State private var credentialRefs: [CredentialRefRecord] = []
  @State private var password = ""
  @State private var rdpPort = "3389"
  @State private var rdpUsername = ""
  @State private var rdpCredentialID: String?

  let host: HostRecord?
  let workspaces: [WorkspaceRecord]
  let groups: [HostGroupRecord]
  let preferredWorkspaceID: String?
  let preferredGroupID: String?
  let onSave: (HostDraft) throws -> HostRecord

  init(
    host: HostRecord?,
    workspaces: [WorkspaceRecord],
    groups: [HostGroupRecord],
    preferredWorkspaceID: String?,
    preferredGroupID: String?,
    onSave: @escaping (HostDraft) throws -> HostRecord
  ) {
    self.host = host
    self.workspaces = workspaces
    self.groups = groups
    self.preferredWorkspaceID = preferredWorkspaceID
    self.preferredGroupID = preferredGroupID
    self.onSave = onSave
    _displayName = State(initialValue: host?.displayName ?? "")
    _address = State(initialValue: host?.address ?? "")
    _environment = State(initialValue: host?.environment ?? .development)
    _workspaceID = State(initialValue: host?.workspaceID ?? preferredWorkspaceID ?? workspaces.first?.id ?? "")
    _groupID = State(initialValue: host?.groupID ?? preferredGroupID ?? "")
    _tagsText = State(initialValue: host?.tags.joined(separator: ", ") ?? "")
    _sshEnabled = State(initialValue: host.map { $0.protocols.contains("ssh") } ?? true)
    _rdpEnabled = State(initialValue: host.map { $0.protocols.contains("rdp") } ?? false)
    let preset = host.flatMap { SSHConnectionPreset.load(hostID: $0.id) } ?? SSHConnectionPreset()
    _preset = State(initialValue: preset)
    _portString = State(initialValue: String(preset.port))
  }

  private var selectedWorkspaceGroups: [HostGroupRecord] {
    groups.filter { $0.workspaceID == workspaceID }
  }

  var body: some View {
    NavigationStack {
      Form {
        Section(AppLocalization.string("Host")) {
          TextField(AppLocalization.string("Name"), text: $displayName)
            .focused($nameFocused)
            .accessibilityLabel(AppLocalization.string("Host name"))
          fieldError(.name)
          TextField(AppLocalization.string("Address"), text: $address)
            .accessibilityLabel(AppLocalization.string("Host address"))
          fieldError(.address)
          TextField(AppLocalization.string("Tags (comma-separated)"), text: $tagsText)
          fieldError(.tags)
          Toggle("SSH", isOn: $sshEnabled)
          Toggle("RDP", isOn: $rdpEnabled)
          Picker(AppLocalization.string("Environment"), selection: $environment) {
            ForEach(HostEnvironment.allCases) { value in
              Text(value.localizedTitle).tag(value)
            }
          }
        }

        if sshEnabled { sshSection }

        if rdpEnabled { rdpSection }

        Section(AppLocalization.string("Workspace")) {
          if !workspaces.isEmpty {
            Picker(AppLocalization.string("Workspace"), selection: $workspaceID) {
              ForEach(workspaces) { workspace in Text(workspace.name).tag(workspace.id) }
            }
            .onChange(of: workspaceID) { _, selectedWorkspaceID in
              if !groups.contains(where: { $0.id == groupID && $0.workspaceID == selectedWorkspaceID }) { groupID = "" }
            }
          } else {
            Text(AppLocalization.string("A Local workspace will be created when you save this host."))
              .foregroundStyle(.secondary)
          }
        }
        Section(AppLocalization.string("Group")) {
          Picker(AppLocalization.string("Group"), selection: $groupID) {
            Text(AppLocalization.string("Ungrouped")).tag("")
            ForEach(selectedWorkspaceGroups) { group in Text(group.name).tag(group.id) }
          }
        }

        if let validationError {
          Text(validationError)
            .foregroundStyle(.red)
            .accessibilityAddTraits(.updatesFrequently)
        }
      }
      .formStyle(.grouped)
      .navigationTitle(host == nil ? AppLocalization.string("Add Host") : AppLocalization.string("Edit Host"))
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(AppLocalization.string("Cancel")) { dismiss() }
            .keyboardShortcut(.cancelAction)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(AppLocalization.string("Save"), action: save)
            .buttonStyle(WorkspacePrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
      }
      .frame(minWidth: 440, minHeight: 380)
      .onAppear { nameFocused = host == nil }
      .task { loadCredentialRefs() }
    }
  }

  private var sshSection: some View {
    Section {
      TextField(AppLocalization.string("Username"), text: $preset.username)
      fieldError(.sshUsername)
      TextField(AppLocalization.string("Port"), text: $portString)
      fieldError(.sshPort)
      TextField(AppLocalization.string("ProxyJump (optional)"), text: Binding(
        get: { preset.proxyJump ?? "" }, set: { preset.proxyJump = $0.isEmpty ? nil : $0 }))
      fieldError(.proxyJump)
      Picker(AppLocalization.string("Authentication"), selection: $preset.auth) {
        Text(AppLocalization.string("Password")).tag(SSHConnectionPreset.Auth.password)
        Text(AppLocalization.string("Saved Keychain credential")).tag(SSHConnectionPreset.Auth.keychainCredential)
        Text(AppLocalization.string("SSH agent")).tag(SSHConnectionPreset.Auth.sshAgent)
      }
      if preset.auth == .password {
        SecureField(AppLocalization.string("Password"), text: $password, prompt: Text(AppLocalization.string("Leave empty to ask on connect")))
          .accessibilityLabel(AppLocalization.string("SSH password, saved to Keychain"))
      }
      if preset.auth == .keychainCredential {
        Picker(AppLocalization.string("Credential"), selection: $preset.credentialID) {
          Text(AppLocalization.string("Choose…")).tag(String?.none)
          ForEach(credentialRefs) { record in
            Text("\(record.label) — \(record.kind.localizedTitle)").tag(String?.some(record.id))
          }
        }
        TextField(AppLocalization.string("Key file (optional)"), text: $preset.keyFilePath, prompt: Text("~/.ssh/id_ed25519"))
      }
    } header: {
      Text(AppLocalization.string("SSH Connection"))
    } footer: {
      Text(AppLocalization.string("Pre-fills Connect. A password entered here is stored in Keychain, never in plaintext."))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var rdpSection: some View {
    Section {
      TextField(AppLocalization.string("Username"), text: $rdpUsername)
        .accessibilityLabel(AppLocalization.string("RDP username"))
      fieldError(.rdpUsername)
      TextField(AppLocalization.string("Port"), text: $rdpPort)
        .accessibilityLabel(AppLocalization.string("RDP port"))
      fieldError(.rdpPort)
      Picker(AppLocalization.string("Keychain Credential"), selection: $rdpCredentialID) {
        Text(AppLocalization.string("None")).tag(String?.none)
        ForEach(credentialRefs) { record in
          Text("\(record.label) — \(record.kind.localizedTitle)").tag(String?.some(record.id))
        }
      }
    } header: {
      Text(AppLocalization.string("Remote Desktop (RDP)"))
    } footer: {
      Text(AppLocalization.string("Use DOMAIN\\user or user@domain for Windows domain accounts. Manage passwords in Security → Credentials."))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func fieldError(_ field: HostEditorValidation.Field) -> some View {
    if let error = fieldErrors[field] {
      Text(AppLocalization.string(error)).font(.caption).foregroundStyle(.red)
        .accessibilityAddTraits(.updatesFrequently)
    }
  }

  private func loadCredentialRefs() {
    guard let repository = try? SQLiteHostRepository.openApplicationRepository() else { return }
    credentialRefs = (try? repository.listCredentialRefs()) ?? []
    if let host, let profile = try? repository.rdpProfileDefaults(hostID: host.id) {
      rdpPort = String(profile.port)
      rdpUsername = profile.username
      rdpCredentialID = profile.credentialRefID
    }
    try? repository.close()
  }

  private func save() {
    fieldErrors = HostEditorValidation.errors(name: displayName, address: address, tags: tagsText,
      sshEnabled: sshEnabled, username: preset.username, sshPort: portString, proxyJump: preset.proxyJump,
      rdpEnabled: rdpEnabled, rdpUsername: rdpUsername, rdpPort: rdpPort, hasRdpCredential: rdpCredentialID != nil)
    guard fieldErrors.isEmpty else { return }
    let selectedGroupID = selectedWorkspaceGroups.first(where: { $0.id == groupID })?.id
    let draft = HostDraft(displayName: displayName, address: address, environment: environment,
      workspaceID: workspaceID.isEmpty ? nil : workspaceID, groupID: selectedGroupID,
      tags: HostEditorValidation.tags(tagsText), protocols: (sshEnabled ? ["ssh"] : []) + (rdpEnabled ? ["rdp"] : []))
    let username = preset.username.trimmingCharacters(in: .whitespacesAndNewlines)
    let port = Int(portString) ?? preset.port
    let remotePort = Int(rdpPort) ?? 3389
    let remoteUser = rdpUsername.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      let saved = try onSave(draft)
      if rdpEnabled && !remoteUser.isEmpty {
        let repository = try SQLiteHostRepository.openApplicationRepository()
        defer { try? repository.close() }
        try repository.upsertRdpProfile(hostID: saved.id, port: remotePort, username: remoteUser, credentialRefID: rdpCredentialID)
      }
      var preset = preset
      preset.username = username
      preset.port = port
      if sshEnabled && preset.auth == .password && !password.isEmpty {
        let prepared = try SSHPasswordAuthenticationService().preparePasswordAuthentication(
          secret: ProtectedSecret(data: Data(password.utf8)),
          saveToKeychain: true,
          label: nil,
          defaultLabel: "\(saved.displayName) (\(username))"
        )
        password = ""
        if let record = prepared.savedRecord {
          preset.auth = .keychainCredential
          preset.credentialID = record.id
        }
      }
      if sshEnabled { try preset.saveThrowing(hostID: saved.id) }
      dismiss()
    } catch {
      validationError = error.localizedDescription
    }
  }
}


enum HostEditorValidation {
  enum Field: Hashable { case name, address, tags, sshUsername, sshPort, proxyJump, rdpUsername, rdpPort }

  static func tags(_ text: String) -> [String] {
    text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
  }

  static func errors(name: String, address: String, tags: String, sshEnabled: Bool, username: String,
    sshPort: String, proxyJump: String?, rdpEnabled: Bool, rdpUsername: String, rdpPort: String,
    hasRdpCredential: Bool) -> [Field: String] {
    var result: [Field: String] = [:]
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedName.isEmpty || trimmedName.unicodeScalars.count > 120 || trimmedName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
      result[.name] = "Enter a valid host name (up to 120 characters)."
    }
    let addressCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:_")
    if trimmedAddress.isEmpty || trimmedAddress.utf8.count > 253 || trimmedAddress.hasPrefix("-") || trimmedAddress.hasPrefix(".") || trimmedAddress.hasSuffix(".") || !trimmedAddress.unicodeScalars.allSatisfy(addressCharacters.contains) {
      result[.address] = "Enter a valid host address."
    }
    if self.tags(tags).contains(where: { $0.unicodeScalars.count > 80 || $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) {
      result[.tags] = "Tags must be 80 characters or fewer and contain no control characters."
    }
    if sshEnabled {
      let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
      if user.isEmpty || (try? SSHConnectionSettings.validateProxyJump("\(user)@example.test")) == nil { result[.sshUsername] = "SSH username is invalid." }
      if !(Int(sshPort).map { (1...65535).contains($0) } ?? false) { result[.sshPort] = "SSH port must be between 1 and 65535." }
      if let proxyJump, !proxyJump.isEmpty, (try? SSHConnectionSettings.validateProxyJump(proxyJump)) == nil {
        result[.proxyJump] = "Enter a valid ProxyJump endpoint."
      }
    }
    if rdpEnabled {
      let port = Int(rdpPort)
      if !(port.map { (1...65535).contains($0) } ?? false) { result[.rdpPort] = "RDP port must be between 1 and 65535." }
      if rdpUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (hasRdpCredential || port != 3389) {
        result[.rdpUsername] = "Enter an RDP username to save the RDP settings."
      }
    }
    return result
  }
}

#if DEBUG
#Preview("HostEditorSheet") {
  HostEditorSheet(host: PreviewFixtures.host, workspaces: [], groups: [], preferredWorkspaceID: nil, preferredGroupID: nil, onSave: { _ in PreviewFixtures.host })
}
#endif
