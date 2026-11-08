import AppCore
import SwiftUI

struct SSHConnectionDiagnosticsPanel: View {
  let isRunning: Bool
  let report: SSHConnectionDiagnosticReport?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(AppLocalization.string("Connection Diagnostics"))
        .font(.headline)

      if isRunning {
        ProgressView(AppLocalization.string("Checking DNS, TCP, and SSH negotiation…"))
          .accessibilityLabel(AppLocalization.string("Connection diagnostics running"))
      } else if let report {
        stageRow("DNS", report.dnsResolution)
        stageRow("TCP", report.tcpConnection)
        stageRow(AppLocalization.string("SSH handshake"), report.sshHandshake)
        Text(AppLocalization.string("This pre-authentication probe does not verify host trust, test credentials, or modify known_hosts. SSH timing includes its own TCP connection."))
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(AppLocalization.string("Connection diagnostics"))
  }

  private func stageRow(_ title: String, _ stage: SSHConnectionDiagnosticStage) -> some View {
    HStack(spacing: 8) {
      Label(title, systemImage: symbol(for: stage.status))
        .frame(width: 145, alignment: .leading)
      Text(statusText(for: stage))
        .foregroundStyle(color(for: stage.status))
      Spacer(minLength: 0)
      if let duration = stage.durationMilliseconds {
        Text(AppLocalization.format("%1$@ ms", String(describing: duration)))
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
      }
    }
    .font(.callout)
    .accessibilityElement(children: .combine)
  }

  private func symbol(for status: SSHConnectionDiagnosticStatus) -> String {
    switch status {
    case .succeeded: "checkmark.circle.fill"
    case .failed: "xmark.circle.fill"
    case .skipped: "minus.circle"
    }
  }

  private func color(for status: SSHConnectionDiagnosticStatus) -> Color {
    switch status {
    case .succeeded: .green
    case .failed: .red
    case .skipped: .secondary
    }
  }

  private func statusText(for stage: SSHConnectionDiagnosticStage) -> String {
    switch stage.status {
    case .succeeded:
      AppLocalization.string("Passed")
    case .skipped:
      AppLocalization.string("Not run")
    case .failed(let failure):
      switch failure {
      case .invalidEndpoint: AppLocalization.string("Invalid endpoint")
      case .dnsResolutionFailed: AppLocalization.string("Name resolution failed")
      case .tcpConnectionTimedOut: AppLocalization.string("Connection timed out")
      case .tcpConnectionRefused: AppLocalization.string("Connection refused")
      case .tcpConnectionFailed: AppLocalization.string("Connection failed")
      case .sshHandshakeFailed: AppLocalization.string("SSH negotiation failed")
      }
    }
  }
}

#if DEBUG
#Preview("SSHConnectionDiagnosticsPanel") {
  SSHConnectionDiagnosticsPanel(isRunning: false, report: nil).frame(width: 600, height: 400)
}

#endif
