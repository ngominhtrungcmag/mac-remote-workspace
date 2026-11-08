import AppCore
import SwiftUI

/// Security → Credentials destination: explicit Keychain-backed credential
/// management (US-005 / FR-004 / FR-025 / TC-003). This view only edits
/// labels, kinds, and opaque Keychain references. Secret values never leave
/// SecureField input before being written directly to the Keychain, and they
/// are never placed in SQLite, logs, or process arguments.
struct CredentialVaultView: View {
  @State private var credentialRefs: [CredentialRefRecord] = []
  @State private var repository: SQLiteHostRepository?
  @State private var storageError: String?
  @State private var isShowingCreateSheet = false
  @State private var renameTarget: CredentialRefRecord?
  @State private var deleteTarget: CredentialRefRecord?
  @State private var deleteUsageCount: Int = 0
  @State private var deleteBlockedReason: String?
  @State private var selectedCredentialID: CredentialRefRecord.ID?

  init(repository: SQLiteHostRepository? = nil) {
    _repository = State(initialValue: repository)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let storageError {
        inlineError(storageError)
      }
      if credentialRefs.isEmpty {
        emptyView
      } else {
        credentialTable
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .navigationTitle(AppLocalization.string("Credentials"))
    .navigationSubtitle(credentialSubtitle)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button(AppLocalization.string("Add Credential…"), systemImage: "plus") {
          isShowingCreateSheet = true
        }
        .buttonStyle(WorkspacePrimaryButtonStyle())
        .help(AppLocalization.string("Save a new credential reference in the macOS Keychain"))
        .accessibilityLabel(AppLocalization.string("Add credential"))
      }
    }
    .task { await loadCredentialRefs() }
    .sheet(isPresented: $isShowingCreateSheet) {
      CredentialFormSheet { label, kind, secret in
        try persistCredential(label: label, kind: kind, secret: secret)
      }
    }
    .sheet(item: $renameTarget) { record in
      CredentialRenameSheet(record: record) { newLabel in
        try renameCredential(record, to: newLabel)
      }
    }
    .alert(AppLocalization.string("Remove credential?"), isPresented: deleteConfirmationPresented) {
      Button(AppLocalization.string("Remove from Keychain"), role: .destructive) {
        deleteSelectedCredential()
      }
      .disabled(deleteUsageCount > 0)
      Button(AppLocalization.string("Cancel"), role: .cancel) { deleteTarget = nil }
    } message: {
      Text(deleteConfirmationMessage)
    }
    .alert(AppLocalization.string("Credential unavailable"), isPresented: blockedAlertPresented) {
      Button(AppLocalization.string("OK"), role: .cancel) { deleteBlockedReason = nil }
    } message: {
      Text(deleteBlockedReason ?? AppLocalization.string("The credential is still referenced by a saved connection profile."))
    }
  }

  // MARK: - Content

  private var credentialSubtitle: String {
    guard !credentialRefs.isEmpty else { return "" }
    return AppLocalization.format(
      credentialRefs.count == 1 ? "%1$@ Keychain reference on this Mac" : "%1$@ Keychain references on this Mac",
      String(credentialRefs.count)
    )
  }

  private var emptyView: some View {
    VStack(spacing: 12) {
      Image(systemName: "key.horizontal")
        .font(.largeTitle)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(AppLocalization.string("No Keychain credentials yet"))
        .font(.title3.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
      Text(AppLocalization.string("Credentials save passwords and key passphrases in the macOS Keychain. Connection metadata stores only an opaque reference — never the secret value."))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 460)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .frame(minHeight: 260)
  }

  private var credentialTable: some View {
    Table(credentialRefs, selection: $selectedCredentialID) {
      TableColumn(AppLocalization.string("Label")) { record in
        VStack(alignment: .leading, spacing: 2) {
          Text(record.label)
          Text(record.keychainReferenceDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel(AppLocalization.format("Keychain reference %1$@", String(describing: record.keychainReferenceDescription)))
        }
      }
      TableColumn(AppLocalization.string("Kind")) { record in
        Text(record.kind.localizedTitle)
      }
      TableColumn(AppLocalization.string("Protection")) { record in
        Label(AppLocalization.string("macOS Keychain"), systemImage: "lock.shield")
          .accessibilityLabel(AppLocalization.string("Stored in the macOS Keychain"))
      }
      TableColumn(AppLocalization.string("Actions")) { record in
        HStack(spacing: 8) {
          Button(AppLocalization.string("Rename")) {
            renameTarget = record
          }
          .buttonStyle(.link)
          .accessibilityLabel(AppLocalization.format("Rename credential %1$@", String(describing: record.label)))
          Button(AppLocalization.string("Delete"), role: .destructive) {
            requestDeletion(record)
          }
          .buttonStyle(.link)
          .accessibilityLabel(AppLocalization.format("Delete credential %1$@", String(describing: record.label)))
        }
      }
    }
    .contextMenu(forSelectionType: CredentialRefRecord.ID.self) { ids in
      if let record = credentialRefs.first(where: { ids.contains($0.id) }) {
        Button(AppLocalization.string("Rename…")) { renameTarget = record }
        Divider()
        Button(AppLocalization.string("Delete…"), role: .destructive) { requestDeletion(record) }
      }
    }
    .onDeleteCommand {
      if let record = credentialRefs.first(where: { $0.id == selectedCredentialID }) {
        requestDeletion(record)
      }
    }
    .padding(.bottom, 8)
  }

  private func inlineError(_ message: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.yellow)
      Text(message)
        .font(.callout)
      Spacer()
    }
    .padding(10)
    .background(Color.yellow.opacity(0.15))
    .cornerRadius(6)
    .padding(12)
  }

  // MARK: - Data

  private func loadCredentialRefs() async {
    do {
      let repository = try openRepository()
      credentialRefs = try repository.listCredentialRefs()
      storageError = nil
    } catch {
      repository = nil
      storageError = AppLocalization.format("Credential metadata unavailable: %1$@", error.localizedDescription)
    }
  }

  @discardableResult
  private func openRepository() throws -> SQLiteHostRepository {
    if let repository {
      return repository
    }
    let opened = try SQLiteHostRepository.openApplicationRepository()
    repository = opened
    return opened
  }

  private func persistCredential(label: String, kind: CredentialKind, secret: ProtectedSecret) throws {
    let store = KeychainCredentialStore()
    let reference = try store.create(secret: secret)
    do {
      let repository = try openRepository()
      _ = try repository.createCredentialRef(
        label: label, kind: kind, keychainItemID: reference.encoded)
      try loadCredentialRefsSync()
    } catch {
      // Roll the orphaned Keychain item back so metadata and secrets stay in sync.
      try? store.delete(reference)
      throw error
    }
  }

  private func renameCredential(_ record: CredentialRefRecord, to label: String) throws {
    let repository = try openRepository()
    _ = try repository.updateCredentialRef(id: record.id, expectedLabel: record.label, label: label)
    try loadCredentialRefsSync()
  }

  private func loadCredentialRefsSync() throws {
    let repository = try openRepository()
    credentialRefs = try repository.listCredentialRefs()
    storageError = nil
  }

  // MARK: - Deletion (FR-025 / TC-023)

  private func requestDeletion(_ record: CredentialRefRecord) {
    deleteTarget = record
    deleteUsageCount = 0
    deleteBlockedReason = nil
    do {
      let repository = try openRepository()
      deleteUsageCount = try repository.credentialRefUsageCount(id: record.id)
    } catch {
      storageError = AppLocalization.format("Could not read credential usage: %1$@", error.localizedDescription)
    }
  }

  private var deleteConfirmationMessage: String {
    guard let record = deleteTarget else { return "" }
    if deleteUsageCount > 0 {
      return AppLocalization.format(
        deleteUsageCount == 1
          ? "%1$@ is still referenced by %2$@ saved connection profile. Unlink it before deleting so it keeps working."
          : "%1$@ is still referenced by %2$@ saved connection profiles. Unlink it before deleting so they keep working.",
        record.label,
        String(deleteUsageCount)
      )
    }
    return AppLocalization.format(
      "This removes the secret for %1$@ from the macOS Keychain and its reference from the local metadata. Saved hosts keep working without it.",
      record.label
    )
  }

  private var deleteConfirmationPresented: Binding<Bool> {
    Binding(
      get: { deleteTarget != nil && deleteBlockedReason == nil },
      set: { if !$0 { deleteTarget = nil } }
    )
  }

  private var blockedAlertPresented: Binding<Bool> {
    Binding(
      get: { deleteBlockedReason != nil },
      set: { if !$0 { deleteBlockedReason = nil } }
    )
  }

  private func deleteSelectedCredential() {
    guard let record = deleteTarget else { return }
    deleteTarget = nil
    do {
      let repository = try openRepository()
      let usageCount = try repository.credentialRefUsageCount(id: record.id)
      guard usageCount == 0 else {
        deleteBlockedReason = AppLocalization.format(
          usageCount == 1
            ? "%1$@ is still referenced by %2$@ saved connection profile. Unlink it before deleting."
            : "%1$@ is still referenced by %2$@ saved connection profiles. Unlink it before deleting.",
          record.label,
          String(usageCount)
        )
        return
      }
      // Keychain first: a denied/locked delete must leave metadata intact so the user can retry.
      if let reference = KeychainCredentialReference.decode(record.keychainItemID) {
        do { try KeychainCredentialStore().delete(reference) } catch CredentialStoreError.notFound {}
      }
      try repository.deleteCredentialRef(id: record.id)
      try loadCredentialRefsSync()
    } catch let error as SQLiteRepositoryError where error == .credentialRefInUse {
      deleteBlockedReason = AppLocalization.format(
        "%1$@ is still referenced by a saved connection profile. Unlink it before deleting.",
        record.label
      )
    } catch {
      storageError = AppLocalization.format("Credential removal failed: %1$@", error.localizedDescription)
    }
  }
}

extension CredentialRefRecord {
  /// Human-safe, secret-free description of the opaque Keychain reference.
  var keychainReferenceDescription: String {
    let accountSuffix = keychainItemID.suffix(8)
    return AppLocalization.format("Keychain item …%1$@", String(accountSuffix))
  }
}

/// Creates a new Keychain-backed credential through explicit user input.
struct CredentialFormSheet: View {
  @Environment(\.dismiss) private var dismiss
  var onCommit: (String, CredentialKind, ProtectedSecret) throws -> Void

  @State private var label = ""
  @State private var kind: CredentialKind = .password
  @State private var secret = ""
  @State private var confirmSecret = ""
  @State private var error: CredentialRefValidationError?
  @State private var operationError: String?

  var body: some View {
    NavigationStack {
      Form {
        Section(AppLocalization.string("Credential")) {
          TextField(AppLocalization.string("Label"), text: $label, prompt: Text(AppLocalization.string("Staging admin")))
            .accessibilityLabel(AppLocalization.string("Credential label"))
          Picker(AppLocalization.string("Kind"), selection: $kind) {
            ForEach(CredentialKind.allCases, id: \.self) { value in
              Text(value.localizedTitle).tag(value)
            }
          }
        }
        Section {
          SecureField(AppLocalization.string("Secret"), text: $secret)
            .accessibilityLabel(AppLocalization.string("Credential secret"))
            .privacySensitive()
          if kind == .keyPassphrase {
            SecureField(AppLocalization.string("Repeat secret"), text: $confirmSecret)
              .accessibilityLabel(AppLocalization.string("Repeat credential secret"))
              .privacySensitive()
          }
        } header: {
          Text(AppLocalization.string("Keychain"))
        } footer: {
          Text(AppLocalization.string("Secrets stay in macOS Keychain. Only a reference is stored in the workspace."))
        }
        if let error {
          Label(error.errorDescription ?? AppLocalization.string("The credential label is invalid."), systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
        }
        if let operationError {
          Label(operationError, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
        }
      }
      .formStyle(.grouped)
      .navigationTitle(AppLocalization.string("Add Keychain Credential"))
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(AppLocalization.string("Cancel"), role: .cancel) { dismiss() }
            .keyboardShortcut(.cancelAction)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(AppLocalization.string("Save to Keychain"), action: commit)
            .buttonStyle(WorkspacePrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(!isFormPlausible)
        }
      }
      .frame(minWidth: 460, idealWidth: 500, minHeight: 380)
    }
  }

  private var isFormPlausible: Bool {
    !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !secret.isEmpty
      && (kind != .keyPassphrase || confirmSecret == secret)
  }

  private func commit() {
    error = nil
    operationError = nil
    do {
      _ = try CredentialRefDraft(label: label).validated()
    } catch {
      if let validationError = error as? CredentialRefValidationError {
        self.error = validationError
      } else {
        operationError = error.localizedDescription
      }
      return
    }
    guard secret == confirmSecret || kind != .keyPassphrase else {
      operationError = AppLocalization.string("The repeated secret does not match.")
      return
    }
    let protectedSecret = ProtectedSecret(bytes: Array(secret.utf8))
    do {
      try onCommit(
        label.trimmingCharacters(in: .whitespacesAndNewlines), kind, protectedSecret)
      dismiss()
    } catch {
      operationError = error.localizedDescription
      // Best effort: nothing else retains the secret buffer.
      unknownSecretDeinitFallback()
    }
  }

  private func unknownSecretDeinitFallback() {
    secret = ""
    confirmSecret = ""
  }
}

/// Minimal draft validation mirroring the repository contract without owning
/// any secret value.
struct CredentialRefDraft {
  let label: String

  func validated() throws -> String {
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw CredentialRefValidationError.emptyLabel }
    guard trimmed.utf8.count <= 120 else { throw CredentialRefValidationError.labelTooLong }
    guard trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
      throw CredentialRefValidationError.invalidLabel
    }
    return trimmed
  }
}

/// Renames only the metadata label; the Keychain item itself is untouched.
struct CredentialRenameSheet: View {
  @Environment(\.dismiss) private var dismiss
  let record: CredentialRefRecord
  var onCommit: (String) throws -> Void

  @State private var label: String
  @State private var error: String?

  init(record: CredentialRefRecord, onCommit: @escaping (String) throws -> Void) {
    self.record = record
    self.onCommit = onCommit
    _label = State(initialValue: record.label)
  }

  var body: some View {
    NavigationStack {
      Form {
        TextField(AppLocalization.string("Label"), text: $label)
          .accessibilityLabel(AppLocalization.string("Credential label"))
        if let error {
          Label(error, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
        }
      }
      .formStyle(.grouped)
      .navigationTitle(AppLocalization.string("Rename Credential"))
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(AppLocalization.string("Cancel"), role: .cancel) { dismiss() }
            .keyboardShortcut(.cancelAction)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(AppLocalization.string("Rename"), action: rename)
            .buttonStyle(WorkspacePrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
      }
      .frame(minWidth: 420, idealWidth: 460, minHeight: 200)
    }
  }

  private func rename() {
    do {
      try onCommit(label.trimmingCharacters(in: .whitespacesAndNewlines))
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }
}

#if DEBUG
#Preview("CredentialFormSheet") {
  CredentialFormSheet(onCommit: { _, _, _ in }).frame(width: 500, height: 400)
}

#Preview("CredentialRenameSheet") {
  CredentialRenameSheet(record: PreviewFixtures.credential, onCommit: { _ in }).frame(width: 450, height: 250)
}

#endif
#if DEBUG
#Preview("CredentialVaultView") {
  CredentialVaultView(repository: try! PreviewFixtures.repository())
}
#endif
