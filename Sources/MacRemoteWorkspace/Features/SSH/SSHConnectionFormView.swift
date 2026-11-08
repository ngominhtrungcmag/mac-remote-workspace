import AppCore
import Observation
import SwiftUI

enum SheetAuthenticationMode: Hashable {
  case password, keychainCredential, sshAgent
}

@Observable final class SSHConnectionFormState {
  var username: String = NSUserName()
  var portString: String = "22"
  var proxyJumpExpanded = false
  var proxyJumpEnabled = false
  var jumpHost = ""
  var jumpUsername: String = NSUserName()
  var jumpPortString: String = "22"
  var validationError: String?
  var authenticationMode: SheetAuthenticationMode = .password
  var password: String = ""
  var savePasswordToKeychain: Bool = false
  var passwordCredentialLabel: String = ""
  var credentialRefs: [CredentialRefRecord] = []
  var selectedCredentialID: String?
  var credentialKeyFilePath: String = ""

  static func jumpComponents(_ value: String, defaultUser: String) -> (user: String, host: String, port: Int)? {
    let parts = value.split(separator: "@", omittingEmptySubsequences: false)
    guard (1...2).contains(parts.count), let last = parts.last else { return nil }
    let user = parts.count == 2 ? String(parts[0]) : defaultUser
    let endpoint = String(last)
    let host: String
    let port: Int
    if endpoint.hasPrefix("[") {
      guard let close = endpoint.firstIndex(of: "]") else { return nil }
      host = String(endpoint[endpoint.index(after: endpoint.startIndex)..<close])
      let suffix = endpoint[endpoint.index(after: close)...]
      if suffix.isEmpty { port = 22 }
      else if suffix.first == ":", let parsed = Int(suffix.dropFirst()) { port = parsed }
      else { return nil }
    } else {
      let hostParts = endpoint.split(separator: ":", omittingEmptySubsequences: false)
      guard (1...2).contains(hostParts.count), let parsed = hostParts.count == 2 ? Int(hostParts[1]) : 22 else { return nil }
      host = String(hostParts[0])
      port = parsed
    }
    guard !user.isEmpty, !host.isEmpty, (1...65535).contains(port) else { return nil }
    return (user, host, port)
  }
}

struct ConnectionFormView<Action: View>: View {
  @Bindable var form: SSHConnectionFormState
  let isConnectionConfigurationLocked: Bool
  let isDiagnosingConnection: Bool
  let performDiagnostics: () -> Void
  @ViewBuilder let action: () -> Action
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Preserve access to configuration actions in narrow windows.
      ScrollView(.horizontal) {
      HStack(spacing: 10) {
        HStack(spacing: 4) {
          Text(AppLocalization.string("User:"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
          TextField(AppLocalization.string("username"), text: $form.username)
            .textFieldStyle(.roundedBorder)
            .frame(width: 100)
            .disabled(isConnectionConfigurationLocked)
            .accessibilityLabel(AppLocalization.string("User"))
        }

        HStack(spacing: 4) {
          Text(AppLocalization.string("Port:"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
          TextField("22", text: $form.portString)
            .textFieldStyle(.roundedBorder)
            .frame(width: 50)
            .disabled(isConnectionConfigurationLocked)
            .accessibilityLabel(AppLocalization.string("Port"))
        }

        HStack(spacing: 4) {
          Text(AppLocalization.string("Auth:"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
          Picker(AppLocalization.string("Authentication"), selection: $form.authenticationMode) {
            Text(AppLocalization.string("Password")).tag(SheetAuthenticationMode.password)
            Text(AppLocalization.string("Keychain credential")).tag(SheetAuthenticationMode.keychainCredential)
            Text(AppLocalization.string("SSH agent")).tag(SheetAuthenticationMode.sshAgent)
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .frame(minWidth: 140, maxWidth: 165)
          .disabled(isConnectionConfigurationLocked)
          .accessibilityLabel(AppLocalization.string("Authentication method"))
        }

        Spacer()

        Button(form.proxyJumpEnabled ? AppLocalization.string("Diagnose Jump") : AppLocalization.string("Diagnose")) {
          performDiagnostics()
        }
        .buttonStyle(WorkspaceSecondaryButtonStyle())
        .disabled(isDiagnosingConnection || isConnectionConfigurationLocked)
        .accessibilityLabel(form.proxyJumpEnabled ? AppLocalization.string("Diagnose Jump Host") : AppLocalization.string("Diagnose Connection"))
        .accessibilityHint(AppLocalization.string("Checks DNS, TCP, and SSH negotiation without signing in or verifying host trust."))

        action()
      }
      }

      // Row 2: Authentication parameter row with ample horizontal space
      authenticationParametersRow

      // Row 3: Actionable validation or credential error banner
      if let error = form.validationError {
        HStack(spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
        }
        .accessibilityElement(children: .combine)
      }

      DisclosureGroup(AppLocalization.string("ProxyJump (optional)"), isExpanded: $form.proxyJumpExpanded) {
        VStack(alignment: .leading, spacing: 8) {
          Toggle(AppLocalization.string("Connect through an SSH jump host"), isOn: $form.proxyJumpEnabled)
            .disabled(isConnectionConfigurationLocked)
          if form.proxyJumpEnabled {
            HStack(spacing: 10) {
              TextField(AppLocalization.string("Jump host"), text: $form.jumpHost)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(AppLocalization.string("Jump host"))
              TextField(AppLocalization.string("Jump user"), text: $form.jumpUsername)
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
                .accessibilityLabel(AppLocalization.string("Jump user"))
              TextField(AppLocalization.string("Port"), text: $form.jumpPortString)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .accessibilityLabel(AppLocalization.string("Jump host port"))
            }
            .disabled(isConnectionConfigurationLocked)
            Text(AppLocalization.string("The jump host key is verified first. The target key is checked through that hop before target credentials are sent."))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .padding(.top, 6)
      }
      .font(.caption)
      .disabled(isConnectionConfigurationLocked)
    }
    .padding(12)
    .background(.bar)
  }

  @ViewBuilder
  private var authenticationParametersRow: some View {
    HStack(spacing: 12) {
      switch form.authenticationMode {
      case .password:
        HStack(spacing: 6) {
          Text(AppLocalization.string("Password:"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
          SecureField(AppLocalization.string("Password"), text: $form.password)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 150, maxWidth: 200)
            .disabled(isConnectionConfigurationLocked)
            .privacySensitive()
            .accessibilityLabel(AppLocalization.string("SSH Password"))
            .accessibilityHint(AppLocalization.string("Account password for remote SSH authentication"))
        }

        Toggle(AppLocalization.string("Save to Keychain"), isOn: $form.savePasswordToKeychain)
          .toggleStyle(.checkbox)
          .font(.caption)
          .fixedSize()
          .disabled(isConnectionConfigurationLocked)
          .accessibilityLabel(AppLocalization.string("Save password to macOS Keychain"))
          .accessibilityHint(AppLocalization.string("Securely saves password in Apple Keychain for future connections"))

        if form.savePasswordToKeychain {
          HStack(spacing: 4) {
            Text(AppLocalization.string("Label:"))
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize()
            TextField(AppLocalization.string("Optional label"), text: $form.passwordCredentialLabel)
              .textFieldStyle(.roundedBorder)
              .frame(minWidth: 120, maxWidth: 180)
              .disabled(isConnectionConfigurationLocked)
              .accessibilityLabel(AppLocalization.string("Keychain credential label"))
          }
        }

        Text(AppLocalization.string("Stored securely in Keychain."))
          .font(.caption)
          .foregroundStyle(.secondary)

      case .keychainCredential:
        HStack(spacing: 6) {
          Text(AppLocalization.string("Credential:"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
          Picker(AppLocalization.string("Keychain credential"), selection: $form.selectedCredentialID) {
            Text(AppLocalization.string("Choose…")).tag(String?.none)
            ForEach(form.credentialRefs) { record in
              Text("\(record.label) — \(record.kind.localizedTitle)").tag(String?.some(record.id))
            }
          }
          .pickerStyle(.menu)
          .frame(minWidth: 160, maxWidth: 240)
          .disabled(isConnectionConfigurationLocked)
          .accessibilityLabel(AppLocalization.string("Saved Keychain credential"))
        }

        HStack(spacing: 6) {
          Text(AppLocalization.string("Key file (optional):"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
          TextField("~/.ssh/id_ed25519", text: $form.credentialKeyFilePath)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 140, maxWidth: 200)
            .disabled(isConnectionConfigurationLocked)
            .accessibilityLabel(AppLocalization.string("Optional private key file path for passphrase authentication"))
        }

      case .sshAgent:
        Label(AppLocalization.string("Using active agent from SSH_AUTH_SOCK"), systemImage: "key.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize()
      }

      Spacer()
    }
  }

}

#if DEBUG
#Preview("ConnectionFormView") {
  ConnectionFormView(form: SSHConnectionFormState(), isConnectionConfigurationLocked: false,
    isDiagnosingConnection: false, performDiagnostics: {}) {
    Button("Connect") {}
  }
  .frame(width: 900, height: 220)
}
#endif
