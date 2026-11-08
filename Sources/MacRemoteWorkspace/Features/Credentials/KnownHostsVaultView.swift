import AppCore
import SwiftUI

public struct KnownHostsVaultView: View {
  @StateObject private var viewModel: KnownHostsViewModel
  @State private var showingRandomartSheet = false

  public init(viewModel: @autoclosure @escaping () -> KnownHostsViewModel = KnownHostsViewModel()) {
    _viewModel = StateObject(wrappedValue: viewModel())
  }

  public var body: some View {
    VStack(spacing: 0) {
      if viewModel.isLoading && viewModel.entries.isEmpty {
        ProgressView(AppLocalization.string("Reading known_hosts…"))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if viewModel.entries.isEmpty {
        emptyStateView
      } else {
        contentList
      }
    }
    .navigationTitle(AppLocalization.string("Known Hosts"))
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          viewModel.loadEntries()
        } label: {
          Label(AppLocalization.string("Refresh"), systemImage: "arrow.clockwise")
        }
        .help(AppLocalization.string("Reload known_hosts file"))
      }
    }
    .searchable(text: $viewModel.searchQuery, prompt: AppLocalization.string("Search host, algorithm, or fingerprint"))
    .onAppear {
      viewModel.loadEntries()
    }
    .sheet(item: $viewModel.showRandomartForEntry) { entry in
      RandomartSheet(entry: entry)
    }
    .confirmationDialog(
      AppLocalization.string("Remove host key?"),
      isPresented: Binding(
        get: { viewModel.entryPendingDeletion != nil },
        set: { if !$0 { viewModel.entryPendingDeletion = nil } }
      ),
      titleVisibility: .visible
    ) {
      if let target = viewModel.entryPendingDeletion {
        Button(AppLocalization.string("Remove Key"), role: .destructive) {
          viewModel.removeEntry(target)
        }
      }
      Button(AppLocalization.string("Cancel"), role: .cancel) {
        viewModel.entryPendingDeletion = nil
      }
    } message: {
      if let target = viewModel.entryPendingDeletion {
        Text(AppLocalization.format("Remove host key for '%1$@'?\n\nFuture connections will treat this host as unknown and require verifying its fingerprint. This also allows resolving host key mismatches after a server key rotation.", String(describing: target.hostPattern)))
      }
    }
    .alert(AppLocalization.string("Known Hosts Error"), isPresented: Binding(
      get: { viewModel.errorMessage != nil },
      set: { if !$0 { viewModel.errorMessage = nil } }
    )) {
      Button(AppLocalization.string("OK"), role: .cancel) {
        viewModel.errorMessage = nil
      }
    } message: {
      Text(viewModel.errorMessage ?? AppLocalization.string("An error occurred."))
    }
  }

  // MARK: - Subviews

  private var emptyStateView: some View {
    ContentUnavailableView(AppLocalization.string("No trusted host keys yet"), systemImage: "checkmark.shield",
      description: Text(AppLocalization.string("Connect to an SSH host and verify its fingerprint to save its public key on this Mac.")))
  }

  private var contentList: some View {
    Group {
      if viewModel.filteredEntries.isEmpty {
        ContentUnavailableView.search
      } else {
        List(selection: $viewModel.selectedEntry) {
          ForEach(viewModel.filteredEntries) { entry in
            KnownHostRow(
              entry: entry,
              onShowRandomart: {
                viewModel.showRandomartForEntry = entry
              },
              onRemove: {
                viewModel.confirmRemoval(for: entry)
              }
            )
            .tag(entry)
          }
        }
        .onDeleteCommand { if let entry = viewModel.selectedEntry { viewModel.confirmRemoval(for: entry) } }
        .listStyle(.inset(alternatesRowBackgrounds: true))
      }
    }
  }
}

private struct KnownHostRow: View {
  let entry: KnownHostEntry
  let onShowRandomart: () -> Void
  let onRemove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .center, spacing: 8) {
        Image(systemName: entry.isHashed ? "number.square" : "lock.shield")
          .foregroundStyle(.tint)
          .accessibilityHidden(true)

        Text(entry.isHashed ? AppLocalization.string("Hashed Host (OpenSSH)") : entry.hostPattern)
          .font(.headline)
          .lineLimit(1)

        if let marker = entry.marker {
          Text(marker)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.2))
            .foregroundStyle(.orange)
            .clipShape(Capsule())
        }

        Spacer()

        Text(algorithmBadgeText)
          .font(.caption.monospaced().weight(.medium))
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color.secondary.opacity(0.15))
          .clipShape(RoundedRectangle(cornerRadius: 4))

        Button(action: onShowRandomart) {
          Label(AppLocalization.string("Visual Art"), systemImage: "sparkles")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help(AppLocalization.string("View visual randomart"))

        Button(role: .destructive, action: onRemove) {
          Label(AppLocalization.string("Remove"), systemImage: "trash")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help(AppLocalization.string("Remove trusted host key"))
      }

      HStack(spacing: 8) {
        Text("SHA256: " + entry.keyRecord.fingerprintSHA256.replacingOccurrences(of: "SHA256:", with: ""))
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .textSelection(.enabled)

        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(entry.keyRecord.fingerprintSHA256, forType: .string)
        } label: {
          Image(systemName: "doc.on.doc")
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .help(AppLocalization.string("Copy fingerprint"))
        .accessibilityLabel(AppLocalization.string("Copy fingerprint"))

        if let comment = entry.keyRecord.comment, !comment.isEmpty {
          Spacer()
          Text(comment)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
    }
    .padding(.vertical, 4)
  }

  private var algorithmBadgeText: String {
    let alg = entry.keyRecord.algorithm.uppercased()
    if let bits = entry.keyRecord.bitLength {
      return "\(alg) \(bits)"
    }
    return alg
  }
}

private struct RandomartSheet: View {
  let entry: KnownHostEntry
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(AppLocalization.string("Host Key Visual Randomart"))
            .font(.headline)
          Text(entry.isHashed ? AppLocalization.string("Hashed host entry") : entry.hostPattern)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button(AppLocalization.string("Done")) {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
      }

      Divider()

      VStack(alignment: .leading, spacing: 6) {
        Text(AppLocalization.format(
          "Algorithm: %1$@ (%2$@)",
          entry.keyRecord.algorithm,
          entry.keyRecord.bitLength.map { AppLocalization.format("%1$@ bits", String($0)) } ?? AppLocalization.string("unknown")
        ))
          .font(.caption)
        Text(AppLocalization.format("Fingerprint: %1$@", String(describing: entry.keyRecord.fingerprintSHA256)))
          .font(.caption.monospaced())
          .textSelection(.enabled)
      }

      if let art = entry.keyRecord.visualArt, !art.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text(AppLocalization.string("Visual fingerprint"))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

          Text(art)
            .font(.system(.caption, design: .monospaced))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
              RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
      } else {
        Text(AppLocalization.string("No visual randomart available for this key format."))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(20)
    .frame(width: 440)
  }
}

#if DEBUG
#Preview("KnownHostsVaultView") {
  KnownHostsVaultView(viewModel: KnownHostsViewModel(trustService: NativeSSHHostTrustService(
    knownHostsFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("preview-known_hosts"))))
}
#endif
