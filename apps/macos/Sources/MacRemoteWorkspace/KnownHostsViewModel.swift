import AppCore
import Combine
import Foundation
import SwiftUI

@MainActor
public final class KnownHostsViewModel: ObservableObject {
  @Published public private(set) var entries: [KnownHostEntry] = []
  @Published public private(set) var isLoading: Bool = false
  @Published public var errorMessage: String? = nil
  @Published public var searchQuery: String = ""
  @Published public var selectedEntry: KnownHostEntry? = nil
  @Published public var entryPendingDeletion: KnownHostEntry? = nil
  @Published public var showRandomartForEntry: KnownHostEntry? = nil

  private let trustService: NativeSSHHostTrustService

  public init(
    trustService: NativeSSHHostTrustService = NativeSSHHostTrustService(
      knownHostsFileURL: NativeSSHHostTrustService.defaultKnownHostsURL,
      audit: NativeSSHHostTrustService.appAuditSink
    )
  ) {
    self.trustService = trustService
  }

  public var filteredEntries: [KnownHostEntry] {
    let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return entries }
    return entries.filter { entry in
      entry.hostPattern.lowercased().contains(query)
        || entry.keyRecord.algorithm.lowercased().contains(query)
        || entry.keyRecord.fingerprintSHA256.lowercased().contains(query)
        || (entry.keyRecord.comment?.lowercased().contains(query) ?? false)
    }
  }

  public func loadEntries() {
    isLoading = true
    errorMessage = nil
    Task.detached(priority: .userInitiated) { [trustService] in
      do {
        let loaded = try trustService.loadAllKnownHosts()
        await MainActor.run {
          self.entries = loaded
          self.isLoading = false
        }
      } catch {
        await MainActor.run {
          self.errorMessage = error.localizedDescription
          self.isLoading = false
        }
      }
    }
  }

  public func confirmRemoval(for entry: KnownHostEntry) {
    entryPendingDeletion = entry
  }

  public func removeEntry(_ entry: KnownHostEntry) {
    Task.detached(priority: .userInitiated) { [trustService] in
      do {
        try trustService.removeKnownHostEntry(entry)
        await MainActor.run {
          self.loadEntries()
          if self.selectedEntry?.id == entry.id {
            self.selectedEntry = nil
          }
          if self.entryPendingDeletion?.id == entry.id {
            self.entryPendingDeletion = nil
          }
        }
      } catch {
        await MainActor.run {
          self.errorMessage = error.localizedDescription
          self.entryPendingDeletion = nil
        }
      }
    }
  }
}
