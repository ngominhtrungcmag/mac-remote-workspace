import Foundation
import XCTest

@testable import AppCore

final class CommandSnippetTests: XCTestCase {
  func testValidationPreservesCommandTextAndRejectsEmptyOrControlInput() throws {
    let command = "  printf 'ready'\nwhoami\t\n"
    let validated = try CommandSnippetDraft(
      title: "  Inspect host  ", commandText: command, scope: .host("host-a")
    ).validated()

    XCTAssertEqual(validated.title, "Inspect host")
    XCTAssertEqual(validated.commandText, command)

    let invalidDrafts = [
      CommandSnippetDraft(title: "   ", commandText: "whoami", scope: .host("host-a")),
      CommandSnippetDraft(title: "Check", commandText: " \n\t", scope: .host("host-a")),
      CommandSnippetDraft(title: "Check", commandText: "whoami\u{001B}[31m", scope: .host("host-a")),
      CommandSnippetDraft(title: "Check", commandText: String(repeating: "x", count: 8_193), scope: .host("host-a")),
      CommandSnippetDraft(title: String(repeating: "x", count: 81), commandText: "whoami", scope: .host("host-a")),
      CommandSnippetDraft(title: "Check", commandText: "whoami", scope: .host("  ")),
      CommandSnippetDraft(title: "Check", commandText: "export API_TOKEN=hardcoded-placeholder-value", scope: .host("host-a")),
    ]
    for draft in invalidDrafts {
      XCTAssertThrowsError(try draft.validated())
    }
    XCTAssertNoThrow(
      try CommandSnippetDraft(
        title: "Check", commandText: "export API_TOKEN=$API_TOKEN", scope: .host("host-a")
      ).validated()
    )
  }

  func testRepositoryPersistsAndScopesSnippetsToHostOrItsCurrentGroup() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("metadata.sqlite")
    let repository = try SQLiteHostRepository(databaseURL: databaseURL)
    let workspace = try repository.createWorkspace(name: "Build")
    let sharedGroup = try repository.createGroup(workspaceID: workspace.id, name: "Deploy")
    let otherGroup = try repository.createGroup(workspaceID: workspace.id, name: "QA")
    let hostA = try repository.createHost(
      HostDraft(
        displayName: "API", address: "api.example.test", environment: .staging,
        workspaceID: workspace.id, groupID: sharedGroup.id
      ))
    let hostB = try repository.createHost(
      HostDraft(
        displayName: "Worker", address: "worker.example.test", environment: .development,
        workspaceID: workspace.id, groupID: sharedGroup.id
      ))
    let hostC = try repository.createHost(
      HostDraft(
        displayName: "QA", address: "qa.example.test", environment: .development,
        workspaceID: workspace.id, groupID: otherGroup.id
      ))

    let hostSnippet = try repository.createCommandSnippet(
      CommandSnippetDraft(title: "API health", commandText: "curl /health", scope: .host(hostA.id)))
    let groupSnippet = try repository.createCommandSnippet(
      CommandSnippetDraft(title: "Deploy status", commandText: "systemctl status app", scope: .group(sharedGroup.id)))
    _ = try repository.createCommandSnippet(
      CommandSnippetDraft(title: "Worker health", commandText: "curl /worker", scope: .host(hostB.id)))
    _ = try repository.createCommandSnippet(
      CommandSnippetDraft(title: "QA only", commandText: "uname -a", scope: .group(otherGroup.id)))

    XCTAssertEqual(
      Set(try repository.listCommandSnippets(hostID: hostA.id, groupID: hostA.groupID).map(\.id)),
      [hostSnippet.id, groupSnippet.id]
    )
    XCTAssertEqual(
      Set(try repository.listCommandSnippets(hostID: hostB.id, groupID: hostB.groupID).map(\.title)),
      ["Deploy status", "Worker health"]
    )
    XCTAssertTrue(try repository.listCommandSnippets(hostID: hostC.id, groupID: hostC.groupID).contains { $0.title == "QA only" })

    try repository.close()
    let reopened = try SQLiteHostRepository(databaseURL: databaseURL)
    defer { try? reopened.close() }
    XCTAssertEqual(
      Set(try reopened.listCommandSnippets(hostID: hostA.id, groupID: hostA.groupID).map(\.id)),
      [hostSnippet.id, groupSnippet.id]
    )
  }

  func testRepositoryRejectsWrongScopeOwnerAndStaleUpdatesAndCascadesOnDelete() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try SQLiteHostRepository(databaseURL: directory.appendingPathComponent("metadata.sqlite"))
    defer { try? repository.close() }
    let workspace = try repository.createWorkspace(name: "Build")
    let group = try repository.createGroup(workspaceID: workspace.id, name: "Ops")
    let host = try repository.createHost(
      HostDraft(
        displayName: "Server", address: "server.example.test", environment: .development,
        workspaceID: workspace.id, groupID: group.id
      ))

    XCTAssertThrowsError(
      try repository.createCommandSnippet(
        CommandSnippetDraft(title: "Missing host", commandText: "whoami", scope: .host("missing")))
    )
    XCTAssertThrowsError(
      try repository.createCommandSnippet(
        CommandSnippetDraft(title: "Missing group", commandText: "whoami", scope: .group("missing")))
    )

    let snippet = try repository.createCommandSnippet(
      CommandSnippetDraft(title: "Status", commandText: "systemctl status app", scope: .host(host.id)))
    let updated = try repository.updateCommandSnippet(
      id: snippet.id,
      expectedVersion: snippet.version,
      draft: CommandSnippetDraft(title: "Status", commandText: "systemctl is-active app", scope: .host(host.id))
    )
    XCTAssertEqual(updated.version, snippet.version + 1)
    XCTAssertThrowsError(
      try repository.updateCommandSnippet(
        id: snippet.id, expectedVersion: snippet.version,
        draft: CommandSnippetDraft(title: "Stale", commandText: "whoami", scope: .host(host.id))
      )
    ) { error in
      XCTAssertEqual(error as? SQLiteRepositoryError, .commandSnippetChanged)
    }

    let groupSnippet = try repository.createCommandSnippet(
      CommandSnippetDraft(title: "Group status", commandText: "systemctl status app", scope: .group(group.id)))
    try repository.deleteGroup(id: group.id, expectedVersion: group.version)
    XCTAssertEqual(try repository.listCommandSnippets(hostID: host.id, groupID: nil).map(\.id), [updated.id])
    XCTAssertThrowsError(
      try repository.deleteCommandSnippet(id: groupSnippet.id, expectedVersion: groupSnippet.version)
    )
  }

  func testPreviewDoesNotSendAndExplicitConfirmationSendsExactReviewedTargetAndPayload() throws {
    let snippet = CommandSnippetRecord(
      id: "snippet-1", title: "Restart service", commandText: "sudo systemctl restart app",
      scope: .host("host-1"), version: 4
    )
    let target = CommandSnippetExecutionTarget(
      hostID: "host-1", groupID: "group-1", displayName: "Payments API",
      address: "payments.example.test", environment: .production
    )
    var gate = CommandSnippetSendGate()
    var sentPayloads: [String] = []

    let preview = try gate.preview(snippet: snippet, target: target)
    XCTAssertEqual(preview.target, target)
    XCTAssertEqual(preview.commandPayload, "sudo systemctl restart app\n")
    XCTAssertTrue(sentPayloads.isEmpty, "Preview must never write to the PTY.")

    XCTAssertThrowsError(
      try gate.confirm(snippet: snippet, target: target, sessionIsActive: false) { sentPayloads.append($0) }
    ) { error in
      XCTAssertEqual(error as? CommandSnippetSendError, .sessionNotActive)
    }
    XCTAssertTrue(sentPayloads.isEmpty)

    try gate.confirm(snippet: snippet, target: target, sessionIsActive: true) { sentPayloads.append($0) }
    XCTAssertEqual(sentPayloads, ["sudo systemctl restart app\n"])
    XCTAssertThrowsError(
      try gate.confirm(snippet: snippet, target: target, sessionIsActive: true) { sentPayloads.append($0) }
    ) { error in
      XCTAssertEqual(error as? CommandSnippetSendError, .noPendingReview)
    }
    XCTAssertEqual(sentPayloads.count, 1)
  }

  func testSendReviewCannotBeReusedAfterSnippetOrTargetChanges() throws {
    let snippet = CommandSnippetRecord(
      id: "snippet-1", title: "List user", commandText: "whoami", scope: .group("group-1"), version: 1
    )
    let target = CommandSnippetExecutionTarget(
      hostID: "host-1", groupID: "group-1", displayName: "Server", address: "server.test",
      environment: .development
    )
    var gate = CommandSnippetSendGate()
    var sent = false
    _ = try gate.preview(snippet: snippet, target: target)

    let editedSnippet = CommandSnippetRecord(
      id: snippet.id, title: snippet.title, commandText: "whoami; rm -rf /", scope: snippet.scope, version: 2
    )
    XCTAssertThrowsError(
      try gate.confirm(snippet: editedSnippet, target: target, sessionIsActive: true) { _ in sent = true }
    ) { error in
      XCTAssertEqual(error as? CommandSnippetSendError, .reviewIsStale)
    }
    XCTAssertFalse(sent)

    _ = try gate.preview(snippet: snippet, target: target)
    let differentHost = CommandSnippetExecutionTarget(
      hostID: "host-2", groupID: "group-1", displayName: "Another server", address: "other.test",
      environment: .development
    )
    XCTAssertThrowsError(
      try gate.confirm(snippet: snippet, target: differentHost, sessionIsActive: true) { _ in sent = true }
    ) { error in
      XCTAssertEqual(error as? CommandSnippetSendError, .targetChanged)
    }
    XCTAssertFalse(sent)
  }

  func testHostScopedSnippetCannotBePreviewedForAnotherHost() throws {
    let snippet = CommandSnippetRecord(
      id: "snippet-1", title: "Inspect", commandText: "uname -a", scope: .host("host-1"), version: 1
    )
    let target = CommandSnippetExecutionTarget(
      hostID: "host-2", groupID: nil, displayName: "Other", address: "other.test",
      environment: .development
    )
    var gate = CommandSnippetSendGate()
    XCTAssertThrowsError(try gate.preview(snippet: snippet, target: target)) { error in
      XCTAssertEqual(error as? CommandSnippetSendError, .scopeDoesNotMatchTarget)
    }
  }

  func testInvalidStoredSnippetCannotBeReviewedOrSent() {
    let snippet = CommandSnippetRecord(
      id: "snippet-1", title: "Unsafe", commandText: "echo ready\u{001B}[31m",
      scope: .host("host-1"), version: 1
    )
    let target = CommandSnippetExecutionTarget(
      hostID: "host-1", groupID: nil, displayName: "Server", address: "server.test",
      environment: .development
    )
    var gate = CommandSnippetSendGate()
    var sent = false
    XCTAssertThrowsError(try gate.preview(snippet: snippet, target: target)) { error in
      XCTAssertEqual(error as? CommandSnippetSendError, .invalidSnippet)
    }
    XCTAssertThrowsError(
      try gate.confirm(snippet: snippet, target: target, sessionIsActive: true) { _ in sent = true }
    ) { error in
      XCTAssertEqual(error as? CommandSnippetSendError, .noPendingReview)
    }
    XCTAssertFalse(sent)
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("mrw-command-snippets-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
