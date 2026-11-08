import AppCore
import SwiftUI

struct HostTrustReviewView: View {
  @ObservedObject var viewModel: SSHSessionViewModel
  let challenge: SSHHostTrustChallenge
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 12) {
          Image(systemName: "questionmark.key.filled")
            .font(.largeTitle)
            .foregroundStyle(.orange)
          VStack(alignment: .leading, spacing: 4) {
            Text(viewModel.trustEndpointRole == .jumpHost ? AppLocalization.string("Unknown Jump Host Key") : AppLocalization.string("Unknown Host Key"))
              .font(.headline)
            Text(AppLocalization.format("The authenticity of endpoint '%1$@:%2$@' cannot be established.", String(describing: challenge.host), String(describing: challenge.port)))
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }

        Divider()

        Text(trustReviewInstructions)
          .font(.callout)

        VStack(alignment: .leading, spacing: 10) {
          LabeledContent(AppLocalization.string("Endpoint")) {
            Text("\(challenge.host):\(challenge.port)")
              .font(.system(.body, design: .monospaced))
          }
          LabeledContent(AppLocalization.string("Algorithm")) {
            Text(AppLocalization.format(
              "%1$@ (%2$@)%3$@",
              challenge.presentedKey.algorithm,
              challenge.presentedKey.keyType,
              challenge.presentedKey.bitLength.map { " " + AppLocalization.format("%1$@ bits", String($0)) } ?? ""
            ))
              .font(.system(.body, design: .monospaced))
          }
          LabeledContent(AppLocalization.string("SHA256 Fingerprint")) {
            Text(challenge.presentedKey.fingerprintSHA256)
              .font(.system(.body, design: .monospaced).bold())
              .textSelection(.enabled)
              .accessibilityLabel(AppLocalization.format("SHA256 Fingerprint %1$@", String(describing: challenge.presentedKey.fingerprintSHA256)))
          }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)

        if let art = challenge.presentedKey.visualArt {
          DisclosureGroup(AppLocalization.string("View Key Randomart")) {
            Text(art)
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
              .padding(8)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(Color(nsColor: .textBackgroundColor))
              .cornerRadius(6)
          }
        }

        HStack(spacing: 12) {
          Button(viewModel.trustEndpointRole == .jumpHost ? AppLocalization.string("Trust & Continue") : AppLocalization.string("Trust & Connect")) {
            viewModel.approveTrustChallenge()
          }
          .buttonStyle(WorkspacePrimaryButtonStyle())
          .accessibilityLabel(viewModel.trustEndpointRole == .jumpHost
            ? AppLocalization.string("Trust jump host key and continue")
            : AppLocalization.string("Trust host key and connect"))

          Button(AppLocalization.string("Reject & Cancel")) {
            viewModel.rejectTrustChallenge()
          }
          .buttonStyle(WorkspaceSecondaryButtonStyle())
          .accessibilityLabel(AppLocalization.string("Reject host key and cancel connection"))

          Spacer()
        }
        .padding(.top, 8)
      }
      .padding(20)
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var trustReviewInstructions: String {
    let verification = AppLocalization.string("Check this fingerprint with your system administrator or trusted records before trusting this host.")
    if viewModel.trustEndpointRole == .jumpHost {
      return AppLocalization.format(
        "This is the jump host. %1$@ The app authenticates to it only after approval, then checks the target key before sending target credentials.",
        verification
      )
    }
    if viewModel.hasProxyJump {
      return AppLocalization.format(
        "The target key was retrieved through the already verified jump host. %1$@ Target credentials have not been sent.",
        verification
      )
    }
    return AppLocalization.format("To prevent man-in-the-middle attacks, %1$@", verification)
  }

}

struct KeyMismatchView: View {
  @ObservedObject var viewModel: SSHSessionViewModel
  let recordedKeys: [SSHHostKeyRecord]
  let presentedKey: SSHHostKeyRecord
  @Binding var confirmingRotation: Bool
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 12) {
          Image(systemName: "exclamationmark.shield.fill")
            .font(.largeTitle)
            .foregroundStyle(.red)
          VStack(alignment: .leading, spacing: 4) {
            Text(AppLocalization.string("WARNING: Remote Host Identification Has Changed!"))
              .font(.headline)
              .foregroundStyle(.red)
            Text(mismatchSummary)
              .font(.subheadline)
              .bold()
          }
        }

        Divider()

        Text(mismatchExplanation)
          .font(.callout)

        VStack(alignment: .leading, spacing: 10) {
          Text(AppLocalization.string("Presented by remote server:"))
            .font(.caption).bold().foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 4) {
            Text(AppLocalization.format("Algorithm: %1$@ (%2$@)", String(describing: presentedKey.algorithm), String(describing: presentedKey.keyType)))
              .font(.system(.caption, design: .monospaced))
            Text(AppLocalization.format("Fingerprint: %1$@", String(describing: presentedKey.fingerprintSHA256)))
              .font(.system(.caption, design: .monospaced).bold())
              .textSelection(.enabled)
          }
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.red.opacity(0.1))
          .cornerRadius(6)

          if let existing = recordedKeys.first {
            Text(AppLocalization.string("Previously recorded in known_hosts:"))
              .font(.caption).bold().foregroundStyle(.secondary)
              .padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
              Text(AppLocalization.format("Algorithm: %1$@ (%2$@)", String(describing: existing.algorithm), String(describing: existing.keyType)))
                .font(.system(.caption, design: .monospaced))
              Text(AppLocalization.format("Fingerprint: %1$@", String(describing: existing.fingerprintSHA256)))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
          }
        }

        Text(AppLocalization.string("Resolution: If this key rotation is authorized, verify the new fingerprint with the server administrator, then replace the trusted key. The rotation is recorded in the audit log."))
          .font(.caption)
          .foregroundStyle(.secondary)

        HStack {
          Button(AppLocalization.string("Acknowledge & Close")) {
            viewModel.disconnect()
          }
          .buttonStyle(WorkspacePrimaryButtonStyle())
          .accessibilityLabel(AppLocalization.string("Acknowledge host key mismatch and close"))

          Button(AppLocalization.string("Replace Trusted Key…"), role: .destructive) { confirmingRotation = true }
            .accessibilityLabel(AppLocalization.string("Replace trusted host key"))
            .confirmationDialog(
              AppLocalization.string("Replace the trusted key for this host?"), isPresented: $confirmingRotation, titleVisibility: .visible
            ) {
              Button(AppLocalization.string("Replace Key (verified with administrator)"), role: .destructive) {
                viewModel.rotateMismatchedHostKey()
              }
            } message: {
              Text(AppLocalization.format("New fingerprint: %1$@. Only continue if it matches what the server administrator gave you.", String(describing: presentedKey.fingerprintSHA256)))
            }

          Spacer()
        }
        .padding(.top, 8)
      }
      .padding(20)
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var mismatchSummary: String {
    if viewModel.trustEndpointRole == .targetHost && viewModel.hasProxyJump {
      return AppLocalization.string("Blocked. Target credentials were not sent.")
    }
    return AppLocalization.string("Connection strictly blocked. No credentials were sent.")
  }

  private var mismatchExplanation: String {
    if viewModel.trustEndpointRole == .targetHost && viewModel.hasProxyJump {
      return AppLocalization.string("The target key does not match the recorded key. Target authentication is blocked; authentication to the verified jump host may have occurred to reach this endpoint.")
    }
    return AppLocalization.string("Someone could be eavesdropping on you, or the server host key has been rotated. Mac Remote Workspace cannot automatically trust or override mismatched host keys.")
  }
}

struct TunnelPanelView: View {
  @ObservedObject var viewModel: SSHSessionViewModel
  let isRunning: Bool
  @Binding var localPortString: String
  @Binding var tunnelRemoteHost: String
  @Binding var tunnelRemotePortString: String
  @Binding var tunnelValidationError: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label(AppLocalization.string("Local SSH Tunnels"), systemImage: "point.3.connected.trianglepath.dotted")
          .font(.headline)
        Spacer()
        Text(AppLocalization.format("Loopback only · %1$@/%2$@", String(describing: viewModel.localTunnels.count), String(describing: NativeSSHSession.maximumLocalTunnels)))
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 8) {
        TextField(AppLocalization.string("Local port"), text: $localPortString)
          .frame(width: 100)
          .accessibilityLabel(AppLocalization.string("Local tunnel port"))
        TextField(AppLocalization.string("Remote host"), text: $tunnelRemoteHost)
          .accessibilityLabel(AppLocalization.string("Remote tunnel target host"))
        TextField(AppLocalization.string("Remote port"), text: $tunnelRemotePortString)
          .frame(width: 110)
          .accessibilityLabel(AppLocalization.string("Remote tunnel target port"))
        Button(AppLocalization.string("Start Tunnel"), systemImage: "plus") {
          startTunnelFromForm()
        }
        .disabled(!isRunning || viewModel.localTunnels.count >= NativeSSHSession.maximumLocalTunnels)
      }

      if let error = tunnelValidationError ?? viewModel.tunnelError {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
      }

      if viewModel.localTunnels.isEmpty {
        Text(AppLocalization.string("No active tunnels. Choose a local port and remote service endpoint."))
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(viewModel.localTunnels) { tunnel in
          HStack(spacing: 10) {
            Text("127.0.0.1:\(tunnel.configuration.localPort) → \(tunnel.configuration.remoteHost):\(tunnel.configuration.remotePort)")
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
            tunnelStateLabel(tunnel.state)
            Button(AppLocalization.string("Stop")) {
              viewModel.stopLocalTunnel(id: tunnel.id)
            }
            .buttonStyle(WorkspaceSecondaryButtonStyle())
            .accessibilityLabel(AppLocalization.format("Stop tunnel on local port %1$@", String(describing: tunnel.configuration.localPort)))
          }
          .padding(.vertical, 3)
        }
      }
    }
    .padding(12)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  @ViewBuilder
  private func tunnelStateLabel(_ state: NativeSSHTunnelState) -> some View {
    switch state {
    case .starting:
      Label(AppLocalization.string("Starting"), systemImage: "hourglass")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .running:
      Label(AppLocalization.string("Running"), systemImage: "checkmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.green)
    case .failed(let exitCode):
      Label(AppLocalization.format("Failed (%1$@)", String(describing: exitCode)), systemImage: "exclamationmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.red)
    case .stopped:
      Label(AppLocalization.string("Stopped"), systemImage: "stop.circle")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func startTunnelFromForm() {
    guard let localPort = Int(localPortString), (1...65535).contains(localPort) else {
      tunnelValidationError = AppLocalization.string("Local port must be between 1 and 65535.")
      return
    }
    guard let remotePort = Int(tunnelRemotePortString), (1...65535).contains(remotePort) else {
      tunnelValidationError = AppLocalization.string("Remote port must be between 1 and 65535.")
      return
    }
    tunnelValidationError = nil
    viewModel.startLocalTunnel(
      localPort: localPort,
      remoteHost: tunnelRemoteHost.trimmingCharacters(in: .whitespacesAndNewlines),
      remotePort: remotePort
    )
  }

}

struct SessionStatusBar: View {
  @ObservedObject var viewModel: SSHSessionViewModel
  let username: String
  let portString: String
  let isAuthRejectionOutput: Bool
  var body: some View {
    HStack(spacing: 12) {
      statusIndicator
      VStack(alignment: .leading, spacing: 2) {
        Text("\(username)@\(viewModel.host.address):\(portString)")
          .font(.system(.subheadline, design: .monospaced).bold())
        statusDescription
      }
      Spacer()
      EnvironmentBadge(environment: viewModel.host.environment)
    }
    .padding(12)
    .background(.background)
  }

  @ViewBuilder
  private var statusIndicator: some View {
    switch viewModel.status {
    case .idle:
      Circle().fill(Color.gray).frame(width: 10, height: 10)
    case .verifyingHost:
      ProgressView().controlSize(.small)
    case .hostTrustRequired:
      Circle().fill(Color.orange).frame(width: 10, height: 10)
    case .hostKeyMismatch:
      Circle().fill(Color.red).frame(width: 10, height: 10)
    case .connecting:
      ProgressView().controlSize(.small)
    case .running:
      Circle().fill(Color.green).frame(width: 10, height: 10)
    case .disconnected(let exitCode):
      if exitCode == 255 && isAuthRejectionOutput {
        Circle().fill(Color.red).frame(width: 10, height: 10)
      } else {
        Circle().fill(Color.secondary).frame(width: 10, height: 10)
      }
    case .failed:
      Circle().fill(Color.red).frame(width: 10, height: 10)
    }
  }

  @ViewBuilder
  private var statusDescription: some View {
    switch viewModel.status {
    case .idle:
      Text(AppLocalization.string("Session idle — verify host trust, choose authentication, then click Connect"))
        .font(.caption)
        .foregroundStyle(.secondary)
    case .verifyingHost(let host, let port):
      let endpointRole = AppLocalization.string(viewModel.trustEndpointRole == .jumpHost ? "jump host" : "target host")
      Text(AppLocalization.format("Checking the %1$@ key for %2$@:%3$@…", endpointRole, host, String(port)))
        .font(.caption)
        .foregroundStyle(.secondary)
    case .hostTrustRequired:
      Text(trustChallengeStatus)
        .font(.caption)
        .foregroundStyle(.orange)
    case .hostKeyMismatch:
      Text(viewModel.trustEndpointRole == .jumpHost
        ? AppLocalization.string("Jump host key mismatch — blocked before jump authentication")
        : AppLocalization.string("Host key mismatch — target authentication is blocked"))
        .font(.caption)
        .foregroundStyle(.red)
    case .connecting:
      Text(AppLocalization.string("Connecting through verified hosts…"))
        .font(.caption)
        .foregroundStyle(.secondary)
    case .running:
      Text(AppLocalization.string("Connected"))
        .font(.caption)
        .foregroundStyle(.secondary)
    case .disconnected(let exitCode):
      if exitCode == 255 && isAuthRejectionOutput {
        Text(AppLocalization.string("Authentication failed. Check your username and password, then try again."))
          .font(.caption)
          .foregroundStyle(.red)
      } else {
                Text(AppLocalization.string("Disconnected"))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    case .failed(let message):
      Text(AppLocalization.format("Connection failed: %1$@", String(describing: message)))
        .font(.caption)
        .foregroundStyle(.red)
    }
  }

  private var trustChallengeStatus: String {
    if viewModel.trustEndpointRole == .jumpHost {
      return AppLocalization.string("Unknown jump key — approval required before jump authentication")
    }
    if viewModel.hasProxyJump {
      return AppLocalization.string("Unknown target key — target authentication is withheld")
    }
    return AppLocalization.string("Unknown host key — verification required before authentication")
  }

}

#if DEBUG
#Preview("TunnelPanelView") {
  TunnelPanelView(viewModel: SSHSessionViewModel(host: PreviewFixtures.host), isRunning: false, localPortString: .constant("5432"), tunnelRemoteHost: .constant("127.0.0.1"), tunnelRemotePortString: .constant("5432"), tunnelValidationError: .constant(nil)).frame(width: 600, height: 400)
}

#Preview("SessionStatusBar") {
  SessionStatusBar(viewModel: SSHSessionViewModel(host: PreviewFixtures.host), username: "user", portString: "22", isAuthRejectionOutput: false).frame(width: 700, height: 80)
}

#endif
#if DEBUG
#Preview("HostTrustReviewView") {
  HostTrustReviewView(viewModel: SSHSessionViewModel(host: PreviewFixtures.host),
    challenge: SSHHostTrustChallenge(host: "example.test", port: 22, presentedKey: PreviewFixtures.hostKey))
    .frame(width: 700, height: 500)
}

#Preview("KeyMismatchView") {
  KeyMismatchView(viewModel: SSHSessionViewModel(host: PreviewFixtures.host), recordedKeys: [PreviewFixtures.hostKey],
    presentedKey: PreviewFixtures.hostKey, confirmingRotation: .constant(false)).frame(width: 700, height: 500)
}
#endif
