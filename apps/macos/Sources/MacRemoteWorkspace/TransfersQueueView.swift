import AppCore
import SwiftUI

extension SFTPTransferItem {
  var isActiveTransfer: Bool {
    switch status {
    case .queued, .running: return true
    default: return false
    }
  }

  var canRevealInFinder: Bool {
    guard kind == .download, case .completed = status else { return false }
    return true
  }
}

private extension SFTPTransferStatus {
  var localizedLabel: String {
    switch self {
    case .queued: AppLocalization.string("Queued")
    case .running(let progress):
      progress.map { AppLocalization.format("%1$@%%", String(Int($0 * 100))) } ?? AppLocalization.string("Running")
    case .completed: AppLocalization.string("Completed")
    case .failed(let error):
      AppLocalization.format("Failed: %1$@", error)
    case .cancelled: AppLocalization.string("Cancelled")
    }
  }
}

public struct TransfersQueueView: View {
  @ObservedObject var queue: SFTPTransferQueue
  @State private var filter: TransferFilter = .all

  private enum TransferFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case active = "Active"
    case finished = "Finished"

    var id: Self { self }
    var localizedTitle: String { AppLocalization.string(rawValue) }
  }

  public init(queue: SFTPTransferQueue) {
    self.queue = queue
  }

  public var body: some View {
    VStack(spacing: 0) {
      if queue.items.isEmpty {
        emptyStateView
      } else {
        contentList
      }
    }
    .navigationTitle(AppLocalization.string("Transfers"))
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button(AppLocalization.string("Clear Finished")) {
          queue.clearFinished()
        }
        .disabled(!hasFinishedItems)
      }
    }
  }

  private var hasFinishedItems: Bool {
    queue.items.contains { item in
      switch item.status {
      case .completed, .cancelled, .failed: return true
      default: return false
      }
    }
  }

  private var filteredItems: [SFTPTransferItem] {
    switch filter {
    case .all:
      return queue.items
    case .active:
      return queue.items.filter { item in
        switch item.status {
        case .queued, .running: return true
        default: return false
        }
      }
    case .finished:
      return queue.items.filter { item in
        switch item.status {
        case .completed, .cancelled, .failed: return true
        default: return false
        }
      }
    }
  }

  private var emptyStateView: some View {
    ContentUnavailableView(AppLocalization.string("No file transfers yet"), systemImage: "arrow.left.arrow.right",
      description: Text(AppLocalization.string("Uploads and downloads from SFTP sessions appear here with progress and status.")))
  }

  private var contentList: some View {
    VStack(spacing: 0) {
      HStack {
        Picker(AppLocalization.string("Filter"), selection: $filter) {
          ForEach(TransferFilter.allCases) { f in
            Text(f.localizedTitle).tag(f)
          }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 240)

        Spacer()

        Text(AppLocalization.format("%1$@ total transfers", String(describing: queue.items.count)))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal)
      .padding(.vertical, 8)

      Divider()

      if filteredItems.isEmpty {
        ContentUnavailableView(
          filter == .active ? AppLocalization.string("No active transfers") : AppLocalization.string("No finished transfers"),
          systemImage: "tray",
          description: Text(AppLocalization.string("Switch the filter to All to see every transfer."))
        )
        .frame(maxHeight: .infinity)
      } else {
      List(filteredItems) { item in
        TransferRow(item: item, onCancel: {
          queue.cancelTransfer(id: item.id)
        })
      }
      .listStyle(.inset(alternatesRowBackgrounds: true))
      }
    }
  }
}

private struct TransferRow: View {
  let item: SFTPTransferItem
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Image(systemName: item.kind == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
          .font(.title2)
          .foregroundStyle(item.kind == .upload ? Color.blue : Color.green)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(item.sourceDescription)
              .font(.headline)
              .lineLimit(1)
              .truncationMode(.middle)
              .help(item.sourceDescription)

            Image(systemName: "arrow.right")
              .font(.caption)
              .foregroundStyle(.tertiary)
              .accessibilityHidden(true)

            Text(item.destinationDescription)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
              .help(item.destinationDescription)
          }

          HStack(spacing: 8) {
            Image(systemName: statusSymbol)
              .foregroundStyle(statusColor)
              .accessibilityHidden(true)
            Text(statusDescription)
              .font(.caption.weight(.medium))
              .foregroundStyle(statusColor)
              .lineLimit(2)
              .help(statusDescription)

            if item.totalBytes > 0 && !isIndeterminate {
              Text("•")
                .foregroundStyle(.tertiary)
              Text(byteCountString)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
          }
        }

        Spacer()

        if item.canRevealInFinder {
          Button(AppLocalization.string("Reveal in Finder")) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.destinationDescription)])
          }
        }

        if isRunningOrQueued {
          Button(AppLocalization.string("Cancel"), role: .destructive, action: onCancel)
            .buttonStyle(WorkspaceSecondaryButtonStyle())
            .controlSize(.small)
            .accessibilityLabel(AppLocalization.format("Cancel %1$@", String(describing: item.sourceDescription)))
        }
      }

      if case .running(let progress) = item.status {
        ProgressView(value: progress)
          .progressViewStyle(.linear)
          .accessibilityLabel(AppLocalization.string("Transfer progress"))
          .accessibilityValue(progress.map { AppLocalization.format("%1$@ percent", String(describing: Int(($0 * 100).rounded()))) } ?? AppLocalization.string("Running"))
          .padding(.top, 2)
      }
    }
    .padding(.vertical, 4)
  }

  private var isRunningOrQueued: Bool {
    switch item.status {
    case .queued, .running: return true
    default: return false
    }
  }

  private var isIndeterminate: Bool {
    if case .running(nil) = item.status { return true }
    return false
  }

  private var statusDescription: String {
    item.status.localizedLabel
  }

  private var statusSymbol: String {
    switch item.status {
    case .completed: return "checkmark.circle.fill"
    case .running: return "arrow.triangle.2.circlepath"
    case .queued: return "clock"
    case .failed: return "exclamationmark.circle.fill"
    case .cancelled: return "xmark.circle"
    }
  }

  private var statusColor: Color {
    switch item.status {
    case .completed: return .green
    case .running: return .blue
    case .queued: return .secondary
    case .failed: return .red
    case .cancelled: return .orange
    }
  }

  private var byteCountString: String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    let trans = formatter.string(fromByteCount: item.transferredBytes)
    let total = formatter.string(fromByteCount: item.totalBytes)
    return "\(trans) / \(total)"
  }
}
