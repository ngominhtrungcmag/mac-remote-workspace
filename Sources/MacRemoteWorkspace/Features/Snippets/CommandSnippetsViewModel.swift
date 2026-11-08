import AppCore
import Combine
import Foundation

@MainActor
final class CommandSnippetsViewModel: ObservableObject {
  @Published private(set) var snippets: [CommandSnippetRecord] = []
  @Published var selectedSnippetID: String?
  @Published private(set) var errorMessage: String?

  let host: HostRecord
  let group: HostGroupRecord?
  let target: CommandSnippetExecutionTarget

  private let repository: CommandSnippetRepository
  private let isSessionActive: () -> Bool
  private let sendToSession: (String) -> Void
  private var sendGate = CommandSnippetSendGate()

  init(
    host: HostRecord,
    group: HostGroupRecord?,
    repository: CommandSnippetRepository,
    isSessionActive: @escaping () -> Bool,
    sendToSession: @escaping (String) -> Void
  ) {
    self.host = host
    self.group = group?.id == host.groupID ? group : nil
    self.repository = repository
    self.isSessionActive = isSessionActive
    self.sendToSession = sendToSession
    target = CommandSnippetExecutionTarget(
      hostID: host.id,
      groupID: host.groupID,
      displayName: host.displayName,
      address: host.address,
      environment: host.environment
    )
    reload()
  }

  var selectedSnippet: CommandSnippetRecord? {
    guard let selectedSnippetID else { return nil }
    return snippets.first(where: { $0.id == selectedSnippetID })
  }

  var canSend: Bool { isSessionActive() }

  func reload() {
    do {
      snippets = try repository.listCommandSnippets(hostID: host.id, groupID: host.groupID)
      if selectedSnippetID == nil || !snippets.contains(where: { $0.id == selectedSnippetID }) {
        selectedSnippetID = snippets.first?.id
      }
      errorMessage = nil
    } catch {
      snippets = []
      selectedSnippetID = nil
      errorMessage = error.localizedDescription
    }
  }

  func save(_ draft: CommandSnippetDraft, editing snippet: CommandSnippetRecord?) throws {
    if let snippet {
      _ = try repository.updateCommandSnippet(
        id: snippet.id, expectedVersion: snippet.version, draft: draft)
    } else {
      _ = try repository.createCommandSnippet(draft)
    }
    reload()
  }

  func delete(_ snippet: CommandSnippetRecord) throws {
    try repository.deleteCommandSnippet(id: snippet.id, expectedVersion: snippet.version)
    if selectedSnippetID == snippet.id { selectedSnippetID = nil }
    reload()
  }

  func prepareReview(for snippet: CommandSnippetRecord) throws -> CommandSnippetReview {
    try sendGate.preview(snippet: snippet, target: target)
  }

  func confirm(_ review: CommandSnippetReview) -> String? {
    guard snippets.contains(where: { $0 == review.snippet }) else {
      sendGate.cancel()
      return CommandSnippetSendError.reviewIsStale.localizedDescription
    }
    do {
      try sendGate.confirm(
        snippet: review.snippet,
        target: target,
        sessionIsActive: isSessionActive(),
        send: sendToSession
      )
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  func cancelReview() {
    sendGate.cancel()
  }
}
