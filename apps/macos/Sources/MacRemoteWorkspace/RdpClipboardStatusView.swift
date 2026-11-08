import SwiftUI

struct RdpClipboardStatusView: View {
  let message: String
  let busy: Bool
  let onCancel: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      if busy { ProgressView().controlSize(.small) }
      Text(Self.localizedMessage(message)).font(.callout)
      if busy {
        Button(AppLocalization.string("Cancel Transfer"), action: onCancel)
          .accessibilityLabel(AppLocalization.string("Cancel clipboard file transfer"))
      }
    }
    .padding(12)
    .modifier(WorkspaceChrome())
    .accessibilityElement(children: .contain)
  }

  nonisolated static func localizedMessage(_ message: String, locale: Locale? = nil) -> String {
    // shortcut: parses the current English IPC progress wording; replace with typed status data if that contract changes.
    let prefix = "Receiving clipboard file "
    let suffix = "…"
    guard message.hasPrefix(prefix), message.hasSuffix(suffix) else {
      return AppLocalization.string(message, locale: locale)
    }

    let progress = message.dropFirst(prefix.count).dropLast(suffix.count).split(separator: " ")
    guard progress.count == 3, progress[1] == "of",
      let current = Int(progress[0]), let total = Int(progress[2]), current > 0, current <= total
    else { return AppLocalization.string(message, locale: locale) }

    return AppLocalization.format(
      "Receiving clipboard file %1$@ of %2$@…", String(progress[0]), String(progress[2]), locale: locale)
  }
}
