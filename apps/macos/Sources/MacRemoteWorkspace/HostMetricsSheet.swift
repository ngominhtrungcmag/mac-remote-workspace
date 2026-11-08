import AppCore
import SwiftUI

public struct HostMetricsSheet: View {
  let host: HostRecord
  @StateObject private var viewModel: HostMetricsViewModel
  @State private var confirmingRotation = false
  @Environment(\.dismiss) private var dismiss

  public init(host: HostRecord) {
    self.host = host
    _viewModel = StateObject(wrappedValue: HostMetricsViewModel(host: host))
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label(AppLocalization.format("Metrics: %1$@", String(describing: host.displayName)), systemImage: "gauge.with.dots.needle.33percent")
          .font(.headline)
        Spacer()
        Button(AppLocalization.string("Close")) { viewModel.stop(); dismiss() }.keyboardShortcut(.cancelAction)
      }
      Divider()

      if let challenge = viewModel.trustChallenge {
        VStack(alignment: .leading, spacing: 8) {
          Label(AppLocalization.string("Unknown Host Key"), systemImage: "shield.lefthalf.filled").foregroundStyle(.orange)
          Text(AppLocalization.format("Host '%1$@:%2$@' is not trusted yet.", String(describing: challenge.host), String(describing: challenge.port)))
          Text(AppLocalization.format("Fingerprint: %1$@", String(describing: challenge.presentedKey.fingerprintSHA256)))
            .font(.caption.monospaced()).textSelection(.enabled)
          HStack {
            Button(AppLocalization.string("Trust & Refresh")) { viewModel.approveTrustChallengeAndRefresh() }
              .buttonStyle(WorkspacePrimaryButtonStyle())
            Button(AppLocalization.string("Cancel")) { viewModel.cancelTrust() }
          }
        }
      } else if let mismatch = viewModel.mismatchBlocked {
        VStack(alignment: .leading, spacing: 6) {
          Label(AppLocalization.string("Host Key Mismatch - Blocked"), systemImage: "exclamationmark.octagon.fill")
            .foregroundStyle(.red)
          Text(AppLocalization.format("The presented key (%1$@) differs from the trusted key. No command was run.", String(describing: mismatch.presented.fingerprintSHA256)))
            .font(.caption)
          Button(AppLocalization.string("Replace Trusted Key…"), role: .destructive) { confirmingRotation = true }
            .confirmationDialog(
              AppLocalization.string("Replace the trusted key for this host?"), isPresented: $confirmingRotation, titleVisibility: .visible
            ) {
              Button(AppLocalization.string("Replace Key (verified with administrator)"), role: .destructive) {
                viewModel.rotateTrustAndRefresh()
              }
            } message: {
              Text(AppLocalization.format("New fingerprint: %1$@. Only continue if it matches what the server administrator gave you. This is recorded in the audit log.", String(describing: mismatch.presented.fingerprintSHA256)))
            }
        }
      } else {
        connectionForm
        if let metrics = viewModel.metrics { metricsGrid(metrics) }
        if let error = viewModel.errorMessage {
          Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(24)
    .frame(minWidth: 460, minHeight: 380)
    .onDisappear { viewModel.stop() }
  }

  private var connectionForm: some View {
    VStack(alignment: .leading, spacing: 8) {
      LabeledContent(AppLocalization.string("Username")) {
        TextField(AppLocalization.string("User"), text: $viewModel.username)
          .accessibilityLabel(AppLocalization.string("SSH username"))
      }
      LabeledContent(AppLocalization.string("Port")) {
        TextField(AppLocalization.string("Port"), text: $viewModel.portString)
          .accessibilityLabel(AppLocalization.string("SSH port"))
      }
      Picker(AppLocalization.string("Authentication"), selection: $viewModel.authMethod) {
        ForEach(HostMetricsAuthMethod.allCases) { Text($0.localizedTitle).tag($0) }
      }
      if viewModel.authMethod == .keychain {
        if viewModel.availableCredentials.isEmpty {
          Text(AppLocalization.string("No credentials saved. Add one in Security → Credentials."))
            .font(.caption).foregroundStyle(.secondary)
        } else {
          Picker(AppLocalization.string("Credential"), selection: $viewModel.selectedCredentialID) {
            ForEach(viewModel.availableCredentials) { Text($0.label).tag(String?.some($0.id)) }
          }
        }
      }
      HStack {
        Button { viewModel.refresh() } label: {
          if viewModel.isLoading { ProgressView().controlSize(.small) } else { Text(AppLocalization.string("Refresh")) }
        }
        .buttonStyle(WorkspacePrimaryButtonStyle())
        .accessibilityLabel(viewModel.isLoading ? AppLocalization.string("Refreshing metrics") : AppLocalization.string("Refresh metrics"))
        .disabled(viewModel.isLoading)
        Picker(AppLocalization.string("Polling"), selection: $viewModel.pollInterval) {
          ForEach(HostMetricsPollInterval.allCases) { Text($0.label).tag($0) }
        }
        .frame(width: 200)
        if let updated = viewModel.lastUpdated {
          Text(AppLocalization.format("Updated %1$@", String(describing: updated.formatted(date: .omitted, time: .standard))))
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  private func metricsGrid(_ m: RemoteHostMetrics) -> some View {
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
      row(AppLocalization.string("OS"), m.operatingSystem == "Darwin" ? "macOS" : m.operatingSystem)
      row(AppLocalization.string("Load average (1/5/15 min)"), String(format: "%.2f  %.2f  %.2f", m.load1, m.load5, m.load15))
      row(AppLocalization.string("Memory"), AppLocalization.format("%1$@ of %2$@", percent(m.memoryUsedFraction), bytes(m.memoryTotalBytes)))
      row(AppLocalization.string("Disk usage (/)"), AppLocalization.format("%1$@ of %2$@", percent(m.diskUsedFraction), bytes(m.diskTotalBytes)))
      row(AppLocalization.string("Uptime"), uptime(m.uptimeSeconds))
    }
    .accessibilityElement(children: .contain)
  }

  private func row(_ title: String, _ value: String) -> some View {
    GridRow {
      Text(title).foregroundStyle(.secondary)
      Text(value).monospacedDigit()
    }
  }

  private func percent(_ f: Double) -> String { String(format: "%.0f%%", f * 100) }
  private func bytes(_ n: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(min(n, UInt64(Int64.max))), countStyle: .binary) }
  private func uptime(_ s: UInt64) -> String {
    AppLocalization.format(
      "%1$@ days, %2$@ hours, %3$@ minutes",
      String(s / 86400),
      String(s % 86400 / 3600),
      String(s % 3600 / 60)
    )
  }
}
