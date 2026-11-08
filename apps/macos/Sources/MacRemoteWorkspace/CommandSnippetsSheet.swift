import AppCore
import SwiftUI

/// Reusable host-session sheet. The caller supplies the live session check and PTY writer;
/// this view never launches a command from selection, loading, or preview.
struct CommandSnippetsSheet: View {
  @Environment(\.dismiss) private var dismiss
  @StateObject private var model: CommandSnippetsViewModel
  private let repository: CommandSnippetRepository

  @State private var activeSheet: SnippetSheetRoute?
  @State private var deleteTarget: CommandSnippetRecord?
  @State private var operationError: String?

  init(
    host: HostRecord,
    group: HostGroupRecord?,
    repository: CommandSnippetRepository,
    isSessionActive: @escaping () -> Bool,
    sendToSession: @escaping (String) -> Void
  ) {
    self.repository = repository
    _model = StateObject(wrappedValue: CommandSnippetsViewModel(
      host: host,
      group: group,
      repository: repository,
      isSessionActive: isSessionActive,
      sendToSession: sendToSession
    ))
  }

  var body: some View {
    NavigationStack {
      HStack(spacing: 0) {
        snippetList
          .frame(minWidth: 220, idealWidth: 250, maxWidth: 290)
        Divider()
        previewPane
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .navigationTitle(AppLocalization.format("Command Snippets — %1$@", String(describing: model.host.displayName)))
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(AppLocalization.string("Close")) { dismiss() }
        }
      }
      .frame(minWidth: 760, minHeight: 520)
      .sheet(item: $activeSheet, onDismiss: model.cancelReview, content: sheetContent)
      .confirmationDialog(
        AppLocalization.format("Delete %1$@?", deleteTarget?.title ?? AppLocalization.string("snippet")),
        isPresented: deleteConfirmationPresented,
        titleVisibility: .visible
      ) {
        Button(AppLocalization.string("Delete Snippet"), role: .destructive, action: deleteSelectedSnippet)
        Button(AppLocalization.string("Cancel"), role: .cancel) { deleteTarget = nil }
      } message: {
        Text(AppLocalization.string("This removes the saved command text. It does not affect any active SSH session."))
      }
      .alert(AppLocalization.string("Snippet error"), isPresented: errorAlertPresented) {
        Button(AppLocalization.string("OK"), role: .cancel) { operationError = nil }
      } message: {
        Text(operationError ?? AppLocalization.string("The snippet operation could not be completed."))
      }
      .onAppear(perform: model.reload)
    }
  }

  private var snippetList: some View {
    VStack(spacing: 0) {
      HStack {
        Text(AppLocalization.string("Saved snippets"))
          .font(.headline)
        Spacer()
        Button {
          activeSheet = .editor(id: UUID(), snippet: nil)
        } label: {
          Image(systemName: "plus")
        }
        .help(AppLocalization.string("Create a snippet for this host or its group"))
        .accessibilityLabel(AppLocalization.string("New command snippet"))
      }
      .padding(12)

      if let error = model.errorMessage {
        ContentUnavailableView {
          Label(AppLocalization.string("Snippets unavailable"), systemImage: "exclamationmark.triangle")
        } description: {
          Text(error)
        } actions: {
          Button(AppLocalization.string("Retry")) { model.reload() }
        }
      } else if model.snippets.isEmpty {
        ContentUnavailableView {
          Label(AppLocalization.string("No command snippets"), systemImage: "terminal")
        } description: {
          Text(AppLocalization.string("Create a snippet scoped to this host or its group. It will never run automatically."))
        } actions: {
          Button(AppLocalization.string("Create Snippet")) { activeSheet = .editor(id: UUID(), snippet: nil) }
        }
      } else {
        List(selection: $model.selectedSnippetID) {
          ForEach(model.snippets) { snippet in
            VStack(alignment: .leading, spacing: 3) {
              Text(snippet.title)
                .lineLimit(1)
              Text(scopeTitle(for: snippet))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
            .tag(snippet.id)
            .accessibilityElement(children: .combine)
          }
        }
        .onDeleteCommand { deleteTarget = model.selectedSnippet }
        .listStyle(.sidebar)
      }

      Divider()
      HStack(spacing: 8) {
        Button(AppLocalization.string("Edit…")) {
          if let snippet = model.selectedSnippet {
            activeSheet = .editor(id: UUID(), snippet: snippet)
          }
        }
        .disabled(model.selectedSnippet == nil)

        Button(AppLocalization.string("Delete…"), role: .destructive) {
          deleteTarget = model.selectedSnippet
        }
        .disabled(model.selectedSnippet == nil)
      }
      .buttonStyle(WorkspaceSecondaryButtonStyle())
      .padding(10)
    }
    .background(.background)
  }

  @ViewBuilder
  private var previewPane: some View {
    if let snippet = model.selectedSnippet {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text(snippet.title)
            .font(.title2.weight(.semibold))
          Label(scopeTitle(for: snippet), systemImage: snippet.scope.isGroup ? "folder.fill" : "server.rack")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }

        if model.host.environment == .production {
          Label(AppLocalization.string("Production session: review every line before sending."), systemImage: "exclamationmark.triangle.fill")
            .font(.callout.weight(.semibold))
            .foregroundStyle(.red)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }

        VStack(alignment: .leading, spacing: 8) {
          Text(AppLocalization.string("Preview — nothing has been sent"))
            .font(.headline)
          ScrollView([.vertical, .horizontal]) {
            Text(snippet.commandText)
              .font(.system(.body, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .accessibilityIdentifier("commandSnippetPreview")
          }
          .padding(12)
          .frame(maxHeight: .infinity)
          .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
          .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        }

        HStack {
          if model.canSend {
            Label(AppLocalization.format("Connected to %1$@", String(describing: model.host.displayName)), systemImage: "checkmark.circle.fill")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            Label(AppLocalization.string("Connect to this host to send a snippet."), systemImage: "bolt.slash")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button(AppLocalization.string("Review & Send…")) {
            do {
              activeSheet = .review(try model.prepareReview(for: snippet))
            } catch {
              operationError = error.localizedDescription
            }
          }
          .buttonStyle(WorkspacePrimaryButtonStyle())
          .disabled(!model.canSend)
          .accessibilityIdentifier("commandSnippetReviewAndSend")
        }
      }
      .padding(20)
    } else {
      ContentUnavailableView(
        AppLocalization.string("Select a snippet"),
        systemImage: "text.alignleft",
        description: Text(AppLocalization.string("The full command preview appears here. Selecting a snippet never sends it."))
      )
    }
  }

  @ViewBuilder
  private func sheetContent(for route: SnippetSheetRoute) -> some View {
    switch route {
    case .editor(_, let snippet):
      CommandSnippetEditorSheet(
        host: model.host,
        group: model.group,
        repository: repository,
        snippet: snippet,
        onSaved: { saved in
          model.reload()
          model.selectedSnippetID = saved.id
          activeSheet = nil
        }
      )
    case .review(let review):
      CommandSnippetReviewSheet(
        review: review,
        isSessionActive: { model.canSend },
        onConfirm: { model.confirm(review) },
        onCancel: model.cancelReview
      )
    }
  }

  private func scopeTitle(for snippet: CommandSnippetRecord) -> String {
    switch snippet.scope {
    case .host:
      AppLocalization.string("This host")
    case .group:
      AppLocalization.format("Group: %1$@", model.group?.name ?? AppLocalization.string("current group"))
    }
  }

  private var deleteConfirmationPresented: Binding<Bool> {
    Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
  }

  private var errorAlertPresented: Binding<Bool> {
    Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })
  }

  private func deleteSelectedSnippet() {
    guard let deleteTarget else { return }
    do {
      try model.delete(deleteTarget)
      self.deleteTarget = nil
    } catch {
      self.deleteTarget = nil
      operationError = error.localizedDescription
    }
  }
}

private enum SnippetSheetRoute: Identifiable {
  case editor(id: UUID, snippet: CommandSnippetRecord?)
  case review(CommandSnippetReview)

  var id: String {
    switch self {
    case .editor(let id, _): id.uuidString
    case .review(let review): review.id
    }
  }
}

private struct CommandSnippetEditorSheet: View {
  @Environment(\.dismiss) private var dismiss
  let host: HostRecord
  let group: HostGroupRecord?
  let repository: CommandSnippetRepository
  let snippet: CommandSnippetRecord?
  let onSaved: (CommandSnippetRecord) -> Void

  @State private var title: String
  @State private var commandText: String
  @State private var scopeChoice: SnippetScopeChoice
  @State private var errorMessage: String?

  init(
    host: HostRecord,
    group: HostGroupRecord?,
    repository: CommandSnippetRepository,
    snippet: CommandSnippetRecord?,
    onSaved: @escaping (CommandSnippetRecord) -> Void
  ) {
    self.host = host
    self.group = group?.id == host.groupID ? group : nil
    self.repository = repository
    self.snippet = snippet
    self.onSaved = onSaved
    _title = State(initialValue: snippet?.title ?? "")
    _commandText = State(initialValue: snippet?.commandText ?? "")
    if case .group = snippet?.scope {
      _scopeChoice = State(initialValue: .group)
    } else {
      _scopeChoice = State(initialValue: .host)
    }
  }

  var body: some View {
    NavigationStack {
      Form {
        TextField(AppLocalization.string("Name"), text: $title)
          .accessibilityIdentifier("commandSnippetTitle")

        Picker(AppLocalization.string("Scope"), selection: $scopeChoice) {
          Text(AppLocalization.format("Host: %1$@", String(describing: host.displayName))).tag(SnippetScopeChoice.host)
          if host.groupID != nil {
            Text(AppLocalization.format("Group: %1$@", group?.name ?? AppLocalization.string("current group"))).tag(SnippetScopeChoice.group)
          }
        }
        .accessibilityIdentifier("commandSnippetScope")

        VStack(alignment: .leading, spacing: 8) {
          Text(AppLocalization.string("Command text"))
            .font(.headline)
          TextEditor(text: $commandText)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 220)
            .accessibilityLabel(AppLocalization.string("Command text"))
            .accessibilityHint(AppLocalization.string("Sending submits this text to the interactive shell. Multiple lines may run multiple commands."))
            .accessibilityIdentifier("commandSnippetCommand")
          Text(AppLocalization.string("Sending submits this text to the interactive shell. Multiple lines may run multiple commands."))
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Label(
          AppLocalization.string("Stored locally. Do not include passwords, access tokens, passphrases, or private keys."),
          systemImage: "lock.shield"
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        if let errorMessage {
          Text(errorMessage)
            .font(.callout)
            .foregroundStyle(.red)
        }
      }
      .formStyle(.grouped)
      .padding(12)
      .navigationTitle(snippet == nil ? AppLocalization.string("New Snippet") : AppLocalization.string("Edit Snippet"))
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(AppLocalization.string("Cancel")) { dismiss() }
            .keyboardShortcut(.cancelAction)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(AppLocalization.string("Save"), action: save)
            .buttonStyle(WorkspacePrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("commandSnippetSave")
        }
      }
      .frame(minWidth: 540, minHeight: 460)
    }
  }

  private func save() {
    let scope: CommandSnippetScope
    switch scopeChoice {
    case .host: scope = .host(host.id)
    case .group:
      guard let groupID = host.groupID else {
        errorMessage = AppLocalization.string("This host is no longer in a group. Choose host scope and try again.")
        return
      }
      scope = .group(groupID)
    }
    do {
      let draft = try CommandSnippetDraft(title: title, commandText: commandText, scope: scope).validated()
      let saved: CommandSnippetRecord
      if let snippet {
        saved = try repository.updateCommandSnippet(
          id: snippet.id, expectedVersion: snippet.version, draft: draft)
      } else {
        saved = try repository.createCommandSnippet(draft)
      }
      onSaved(saved)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

private enum SnippetScopeChoice: String, CaseIterable, Identifiable {
  case host
  case group

  var id: Self { self }
}

private struct CommandSnippetReviewSheet: View {
  @Environment(\.dismiss) private var dismiss
  let review: CommandSnippetReview
  let isSessionActive: () -> Bool
  let onConfirm: () -> String?
  let onCancel: () -> Void
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        Image(systemName: review.target.environment == .production ? "exclamationmark.triangle.fill" : "terminal.fill")
          .font(.title2)
          .foregroundStyle(review.target.environment == .production ? .red : .accentColor)
        VStack(alignment: .leading, spacing: 3) {
          Text(AppLocalization.string("Review before sending"))
            .font(.title2.weight(.semibold))
          Text(review.snippet.title)
            .foregroundStyle(.secondary)
        }
      }

      LabeledContent(AppLocalization.string("Active target")) {
        Text(AppLocalization.format(
          "%1$@ (%2$@) — %3$@",
          review.target.displayName,
          review.target.address,
          review.target.environment.localizedTitle
        ))
          .font(.system(.body, design: .monospaced))
          .multilineTextAlignment(.trailing)
          .textSelection(.enabled)
      }

      Text(AppLocalization.string("The exact text below will be sent to the interactive SSH terminal followed by Return. It can change the remote system."))
        .font(.callout)
        .foregroundStyle(review.target.environment == .production ? .red : .secondary)

      ScrollView([.vertical, .horizontal]) {
        Text(review.commandPayload)
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("commandSnippetConfirmPreview")
      }
      .padding(12)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))

      if let errorMessage {
        Text(errorMessage)
          .font(.callout)
          .foregroundStyle(.red)
      }

      HStack {
        Button(AppLocalization.string("Cancel")) {
          onCancel()
          dismiss()
        }
        Spacer()
        Button(
          review.target.environment == .production ? AppLocalization.string("Send to Production Session") : AppLocalization.string("Confirm & Send"),
          role: .destructive,
          action: confirm
        )
        .buttonStyle(WorkspacePrimaryButtonStyle())
        .disabled(!isSessionActive())
        .accessibilityIdentifier("commandSnippetConfirmSend")
      }
    }
    .padding(20)
    .frame(minWidth: 600, minHeight: 500)
    .onDisappear(perform: onCancel)
  }

  private func confirm() {
    guard isSessionActive() else {
      errorMessage = CommandSnippetSendError.sessionNotActive.localizedDescription
      return
    }
    if let error = onConfirm() {
      errorMessage = error
    } else {
      dismiss()
    }
  }
}

private extension CommandSnippetScope {
  var isGroup: Bool {
    if case .group = self { return true }
    return false
  }
}
