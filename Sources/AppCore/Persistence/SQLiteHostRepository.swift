import Darwin
import Foundation
import SQLite3

public enum HostEnvironment: String, CaseIterable, Identifiable, Sendable {
  case development
  case staging
  case production

  public var id: Self { self }

  public var title: String {
    switch self {
    case .development: "Development"
    case .staging: "Staging"
    case .production: "Production"
    }
  }
}

public struct WorkspaceRecord: Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let version: Int64

  public init(id: String, name: String, version: Int64 = 1) {
    self.id = id
    self.name = name
    self.version = version
  }
}

public struct HostGroupRecord: Equatable, Identifiable, Sendable {
  public let id: String
  public let workspaceID: String
  public let name: String
  public let sortOrder: Int
  public let version: Int64

  public init(id: String, workspaceID: String, name: String, sortOrder: Int = 0, version: Int64 = 1) {
    self.id = id
    self.workspaceID = workspaceID
    self.name = name
    self.sortOrder = sortOrder
    self.version = version
  }
}

public enum OrganizationNameValidationError: Error, Equatable, AppCoreLocalizedError {
  case emptyName
  case nameTooLong
  case invalidName

  public func displayDescription(locale: Locale?) -> String? {
    switch self {
    case .emptyName: AppCoreLocalization.string("Enter a name.", locale: locale)
    case .nameTooLong: AppCoreLocalization.string("Names must be 80 characters or fewer.", locale: locale)
    case .invalidName: AppCoreLocalization.string("Names cannot contain control characters.", locale: locale)
    }
  }
}

public struct HostDraft: Equatable, Sendable {
  public let displayName: String
  public let address: String
  public let environment: HostEnvironment
  public let workspaceID: String?
  public let groupID: String?
  public let tags: [String]?
  public let protocols: [String]?

  public init(
    displayName: String,
    address: String,
    environment: HostEnvironment,
    workspaceID: String? = nil,
    groupID: String? = nil,
    tags: [String]? = nil, protocols: [String]? = nil
  ) {
    self.tags = tags
    self.protocols = protocols
    self.displayName = displayName
    self.address = address
    self.environment = environment
    self.workspaceID = workspaceID
    self.groupID = groupID
  }
}

public struct HostRecord: Equatable, Identifiable, Sendable {
  public let id: String
  public let workspaceID: String
  public let groupID: String?
  public let displayName: String
  public let address: String
  public let environment: HostEnvironment
  public let version: Int64
  /// Tag names and connection protocols ("ssh"/"rdp"); populated by listHosts for search/filter (FR-003).
  public let tags: [String]
  public let protocols: [String]

  public init(
    id: String,
    workspaceID: String,
    groupID: String? = nil,
    displayName: String,
    address: String,
    environment: HostEnvironment,
    version: Int64,
    tags: [String] = [],
    protocols: [String] = []
  ) {
    self.tags = tags
    self.protocols = protocols
    self.id = id
    self.workspaceID = workspaceID
    self.groupID = groupID
    self.displayName = displayName
    self.address = address
    self.environment = environment
    self.version = version
  }
}

public protocol HostRepository: AnyObject {
  func listWorkspaces() throws -> [WorkspaceRecord]
  func listGroups(workspaceID: String) throws -> [HostGroupRecord]
  func listHosts() throws -> [HostRecord]
  func createWorkspace(name: String) throws -> WorkspaceRecord
  func updateWorkspace(id: String, expectedVersion: Int64, name: String) throws -> WorkspaceRecord
  func deleteWorkspace(id: String, expectedVersion: Int64) throws
  func createGroup(workspaceID: String, name: String) throws -> HostGroupRecord
  func updateGroup(id: String, expectedVersion: Int64, name: String) throws -> HostGroupRecord
  func deleteGroup(id: String, expectedVersion: Int64) throws
  func createHost(_ draft: HostDraft) throws -> HostRecord
  func updateHost(id: String, expectedVersion: Int64, draft: HostDraft) throws -> HostRecord
  func moveHost(id: String, expectedVersion: Int64, toWorkspaceID: String, groupID: String?) throws -> HostRecord
  func deleteHost(id: String) throws
  func importInventory(
    workspaces: [ImportedWorkspaceDraft],
    groups: [ImportedGroupDraft],
    hosts: [ImportedHostDraft],
    conflictPolicy: ImportConflictPolicy
  ) throws -> ImportExecutionResult
}

// MARK: - Audit Events (FR-013, FR-026)

public enum AuditOutcome: String, Sendable, Codable, Equatable {
  case success
  case failure
  case denied
}

public struct AuditEventRecord: Equatable, Identifiable, Sendable {
  public let id: String
  public let action: String
  public let entityType: String
  public let entityID: String?
  public let outcome: AuditOutcome
  public let errorCode: String?
  public let occurredAt: Date

  public init(
    id: String = UUID().uuidString.lowercased(),
    action: String,
    entityType: String,
    entityID: String? = nil,
    outcome: AuditOutcome,
    errorCode: String? = nil,
    occurredAt: Date = Date()
  ) {
    self.id = id
    self.action = action
    self.entityType = entityType
    self.entityID = entityID
    self.outcome = outcome
    self.errorCode = errorCode
    self.occurredAt = occurredAt
  }
}

public protocol AuditRepository: AnyObject {
  func recordAuditEvent(
    action: String,
    entityType: String,
    entityID: String?,
    outcome: AuditOutcome,
    errorCode: String?
  ) throws
  func listAuditEvents(limit: Int) throws -> [AuditEventRecord]
}

public protocol RdpHostTrustRepository: AnyObject, Sendable {
  func getRdpHostTrust(host: String, port: Int) throws -> RdpCertificateRecord?
  func recordRdpHostTrust(record: RdpCertificateRecord) throws
  func deleteRdpHostTrust(host: String, port: Int) throws
  func listRdpHostTrust() throws -> [RdpCertificateRecord]
}

// MARK: - Import & Export Models (FR-014, US-004)

public struct ImportedWorkspaceDraft: Sendable, Equatable {
  public let name: String
  public init(name: String) { self.name = name }
}

public struct ImportedGroupDraft: Sendable, Equatable {
  public let workspaceName: String
  public let name: String
  public let snippets: [ExportedSnippet]?
  public init(workspaceName: String, name: String, snippets: [ExportedSnippet]? = nil) {
    self.workspaceName = workspaceName
    self.name = name
    self.snippets = snippets
  }
}

public struct ImportedHostDraft: Sendable, Equatable {
  public let workspaceName: String
  public let groupName: String?
  public let displayName: String
  public let address: String
  public let environment: HostEnvironment
  public let tags: [String]?
  public let profiles: [ExportedProfile]?
  public let protocols: [String]?
  public let sshSettings: SSHConnectionSettings?
  public let snippets: [ExportedSnippet]?
  public let matchAliasOnly: Bool

  public init(
    workspaceName: String,
    groupName: String?,
    displayName: String,
    address: String,
    environment: HostEnvironment, tags: [String]? = nil, profiles: [ExportedProfile]? = nil, protocols: [String]? = nil,
    sshSettings: SSHConnectionSettings? = nil, snippets: [ExportedSnippet]? = nil, matchAliasOnly: Bool = false
  ) {
    self.tags = tags; self.profiles = profiles; self.protocols = protocols; self.sshSettings = sshSettings
    self.snippets = snippets; self.matchAliasOnly = matchAliasOnly
    self.workspaceName = workspaceName
    self.groupName = groupName
    self.displayName = displayName
    self.address = address
    self.environment = environment
  }
}

public enum ImportConflictPolicy: String, CaseIterable, Identifiable, Sendable {
  case skip = "Skip existing"
  case overwrite = "Update existing"
  case keepBoth = "Import as copy"

  public var id: Self { self }
}

public struct ImportExecutionResult: Sendable, Equatable {
  public let addedHostsCount: Int
  public let updatedHostsCount: Int
  public let skippedHostsCount: Int
  public let createdWorkspacesCount: Int
  public let createdGroupsCount: Int

  public init(
    addedHostsCount: Int = 0,
    updatedHostsCount: Int = 0,
    skippedHostsCount: Int = 0,
    createdWorkspacesCount: Int = 0,
    createdGroupsCount: Int = 0
  ) {
    self.addedHostsCount = addedHostsCount
    self.updatedHostsCount = updatedHostsCount
    self.skippedHostsCount = skippedHostsCount
    self.createdWorkspacesCount = createdWorkspacesCount
    self.createdGroupsCount = createdGroupsCount
  }
}

/// Kind of secret a credential reference protects.
public enum CredentialKind: String, CaseIterable, Sendable, Equatable {
  case password
  case keyPassphrase = "key_passphrase"
  case rdpPassword = "rdp_password"

  public var title: String {
    switch self {
    case .password: "SSH password"
    case .keyPassphrase: "Key passphrase"
    case .rdpPassword: "Windows / RDP password"
    }
  }
}

/// Opaque reference metadata for a Keychain-backed credential. Secret values
/// never pass through this record (FR-004).
public struct CredentialRefRecord: Equatable, Identifiable, Sendable {
  public let id: String
  public let label: String
  public let kind: CredentialKind
  /// Opaque Keychain reference (service/account) with no secret material.
  public let keychainItemID: String

  public init(id: String, label: String, kind: CredentialKind, keychainItemID: String) {
    self.id = id
    self.label = label
    self.kind = kind
    self.keychainItemID = keychainItemID
  }
}

public enum CredentialRefValidationError: Error, Equatable, AppCoreLocalizedError {
  case emptyLabel
  case labelTooLong
  case invalidLabel

  public func displayDescription(locale: Locale?) -> String? {
    switch self {
    case .emptyLabel: AppCoreLocalization.string("Enter a credential label.", locale: locale)
    case .labelTooLong: AppCoreLocalization.string("Credential labels must be 120 characters or fewer.", locale: locale)
    case .invalidLabel: AppCoreLocalization.string("Credential labels cannot contain control characters.", locale: locale)
    }
  }
}

/// Metadata repository for Keychain credential references.
public protocol CredentialRefRepository: AnyObject {
  func listCredentialRefs() throws -> [CredentialRefRecord]
  /// Persists one reference after the secret already exists in the Keychain.
  func createCredentialRef(label: String, kind: CredentialKind, keychainItemID: String) throws -> CredentialRefRecord
  func updateCredentialRef(id: String, expectedLabel: String, label: String) throws -> CredentialRefRecord
  func deleteCredentialRef(id: String) throws
  /// Number of stored connection profiles that still reference this credential.
  func credentialRefUsageCount(id: String) throws -> Int
}


public enum HostValidationError: Error, Equatable, AppCoreLocalizedError {
  case emptyDisplayName
  case displayNameTooLong
  case invalidDisplayName
  case invalidAddress

  public func displayDescription(locale: Locale?) -> String? {
    switch self {
    case .emptyDisplayName: AppCoreLocalization.string("Enter a host name.", locale: locale)
    case .displayNameTooLong: AppCoreLocalization.string("Host names must be 120 characters or fewer.", locale: locale)
    case .invalidDisplayName: AppCoreLocalization.string("Host names cannot contain control characters.", locale: locale)
    case .invalidAddress: AppCoreLocalization.string("Enter a host name or IP address using supported characters.", locale: locale)
    }
  }
}

public enum SQLiteRepositoryError: Error, Equatable, AppCoreLocalizedError {
  case sqlite(code: Int32, message: String)
  case unsupportedSchemaVersion(Int32)
  case missingMigration(String)
  case foreignKeyViolation
  case localPermissionDenied
  case invalidStoredEnvironment
  case workspaceNotFound
  case workspaceRequired
  case workspaceChanged
  case workspaceInUse
  case groupNotFound
  case groupChanged
  case groupNameAlreadyExists
  case groupWorkspaceMismatch
  case hostNotFound
  case hostChanged
  case hostInUse
  case commandSnippetNotFound
  case commandSnippetChanged
  case commandSnippetOwnerNotFound
  case invalidStoredCommandSnippet
  case credentialRefNotFound
  case credentialRefChanged
  case credentialRefInUse
  case invalidStoredCredentialRef
  case closed

  public func displayDescription(locale: Locale?) -> String? {
    switch self {
    case .sqlite:
      AppCoreLocalization.string("The local host database could not complete the operation.", locale: locale)
    case .unsupportedSchemaVersion:
      AppCoreLocalization.string("The local host database was created by a newer app version.", locale: locale)
    case .missingMigration:
      AppCoreLocalization.string("A required local database migration is missing.", locale: locale)
    case .foreignKeyViolation:
      AppCoreLocalization.string("The database migration would break existing references.", locale: locale)
    case .localPermissionDenied:
      AppCoreLocalization.string("The app could not secure the local host database file.", locale: locale)
    case .invalidStoredEnvironment:
      AppCoreLocalization.string("The database contains an unsupported host environment.", locale: locale)
    case .workspaceNotFound:
      AppCoreLocalization.string("The selected workspace no longer exists.", locale: locale)
    case .workspaceRequired:
      AppCoreLocalization.string("Select a workspace before adding a host.", locale: locale)
    case .workspaceChanged:
      AppCoreLocalization.string("This workspace changed in another window. Reopen it before saving.", locale: locale)
    case .workspaceInUse:
      AppCoreLocalization.string("Close active sessions or transfers in this workspace before deleting it.", locale: locale)
    case .groupNotFound:
      AppCoreLocalization.string("The selected group no longer exists.", locale: locale)
    case .groupChanged:
      AppCoreLocalization.string("This group changed in another window. Reopen it before saving.", locale: locale)
    case .groupNameAlreadyExists:
      AppCoreLocalization.string("A group with this name already exists in the workspace.", locale: locale)
    case .groupWorkspaceMismatch:
      AppCoreLocalization.string("Choose a group that belongs to the selected workspace.", locale: locale)
    case .hostNotFound:
      AppCoreLocalization.string("The host no longer exists.", locale: locale)
    case .hostChanged:
      AppCoreLocalization.string("This host changed in another window. Reopen it before saving.", locale: locale)
    case .hostInUse:
      AppCoreLocalization.string("Close the host's active session or transfer before deleting it.", locale: locale)
    case .commandSnippetNotFound:
      AppCoreLocalization.string("The command snippet no longer exists.", locale: locale)
    case .commandSnippetChanged:
      AppCoreLocalization.string("This command snippet changed in another window. Reopen it before saving.", locale: locale)
    case .commandSnippetOwnerNotFound:
      AppCoreLocalization.string("The host or group for this command snippet no longer exists.", locale: locale)
    case .invalidStoredCommandSnippet:
      AppCoreLocalization.string("The local database contains an invalid command snippet.", locale: locale)
    case .credentialRefNotFound:
      AppCoreLocalization.string("The credential reference no longer exists.", locale: locale)
    case .credentialRefChanged:
      AppCoreLocalization.string("This credential changed in another window. Reload it before saving.", locale: locale)
    case .credentialRefInUse:
      AppCoreLocalization.string("This credential is still referenced by a saved connection profile. Unlink it first.", locale: locale)
    case .invalidStoredCredentialRef:
      AppCoreLocalization.string("The local database contains an invalid credential reference.", locale: locale)
    case .closed:
      AppCoreLocalization.string("The local host database is closed.", locale: locale)
    }
  }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Uses the app's existing SQLite schema and migration history without replacing the database.
public final class SQLiteHostRepository: HostRepository, CommandSnippetRepository, AuditRepository, RdpHostTrustRepository, @unchecked Sendable {
  private var connection: OpaquePointer?
  private let databaseURL: URL
  private let databaseExistedWithData: Bool

  static var migrationDirectory: URL {
    get throws {
      guard let directory = Bundle.module.url(forResource: "Migrations", withExtension: nil) else {
        throw SQLiteRepositoryError.missingMigration("Migrations")
      }
      return directory
    }
  }

  public static func applicationDatabaseURL(applicationSupportDirectory: URL) -> URL {
    applicationSupportDirectory
      .appendingPathComponent("org.macremoteworkspace.desktop", isDirectory: true)
      .appendingPathComponent("metadata.sqlite")
  }

  static func applicationSupportDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
    if environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
      return FileManager.default.temporaryDirectory.appendingPathComponent("MacRemoteWorkspacePreviews", isDirectory: true)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
  }

  public static func openApplicationRepository() throws -> SQLiteHostRepository {
    guard let supportDirectory = applicationSupportDirectory() else {
      throw CocoaError(.fileNoSuchFile)
    }
    let url = applicationDatabaseURL(applicationSupportDirectory: supportDirectory)
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let repository = try SQLiteHostRepository(databaseURL: url)
    try repository.importLegacySSHConnectionSettings(from: .standard)
    return repository
  }

  public init(databaseURL: URL) throws {
    self.databaseURL = databaseURL
    let existingAttributes = try? FileManager.default.attributesOfItem(atPath: databaseURL.path)
    databaseExistedWithData = ((existingAttributes?[.size] as? NSNumber)?.intValue ?? 0) > 0
    try FileManager.default.createDirectory(
      at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)

    let fd = open(databaseURL.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
    if fd >= 0 { Darwin.close(fd) }
    else if errno != EEXIST { throw SQLiteRepositoryError.localPermissionDenied }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)

    var database: OpaquePointer?
    let openStatus = databaseURL.path.withCString {
      sqlite3_open_v2(
        $0, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
    }
    guard openStatus == SQLITE_OK, let database else {
      if let database { sqlite3_close_v2(database) }
      throw SQLiteRepositoryError.sqlite(
        code: openStatus, message: "Could not open local metadata database")
    }
    connection = database

    do {
      try executeBatch("PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000; PRAGMA journal_mode = WAL;")
      try migrate(from: Self.migrationDirectory, backUpExistingDatabase: databaseExistedWithData)
      do {
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
      } catch {
        throw SQLiteRepositoryError.localPermissionDenied
      }
    } catch {
      sqlite3_close_v2(database)
      connection = nil
      throw error
    }
  }

  deinit {
    if let connection { sqlite3_close_v2(connection) }
  }

  public func listWorkspaces() throws -> [WorkspaceRecord] {
    let statement = try prepare(
      "SELECT id, name, version FROM workspaces ORDER BY name COLLATE NOCASE ASC, created_at ASC")
    defer { sqlite3_finalize(statement) }

    var workspaces: [WorkspaceRecord] = []
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { return workspaces }
      guard status == SQLITE_ROW else { throw lastError() }
      workspaces.append(WorkspaceRecord(
        id: columnText(statement, 0), name: columnText(statement, 1),
        version: sqlite3_column_int64(statement, 2)
      ))
    }
  }

  public func listGroups(workspaceID: String) throws -> [HostGroupRecord] {
    let statement = try prepare(
      "SELECT id, workspace_id, name, sort_order, version FROM host_groups "
        + "WHERE workspace_id = ? ORDER BY sort_order ASC, name COLLATE NOCASE ASC")
    defer { sqlite3_finalize(statement) }
    try bind([workspaceID], to: statement)

    var groups: [HostGroupRecord] = []
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { return groups }
      guard status == SQLITE_ROW else { throw lastError() }
      groups.append(HostGroupRecord(
        id: columnText(statement, 0), workspaceID: columnText(statement, 1),
        name: columnText(statement, 2), sortOrder: Int(sqlite3_column_int(statement, 3)),
        version: sqlite3_column_int64(statement, 4)
      ))
    }
  }

  @discardableResult
  public func createWorkspace(name: String) throws -> WorkspaceRecord {
    let name = try validatedOrganizationName(name)
    let id = UUID().uuidString.lowercased()
    try execute("INSERT INTO workspaces (id, name) VALUES (?, ?)", [id, name])
    guard let workspace = try workspace(id: id) else { throw SQLiteRepositoryError.workspaceNotFound }
    return workspace
  }

  @discardableResult
  public func updateWorkspace(id: String, expectedVersion: Int64, name: String) throws -> WorkspaceRecord {
    let name = try validatedOrganizationName(name)
    let changes = try execute(
      "UPDATE workspaces SET name = ?, updated_at = CURRENT_TIMESTAMP, version = version + 1 "
        + "WHERE id = ? AND version = ?",
      [name, id, String(expectedVersion)]
    )
    guard changes > 0 else {
      guard try workspace(id: id) != nil else { throw SQLiteRepositoryError.workspaceNotFound }
      throw SQLiteRepositoryError.workspaceChanged
    }
    guard let workspace = try workspace(id: id) else { throw SQLiteRepositoryError.workspaceNotFound }
    return workspace
  }

  public func deleteWorkspace(id: String, expectedVersion: Int64) throws {
    do {
      try inImmediateTransaction {
        guard let workspace = try workspace(id: id) else { throw SQLiteRepositoryError.workspaceNotFound }
        guard workspace.version == expectedVersion else { throw SQLiteRepositoryError.workspaceChanged }
        if try workspaceHasActiveActivity(id: id) { throw SQLiteRepositoryError.workspaceInUse }
        guard try execute("DELETE FROM workspaces WHERE id = ?", [id]) > 0 else {
          throw SQLiteRepositoryError.workspaceChanged
        }
      }
    } catch let error as SQLiteRepositoryError {
      if case .sqlite(let code, _) = error, code & 0xff == SQLITE_CONSTRAINT {
        throw SQLiteRepositoryError.workspaceInUse
      }
      throw error
    }
  }

  @discardableResult
  public func createGroup(workspaceID: String, name: String) throws -> HostGroupRecord {
    let name = try validatedOrganizationName(name)
    do {
      return try inImmediateTransaction {
        guard try workspace(id: workspaceID) != nil else { throw SQLiteRepositoryError.workspaceNotFound }
        if try groupNameExists(workspaceID: workspaceID, name: name) {
          throw SQLiteRepositoryError.groupNameAlreadyExists
        }
        let id = UUID().uuidString.lowercased()
        let order = try nextGroupSortOrder(workspaceID: workspaceID)
        try execute(
          "INSERT INTO host_groups (id, workspace_id, name, sort_order) VALUES (?, ?, ?, ?)",
          [id, workspaceID, name, String(order)]
        )
        guard let group = try group(id: id) else { throw SQLiteRepositoryError.groupNotFound }
        return group
      }
    } catch let error as SQLiteRepositoryError {
      if case .sqlite(let code, _) = error, code & 0xff == SQLITE_CONSTRAINT {
        throw SQLiteRepositoryError.groupNameAlreadyExists
      }
      throw error
    }
  }

  @discardableResult
  public func updateGroup(id: String, expectedVersion: Int64, name: String) throws -> HostGroupRecord {
    let name = try validatedOrganizationName(name)
    do {
      return try inImmediateTransaction {
        guard let current = try group(id: id) else { throw SQLiteRepositoryError.groupNotFound }
        guard current.version == expectedVersion else { throw SQLiteRepositoryError.groupChanged }
        if try groupNameExists(workspaceID: current.workspaceID, name: name, excludingID: id) {
          throw SQLiteRepositoryError.groupNameAlreadyExists
        }
        let changes = try execute(
          "UPDATE host_groups SET name = ?, updated_at = CURRENT_TIMESTAMP, version = version + 1 "
            + "WHERE id = ? AND version = ?",
          [name, id, String(expectedVersion)]
        )
        guard changes > 0 else { throw SQLiteRepositoryError.groupChanged }
        guard let group = try group(id: id) else { throw SQLiteRepositoryError.groupNotFound }
        return group
      }
    } catch let error as SQLiteRepositoryError {
      if case .sqlite(let code, _) = error, code & 0xff == SQLITE_CONSTRAINT {
        throw SQLiteRepositoryError.groupNameAlreadyExists
      }
      throw error
    }
  }

  public func deleteGroup(id: String, expectedVersion: Int64) throws {
    try inImmediateTransaction {
      guard let current = try group(id: id) else { throw SQLiteRepositoryError.groupNotFound }
      guard current.version == expectedVersion else { throw SQLiteRepositoryError.groupChanged }
      guard try execute("DELETE FROM host_groups WHERE id = ? AND version = ?", [id, String(expectedVersion)]) > 0
      else { throw SQLiteRepositoryError.groupChanged }
    }
  }

  public func listHosts() throws -> [HostRecord] {
    let statement = try prepare(
      "SELECT id, workspace_id, group_id, display_name, address, environment, version, "
        + "(SELECT group_concat(t.name, char(31)) FROM host_tags ht JOIN tags t ON t.id = ht.tag_id WHERE ht.host_id = hosts.id), "
        + "(SELECT CASE WHEN ssh_enabled = 1 THEN 'ssh' ELSE '' END || CASE WHEN rdp_enabled = 1 THEN ',rdp' ELSE '' END FROM host_protocols WHERE host_id = hosts.id) "
        + "FROM hosts ORDER BY display_name COLLATE NOCASE ASC, created_at ASC")
    defer { sqlite3_finalize(statement) }

    var hosts: [HostRecord] = []
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { return hosts }
      guard status == SQLITE_ROW else { throw lastError() }
      let base = try host(from: statement)
      hosts.append(
        HostRecord(
          id: base.id, workspaceID: base.workspaceID, groupID: base.groupID,
          displayName: base.displayName, address: base.address, environment: base.environment,
          version: base.version,
          tags: (optionalColumnText(statement, 7) ?? "").split(separator: "\u{1F}").map(String.init),
          protocols: (optionalColumnText(statement, 8) ?? "").split(separator: ",").map(String.init)))
    }
  }

  public func listCommandSnippets(hostID: String, groupID: String?) throws -> [CommandSnippetRecord] {
    let statement = try prepare(
      "SELECT id, title, command_text, host_id, group_id, version FROM command_snippets "
        + "WHERE host_id = ? OR group_id = ? ORDER BY title COLLATE NOCASE ASC, created_at ASC")
    defer { sqlite3_finalize(statement) }
    try bind([hostID, groupID ?? ""], to: statement)

    var snippets: [CommandSnippetRecord] = []
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { return snippets }
      guard status == SQLITE_ROW else { throw lastError() }
      snippets.append(try commandSnippet(from: statement))
    }
  }

  @discardableResult
  public func createCommandSnippet(_ draft: CommandSnippetDraft) throws -> CommandSnippetRecord {
    let draft = try draft.validated()
    return try inImmediateTransaction {
      try validateSnippetOwner(draft.scope)
      let id = UUID().uuidString.lowercased()
      switch draft.scope {
      case .host(let hostID):
        try execute(
          "INSERT INTO command_snippets (id, title, command_text, host_id) VALUES (?, ?, ?, ?)",
          [id, draft.title, draft.commandText, hostID]
        )
      case .group(let groupID):
        try execute(
          "INSERT INTO command_snippets (id, title, command_text, group_id) VALUES (?, ?, ?, ?)",
          [id, draft.title, draft.commandText, groupID]
        )
      }
      guard let snippet = try commandSnippet(id: id) else {
        throw SQLiteRepositoryError.commandSnippetNotFound
      }
      return snippet
    }
  }

  @discardableResult
  public func updateCommandSnippet(
    id: String, expectedVersion: Int64, draft: CommandSnippetDraft
  ) throws -> CommandSnippetRecord {
    let draft = try draft.validated()
    return try inImmediateTransaction {
      guard let current = try commandSnippet(id: id) else {
        throw SQLiteRepositoryError.commandSnippetNotFound
      }
      guard current.version == expectedVersion else {
        throw SQLiteRepositoryError.commandSnippetChanged
      }
      try validateSnippetOwner(draft.scope)
      switch draft.scope {
      case .host(let hostID):
        try execute(
          "UPDATE command_snippets SET title = ?, command_text = ?, host_id = ?, group_id = NULL, "
            + "updated_at = CURRENT_TIMESTAMP, version = version + 1 WHERE id = ? AND version = ?",
          [draft.title, draft.commandText, hostID, id, String(expectedVersion)]
        )
      case .group(let groupID):
        try execute(
          "UPDATE command_snippets SET title = ?, command_text = ?, host_id = NULL, group_id = ?, "
            + "updated_at = CURRENT_TIMESTAMP, version = version + 1 WHERE id = ? AND version = ?",
          [draft.title, draft.commandText, groupID, id, String(expectedVersion)]
        )
      }
      guard let updated = try commandSnippet(id: id) else {
        throw SQLiteRepositoryError.commandSnippetNotFound
      }
      return updated
    }
  }

  public func deleteCommandSnippet(id: String, expectedVersion: Int64) throws {
    try inImmediateTransaction {
      guard let current = try commandSnippet(id: id) else {
        throw SQLiteRepositoryError.commandSnippetNotFound
      }
      guard current.version == expectedVersion else {
        throw SQLiteRepositoryError.commandSnippetChanged
      }
      guard try execute(
        "DELETE FROM command_snippets WHERE id = ? AND version = ?", [id, String(expectedVersion)]
      ) > 0 else {
        throw SQLiteRepositoryError.commandSnippetChanged
      }
    }
  }

  @discardableResult
  public func createHost(_ draft: HostDraft) throws -> HostRecord {
    try inImmediateTransaction {
      let normalized = try validated(draft)
      if normalized.groupID != nil && normalized.workspaceID?.isEmpty != false { throw SQLiteRepositoryError.workspaceRequired }
      let workspaceID = try resolveWorkspaceID(normalized.workspaceID)
      try validateHostGroup(normalized.groupID, workspaceID: workspaceID)
      let id = UUID().uuidString.lowercased()
      let groupID = normalized.groupID
      try execute("INSERT INTO hosts (id, workspace_id, group_id, display_name, address, environment) "
        + "VALUES (?, ?, \(groupID == nil ? "NULL" : "?"), ?, ?, ?)",
        [id, workspaceID] + (groupID.map { [$0] } ?? []) + [normalized.displayName, normalized.address, normalized.environment.rawValue])
      try updateHostMetadata(id: id, tags: normalized.tags, protocols: normalized.protocols)
      guard let host = try listHosts().first(where: { $0.id == id }) else { throw SQLiteRepositoryError.hostNotFound }
      return host
    }
  }

  @discardableResult
  public func updateHost(id: String, expectedVersion: Int64, draft: HostDraft) throws -> HostRecord {
    try inImmediateTransaction {
      let normalized = try validated(draft)
      guard let current = try host(id: id) else { throw SQLiteRepositoryError.hostNotFound }
      guard current.version == expectedVersion else { throw SQLiteRepositoryError.hostChanged }
      let workspaceID = normalized.workspaceID ?? current.workspaceID
      let groupID = normalized.workspaceID == nil ? current.groupID : normalized.groupID
      guard try workspace(id: workspaceID) != nil else { throw SQLiteRepositoryError.workspaceNotFound }
      try validateHostGroup(groupID, workspaceID: workspaceID)
      let changes = try execute("UPDATE hosts SET display_name = ?, address = ?, environment = ?, workspace_id = ?, "
        + "group_id = \(groupID == nil ? "NULL" : "?"), updated_at = CURRENT_TIMESTAMP, version = version + 1 WHERE id = ? AND version = ?",
        [normalized.displayName, normalized.address, normalized.environment.rawValue, workspaceID] + (groupID.map { [$0] } ?? []) + [id, String(expectedVersion)])
      guard changes > 0 else { throw SQLiteRepositoryError.hostChanged }
      try updateHostMetadata(id: id, tags: normalized.tags, protocols: normalized.protocols)
      guard let result = try listHosts().first(where: { $0.id == id }) else { throw SQLiteRepositoryError.hostNotFound }
      return result
    }
  }

  private func validateHostGroup(_ groupID: String?, workspaceID: String) throws {
    guard let groupID else { return }
    guard let group = try group(id: groupID) else { throw SQLiteRepositoryError.groupNotFound }
    guard group.workspaceID == workspaceID else { throw SQLiteRepositoryError.groupWorkspaceMismatch }
  }

  private func updateHostMetadata(id: String, tags: [String]?, protocols: [String]?) throws {
    if let tags {
      try execute("DELETE FROM host_tags WHERE host_id = ?", [id])
      for tag in tags {
        let name = try validatedOrganizationName(tag)
        try execute("INSERT OR IGNORE INTO tags (id, name, normalized_name) VALUES (?, ?, ?)",
          [UUID().uuidString.lowercased(), name, name.lowercased()])
        try execute("INSERT OR IGNORE INTO host_tags (host_id, tag_id) SELECT ?, id FROM tags WHERE normalized_name = ?", [id, name.lowercased()])
      }
    }
    if let protocols {
      guard Set(protocols).isSubset(of: ["ssh", "rdp"]) else { throw SQLiteRepositoryError.sqlite(code: SQLITE_CONSTRAINT, message: "Invalid protocol") }
      try execute("UPDATE host_protocols SET ssh_enabled = ?, rdp_enabled = ? WHERE host_id = ?",
        [protocols.contains("ssh") ? "1" : "0", protocols.contains("rdp") ? "1" : "0", id])
    }
  }

  @discardableResult
  public func moveHost(
    id: String,
    expectedVersion: Int64,
    toWorkspaceID workspaceID: String,
    groupID: String?
  ) throws -> HostRecord {
    try inImmediateTransaction {
      guard try workspace(id: workspaceID) != nil else { throw SQLiteRepositoryError.workspaceNotFound }
      if let groupID {
        guard let group = try group(id: groupID) else { throw SQLiteRepositoryError.groupNotFound }
        guard group.workspaceID == workspaceID else { throw SQLiteRepositoryError.groupWorkspaceMismatch }
      }
      let changes: Int32
      if let groupID {
        changes = try execute(
          "UPDATE hosts SET workspace_id = ?, group_id = ?, updated_at = CURRENT_TIMESTAMP, "
            + "version = version + 1 WHERE id = ? AND version = ?",
          [workspaceID, groupID, id, String(expectedVersion)]
        )
      } else {
        changes = try execute(
          "UPDATE hosts SET workspace_id = ?, group_id = NULL, updated_at = CURRENT_TIMESTAMP, "
            + "version = version + 1 WHERE id = ? AND version = ?",
          [workspaceID, id, String(expectedVersion)]
        )
      }
      guard changes > 0 else {
        guard try host(id: id) != nil else { throw SQLiteRepositoryError.hostNotFound }
        throw SQLiteRepositoryError.hostChanged
      }
      guard let host = try host(id: id) else { throw SQLiteRepositoryError.hostNotFound }
      return host
    }
  }

  public func deleteHost(id: String) throws {
    if try hostHasActiveActivity(id: id) { throw SQLiteRepositoryError.hostInUse }
    do {
      guard try execute("DELETE FROM hosts WHERE id = ?", [id]) > 0 else {
        throw SQLiteRepositoryError.hostNotFound
      }
    } catch let error as SQLiteRepositoryError {
      if case .sqlite(let code, _) = error, code & 0xff == SQLITE_CONSTRAINT {
        throw SQLiteRepositoryError.hostInUse
      }
      throw error
    }
  }

  public func close() throws {
    guard let connection else { return }
    try executeBatch("PRAGMA wal_checkpoint(TRUNCATE);")
    let status = sqlite3_close_v2(connection)
    guard status == SQLITE_OK else { throw lastError(code: status) }
    self.connection = nil
  }

  // MARK: - Credential References (metadata only; secrets live in the Keychain)

  public func listCredentialRefs() throws -> [CredentialRefRecord] {
    let statement = try prepare(
      "SELECT id, label, kind, keychain_item_id FROM credential_refs ORDER BY label COLLATE NOCASE ASC, id ASC")
    defer { sqlite3_finalize(statement) }

    var records: [CredentialRefRecord] = []
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { return records }
      guard status == SQLITE_ROW else { throw lastError() }
      let record = try credentialRef(from: statement)
      records.append(record)
    }
  }

  @discardableResult
  public func createCredentialRef(label: String, kind: CredentialKind, keychainItemID: String) throws -> CredentialRefRecord {
    let label = try validatedCredentialLabel(label)
    guard KeychainCredentialReference.decode(keychainItemID) != nil else {
      throw CredentialRefValidationError.invalidLabel
    }
    let id = UUID().uuidString.lowercased()
    do {
      try execute(
        "INSERT INTO credential_refs (id, label, kind, keychain_item_id) VALUES (?, ?, ?, ?)",
        [id, label, kind.rawValue, keychainItemID]
      )
    } catch let error as SQLiteRepositoryError {
      RedactedLogger.shared.error("credential", "create failed")
      if case .sqlite(let code, _) = error, code & 0xff == SQLITE_CONSTRAINT {
        throw CredentialRefValidationError.invalidLabel
      }
      throw error
    }
    guard let record = try credentialRef(id: id) else {
      throw SQLiteRepositoryError.credentialRefNotFound
    }
    _ = try? recordAuditEvent(
      action: "credential.create", entityType: "credential", entityID: id, outcome: .success, errorCode: nil)
    return record
  }

  @discardableResult
  public func updateCredentialRef(id: String, expectedLabel: String, label: String) throws -> CredentialRefRecord {
    let label = try validatedCredentialLabel(label)
    let expectedLabel = try validatedCredentialLabel(expectedLabel)
    let changes = try execute(
      "UPDATE credential_refs SET label = ? WHERE id = ? AND label = ?",
      [label, id, expectedLabel]
    )
    guard changes > 0 else {
      guard try credentialRef(id: id) != nil else { throw SQLiteRepositoryError.credentialRefNotFound }
      throw SQLiteRepositoryError.credentialRefChanged
    }
    guard let record = try credentialRef(id: id) else {
      throw SQLiteRepositoryError.credentialRefNotFound
    }
    return record
  }

  public func deleteCredentialRef(id: String) throws {
    do {
      guard try execute("DELETE FROM credential_refs WHERE id = ?", [id]) > 0 else {
        throw SQLiteRepositoryError.credentialRefNotFound
      }
      _ = try? recordAuditEvent(
        action: "credential.delete", entityType: "credential", entityID: id, outcome: .success, errorCode: nil)
    } catch let error as SQLiteRepositoryError {
      RedactedLogger.shared.error("credential", "delete failed \(id)")
      if case .sqlite(let code, _) = error, code & 0xff == SQLITE_CONSTRAINT {
        throw SQLiteRepositoryError.credentialRefInUse
      }
      throw error
    }
  }

  public func sshConnectionSettings(hostID: String) throws -> SSHConnectionSettings? {
    let statement = try prepare("SELECT username, port, auth_method, credential_id, key_file_path, proxy_jump FROM host_connection_settings WHERE host_id = ?")
    defer { sqlite3_finalize(statement) }
    try bind([hostID], to: statement)
    let status = sqlite3_step(statement)
    if status == SQLITE_DONE { return nil }
    guard status == SQLITE_ROW else { throw lastError() }
    guard let auth = SSHConnectionSettings.Auth(rawValue: columnText(statement, 2)) else {
      throw SQLiteRepositoryError.sqlite(code: SQLITE_CORRUPT, message: "Invalid SSH authentication method")
    }
    return SSHConnectionSettings(username: columnText(statement, 0), port: Int(sqlite3_column_int(statement, 1)),
      auth: auth, credentialID: optionalColumnText(statement, 3), keyFilePath: columnText(statement, 4), proxyJump: optionalColumnText(statement, 5))
  }

  public func upsertSSHConnectionSettings(hostID: String, settings: SSHConnectionSettings) throws {
    if let jump = settings.proxyJump { try SSHConnectionSettings.validateProxyJump(jump) }
    let ref = settings.credentialID
    try execute("INSERT INTO host_connection_settings (host_id, username, port, auth_method, credential_id, key_file_path, proxy_jump) "
      + "VALUES (?, ?, ?, ?, \(ref == nil ? "NULL" : "?"), ?, \(settings.proxyJump == nil ? "NULL" : "?")) ON CONFLICT(host_id) DO UPDATE SET "
      + "username = excluded.username, port = excluded.port, auth_method = excluded.auth_method, "
      + "credential_id = excluded.credential_id, key_file_path = excluded.key_file_path, proxy_jump = excluded.proxy_jump",
      [hostID, settings.username, String(settings.port), settings.auth.rawValue] + (ref.map { [$0] } ?? []) + [settings.keyFilePath] + (settings.proxyJump.map { [$0] } ?? []))
  }

  public func deleteSSHConnectionSettings(hostID: String) throws {
    try execute("DELETE FROM host_connection_settings WHERE host_id = ?", [hostID])
  }

  /// Import only valid presets for existing hosts; leave unreadable or orphaned entries available for recovery.
  public func importLegacySSHConnectionSettings(from defaults: UserDefaults) throws {
    let prefix = "ssh.preset."
    let entries = defaults.dictionaryRepresentation().compactMap { key, value -> (String, String, SSHConnectionSettings)? in
      guard key.hasPrefix(prefix), let data = value as? Data,
        let settings = try? JSONDecoder().decode(SSHConnectionSettings.self, from: data),
        (1...65535).contains(settings.port) else { return nil }
      return (key, String(key.dropFirst(prefix.count)), settings)
    }
    guard !entries.isEmpty else { return }
    let imported = try inImmediateTransaction { () -> [String] in
      var keys: [String] = []
      for (key, hostID, settings) in entries {
        guard try host(id: hostID) != nil else { continue }
        if try sshConnectionSettings(hostID: hostID) == nil {
          try upsertSSHConnectionSettings(hostID: hostID, settings: settings)
        }
        keys.append(key)
      }
      return keys
    }
    for key in imported { defaults.removeObject(forKey: key) }
  }

  public func exportedProfiles(hostID: String) throws -> [ExportedProfile] {
    let statement = try prepare("SELECT protocol, port, username, auth_method, private_key_path FROM connection_profiles WHERE host_id = ? ORDER BY rowid")
    defer { sqlite3_finalize(statement) }
    try bind([hostID], to: statement)
    var result: [ExportedProfile] = []
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { return result }
      guard status == SQLITE_ROW else { throw lastError() }
      let proto = columnText(statement, 0)
      let method = columnText(statement, 3)
      result.append(ExportedProfile(protocolName: proto, port: Int(sqlite3_column_int(statement, 1)),
        username: columnText(statement, 2), authMethod: method,
        keyPath: optionalColumnText(statement, 4)))
    }
  }

  public func exportedSnippets(hostID: String?, groupID: String?) throws -> [ExportedSnippet] {
    let records = try listCommandSnippets(hostID: hostID ?? "", groupID: groupID)
    return try records.map { snippet in
      _ = try CommandSnippetDraft(title: snippet.title, commandText: snippet.commandText, scope: snippet.scope).validated()
      return ExportedSnippet(title: snippet.title, command: snippet.commandText)
    }
  }

  private func importSnippets(_ snippets: [ExportedSnippet], hostID: String? = nil, groupID: String? = nil) throws {
    let owner = hostID.map(CommandSnippetScope.host) ?? .group(groupID!)
    for snippet in snippets {
      let draft = try CommandSnippetDraft(title: snippet.title, commandText: snippet.command, scope: owner).validated()
      let column = hostID == nil ? "group_id" : "host_id"
      let statement = try prepare("SELECT 1 FROM command_snippets WHERE \(column) = ? AND title = ? AND command_text = ? LIMIT 1")
      defer { sqlite3_finalize(statement) }
      try bind([owner.ownerID, draft.title, draft.commandText], to: statement)
      let status = sqlite3_step(statement)
      if status == SQLITE_ROW { continue }
      guard status == SQLITE_DONE else { throw lastError() }
      try execute("INSERT INTO command_snippets (id, title, command_text, \(column)) VALUES (?, ?, ?, ?)",
        [UUID().uuidString.lowercased(), draft.title, draft.commandText, owner.ownerID])
    }
  }

  private func importHostMetadata(_ draft: ImportedHostDraft, hostID: String) throws {
    if let settings = draft.sshSettings { try upsertSSHConnectionSettings(hostID: hostID, settings: settings) }
    let protocols = draft.protocols ?? draft.profiles.map { Array(Set($0.map(\.protocolName))) }
      ?? (draft.matchAliasOnly ? ["ssh"] : nil)
    try updateHostMetadata(id: hostID, tags: draft.tags, protocols: protocols)
    if let profiles = draft.profiles {
      let existing = try exportedProfiles(hostID: hostID)
      for profile in profiles where !existing.contains(profile) {
        let method = profile.authMethod
        let keyPath = profile.keyPath
        try execute("INSERT INTO connection_profiles (id, host_id, protocol, port, username, auth_method, private_key_path) "
          + "VALUES (?, ?, ?, ?, ?, ?, \(keyPath == nil ? "NULL" : "?"))",
          [UUID().uuidString.lowercased(), hostID, profile.protocolName, String(profile.port), profile.username, method] + (keyPath.map { [$0] } ?? []))
      }
    }
    if let snippets = draft.snippets { try importSnippets(snippets, hostID: hostID) }
  }

  /// Most recently updated RDP profile for a host: (username, credentialRefID), used to prefill launch UI.
  public func rdpProfileDefaults(hostID: String) throws -> (port: Int, username: String, credentialRefID: String?)? {
    let statement = try prepare(
      "SELECT port, username, credential_ref_id FROM connection_profiles "
        + "WHERE host_id = ? AND protocol = 'rdp' ORDER BY updated_at DESC, rowid DESC LIMIT 1")
    defer { sqlite3_finalize(statement) }
    try bind([hostID], to: statement)
    let status = sqlite3_step(statement)
    if status == SQLITE_DONE { return nil }
    guard status == SQLITE_ROW else { throw lastError() }
    let ref = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : columnText(statement, 2)
    return (Int(sqlite3_column_int(statement, 0)), columnText(statement, 1), ref)
  }

  /// Upserts the single RDP profile for a host (username + credential reference only, never secrets).
  public func upsertRdpProfile(hostID: String, port: Int, username: String, credentialRefID: String?) throws {
    let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
    let method = credentialRefID == nil ? "external" : "password"
    let find = try prepare(
      "SELECT id FROM connection_profiles WHERE host_id = ? AND protocol = 'rdp' "
        + "ORDER BY updated_at DESC, rowid DESC LIMIT 1")
    defer { sqlite3_finalize(find) }
    try bind([hostID], to: find)
    let status = sqlite3_step(find)
    guard status == SQLITE_ROW || status == SQLITE_DONE else { throw lastError() }
    let existing = status == SQLITE_ROW ? columnText(find, 0) : nil
    let ref = credentialRefID
    if let existing {
      let sql = "UPDATE connection_profiles SET port = ?, username = ?, auth_method = ?, "
        + "credential_ref_id = \(ref == nil ? "NULL" : "?"), updated_at = CURRENT_TIMESTAMP, "
        + "version = version + 1 WHERE id = ?"
      try execute(sql, [String(port), user, method] + (ref.map { [$0] } ?? []) + [existing])
    } else {
      let sql = "INSERT INTO connection_profiles (id, host_id, protocol, port, username, auth_method, "
        + "credential_ref_id) VALUES (?, ?, 'rdp', ?, ?, ?, \(ref == nil ? "NULL" : "?"))"
      try execute(
        sql, [UUID().uuidString.lowercased(), hostID, String(port), user, method] + (ref.map { [$0] } ?? []))
    }
    try execute("UPDATE host_protocols SET rdp_enabled = 1 WHERE host_id = ?", [hostID])
  }

  public func credentialRefUsageCount(id: String) throws -> Int {
    let statement = try prepare(
      "SELECT COUNT(*) FROM connection_profiles WHERE credential_ref_id = ?")
    defer { sqlite3_finalize(statement) }
    try bind([id], to: statement)
    guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
    return Int(sqlite3_column_int(statement, 0))
  }

  private func credentialRef(from statement: OpaquePointer) throws -> CredentialRefRecord {
    guard let kind = CredentialKind(rawValue: columnText(statement, 2)) else {
      throw SQLiteRepositoryError.invalidStoredCredentialRef
    }
    let record = CredentialRefRecord(
      id: columnText(statement, 0),
      label: columnText(statement, 1),
      kind: kind,
      keychainItemID: columnText(statement, 3)
    )
    guard KeychainCredentialReference.decode(record.keychainItemID) != nil else {
      throw SQLiteRepositoryError.invalidStoredCredentialRef
    }
    return record
  }

  private func credentialRef(id: String) throws -> CredentialRefRecord? {
    let statement = try prepare(
      "SELECT id, label, kind, keychain_item_id FROM credential_refs WHERE id = ?")
    defer { sqlite3_finalize(statement) }
    try bind([id], to: statement)
    let status = sqlite3_step(statement)
    if status == SQLITE_DONE { return nil }
    guard status == SQLITE_ROW else { throw lastError() }
    return try credentialRef(from: statement)
  }

  private func validatedCredentialLabel(_ label: String) throws -> String {
    let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !label.isEmpty else { throw CredentialRefValidationError.emptyLabel }
    guard label.utf8.count <= 120 else { throw CredentialRefValidationError.labelTooLong }
    guard label.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
      throw CredentialRefValidationError.invalidLabel
    }
    return label
  }

  var schemaVersion: Int32 {
    get throws {
      let statement = try prepare("PRAGMA user_version")
      defer { sqlite3_finalize(statement) }
      guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
      return sqlite3_column_int(statement, 0)
    }
  }

  private func resolveWorkspaceID(_ requestedID: String?) throws -> String {
    if let requestedID = requestedID?.trimmingCharacters(in: .whitespacesAndNewlines),
      !requestedID.isEmpty
    {
      let statement = try prepare("SELECT 1 FROM workspaces WHERE id = ?")
      defer { sqlite3_finalize(statement) }
      try bind([requestedID], to: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { throw SQLiteRepositoryError.workspaceNotFound }
      return requestedID
    }

    let defaultID = UUID().uuidString.lowercased()
    try execute(
      "INSERT INTO workspaces (id, name) "
        + "SELECT ?, 'Local' WHERE NOT EXISTS (SELECT 1 FROM workspaces)",
      [defaultID]
    )
    let statement = try prepare("SELECT id FROM workspaces ORDER BY created_at ASC, id ASC LIMIT 2")
    defer { sqlite3_finalize(statement) }
    let firstStatus = sqlite3_step(statement)
    guard firstStatus == SQLITE_ROW else { throw lastError() }
    let firstID = columnText(statement, 0)
    let secondStatus = sqlite3_step(statement)
    if secondStatus == SQLITE_ROW { throw SQLiteRepositoryError.workspaceRequired }
    guard secondStatus == SQLITE_DONE else { throw lastError() }
    return firstID
  }

  private func host(id: String) throws -> HostRecord? {
    let statement = try prepare(
      "SELECT id, workspace_id, group_id, display_name, address, environment, version FROM hosts WHERE id = ?")
    defer { sqlite3_finalize(statement) }
    try bind([id], to: statement)
    let status = sqlite3_step(statement)
    if status == SQLITE_DONE { return nil }
    guard status == SQLITE_ROW else { throw lastError() }
    return try host(from: statement)
  }

  private func workspace(id: String) throws -> WorkspaceRecord? {
    let statement = try prepare("SELECT id, name, version FROM workspaces WHERE id = ?")
    defer { sqlite3_finalize(statement) }
    try bind([id], to: statement)
    let status = sqlite3_step(statement)
    if status == SQLITE_DONE { return nil }
    guard status == SQLITE_ROW else { throw lastError() }
    return WorkspaceRecord(
      id: columnText(statement, 0), name: columnText(statement, 1),
      version: sqlite3_column_int64(statement, 2)
    )
  }

  private func group(id: String) throws -> HostGroupRecord? {
    let statement = try prepare(
      "SELECT id, workspace_id, name, sort_order, version FROM host_groups WHERE id = ?")
    defer { sqlite3_finalize(statement) }
    try bind([id], to: statement)
    let status = sqlite3_step(statement)
    if status == SQLITE_DONE { return nil }
    guard status == SQLITE_ROW else { throw lastError() }
    return HostGroupRecord(
      id: columnText(statement, 0), workspaceID: columnText(statement, 1),
      name: columnText(statement, 2), sortOrder: Int(sqlite3_column_int(statement, 3)),
      version: sqlite3_column_int64(statement, 4)
    )
  }

  private func commandSnippet(id: String) throws -> CommandSnippetRecord? {
    let statement = try prepare(
      "SELECT id, title, command_text, host_id, group_id, version FROM command_snippets WHERE id = ?")
    defer { sqlite3_finalize(statement) }
    try bind([id], to: statement)
    let status = sqlite3_step(statement)
    if status == SQLITE_DONE { return nil }
    guard status == SQLITE_ROW else { throw lastError() }
    return try commandSnippet(from: statement)
  }

  private func commandSnippet(from statement: OpaquePointer) throws -> CommandSnippetRecord {
    let hostID = optionalColumnText(statement, 3)
    let groupID = optionalColumnText(statement, 4)
    let scope: CommandSnippetScope
    switch (hostID, groupID) {
    case (.some(let id), .none): scope = .host(id)
    case (.none, .some(let id)): scope = .group(id)
    default: throw SQLiteRepositoryError.invalidStoredCommandSnippet
    }
    let snippet = CommandSnippetRecord(
      id: columnText(statement, 0), title: columnText(statement, 1),
      commandText: columnText(statement, 2), scope: scope,
      version: sqlite3_column_int64(statement, 5)
    )
    guard let validated = try? CommandSnippetDraft(
      title: snippet.title, commandText: snippet.commandText, scope: snippet.scope
    ).validated(), validated.title == snippet.title, validated.commandText == snippet.commandText else {
      throw SQLiteRepositoryError.invalidStoredCommandSnippet
    }
    return snippet
  }

  private func validateSnippetOwner(_ scope: CommandSnippetScope) throws {
    switch scope {
    case .host(let hostID):
      guard try host(id: hostID) != nil else { throw SQLiteRepositoryError.commandSnippetOwnerNotFound }
    case .group(let groupID):
      guard try group(id: groupID) != nil else { throw SQLiteRepositoryError.commandSnippetOwnerNotFound }
    }
  }

  private func groupNameExists(workspaceID: String, name: String, excludingID: String? = nil) throws -> Bool {
    let exclusion = excludingID == nil ? "" : " AND id <> ?"
    let statement = try prepare(
      "SELECT EXISTS (SELECT 1 FROM host_groups WHERE workspace_id = ? AND name = ? COLLATE NOCASE\(exclusion))")
    defer { sqlite3_finalize(statement) }
    var values = [workspaceID, name]
    if let excludingID { values.append(excludingID) }
    try bind(values, to: statement)
    guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
    return sqlite3_column_int(statement, 0) != 0
  }

  private func nextGroupSortOrder(workspaceID: String) throws -> Int {
    let statement = try prepare("SELECT COALESCE(MAX(sort_order), -1) + 1 FROM host_groups WHERE workspace_id = ?")
    defer { sqlite3_finalize(statement) }
    try bind([workspaceID], to: statement)
    guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
    return Int(sqlite3_column_int(statement, 0))
  }

  private func host(from statement: OpaquePointer) throws -> HostRecord {
    guard let environment = HostEnvironment(rawValue: columnText(statement, 5)) else {
      throw SQLiteRepositoryError.invalidStoredEnvironment
    }
    return HostRecord(
      id: columnText(statement, 0),
      workspaceID: columnText(statement, 1),
      groupID: optionalColumnText(statement, 2),
      displayName: columnText(statement, 3),
      address: columnText(statement, 4),
      environment: environment,
      version: sqlite3_column_int64(statement, 6)
    )
  }

  private func hostHasActiveActivity(id: String) throws -> Bool {
    let statement = try prepare(
      "SELECT EXISTS (SELECT 1 FROM connection_profiles p "
        + "WHERE p.host_id = ? AND ("
        + "EXISTS (SELECT 1 FROM recent_sessions s WHERE s.connection_profile_id = p.id "
        + "AND s.status IN ('resolving','connecting','verifying_host','authenticating','connected','interrupted','closing')) "
        + "OR EXISTS (SELECT 1 FROM transfer_jobs t WHERE t.connection_profile_id = p.id "
        + "AND t.status IN ('created','validating','running','verifying'))))")
    defer { sqlite3_finalize(statement) }
    try bind([id], to: statement)
    guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
    return sqlite3_column_int(statement, 0) != 0
  }

  private func workspaceHasActiveActivity(id: String) throws -> Bool {
    let statement = try prepare(
      "SELECT EXISTS (SELECT 1 FROM hosts h JOIN connection_profiles p ON p.host_id = h.id "
        + "WHERE h.workspace_id = ? AND ("
        + "EXISTS (SELECT 1 FROM recent_sessions s WHERE s.connection_profile_id = p.id "
        + "AND s.status IN ('resolving','connecting','verifying_host','authenticating','connected','interrupted','closing')) "
        + "OR EXISTS (SELECT 1 FROM transfer_jobs t WHERE t.connection_profile_id = p.id "
        + "AND t.status IN ('created','validating','running','verifying'))))")
    defer { sqlite3_finalize(statement) }
    try bind([id], to: statement)
    guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
    return sqlite3_column_int(statement, 0) != 0
  }

  private func validatedOrganizationName(_ name: String) throws -> String {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw OrganizationNameValidationError.emptyName }
    guard name.unicodeScalars.count <= 80 else { throw OrganizationNameValidationError.nameTooLong }
    guard !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
      throw OrganizationNameValidationError.invalidName
    }
    return name
  }

  private func inImmediateTransaction<T>(_ body: () throws -> T) throws -> T {
    try executeBatch("BEGIN IMMEDIATE;")
    do {
      let result = try body()
      try executeBatch("COMMIT;")
      return result
    } catch {
      try? executeBatch("ROLLBACK;")
      throw error
    }
  }

  private func validated(_ draft: HostDraft) throws -> HostDraft {
    let displayName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    let address = draft.address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !displayName.isEmpty else { throw HostValidationError.emptyDisplayName }
    guard displayName.unicodeScalars.count <= 120 else {
      throw HostValidationError.displayNameTooLong
    }
    guard !displayName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
      throw HostValidationError.invalidDisplayName
    }
    // shortcut: retain the existing host-alias allowlist; validate DNS/IP syntax before transport connects.
    let allowedAddressCharacters = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:_")
    guard !address.isEmpty, address.utf8.count <= 253,
      !address.hasPrefix("-") && !address.hasPrefix(".") && !address.hasSuffix(".") &&
        address.unicodeScalars.allSatisfy(allowedAddressCharacters.contains)
    else {
      throw HostValidationError.invalidAddress
    }
    let groupID = draft.groupID?.trimmingCharacters(in: .whitespacesAndNewlines)
    return HostDraft(
      displayName: displayName,
      address: address,
      environment: draft.environment,
      workspaceID: draft.workspaceID,
      groupID: groupID?.isEmpty == false ? groupID : nil, tags: draft.tags, protocols: draft.protocols
    )
  }

  private func migrate(from directory: URL, backUpExistingDatabase: Bool) throws {
    let currentVersion = try schemaVersion
    let migrations: [(Int32, String)] = [
      (1, "0001_initial.sql"), (2, "0002_rdp_profiles.sql"), (3, "0003_command_snippets.sql"),
      (4, "0004_rdp_embedded_and_host_trust.sql"),
      (5, "0005_rdp_credential_kind.sql"), (6, "0006_host_connection_settings.sql"), (7, "0007_ssh_proxy_jump.sql"), (8, "0008_host_protocols.sql"),
    ]
    guard (0...8).contains(currentVersion) else {
      throw SQLiteRepositoryError.unsupportedSchemaVersion(currentVersion)
    }
    guard currentVersion < 8 else { return }

    if backUpExistingDatabase { try makePreMigrationBackup(version: currentVersion) }
    for (version, filename) in migrations where version > currentVersion {
      let migrationURL = directory.appendingPathComponent(filename)
      guard FileManager.default.fileExists(atPath: migrationURL.path) else {
        throw SQLiteRepositoryError.missingMigration(filename)
      }
      let sql = try String(contentsOf: migrationURL, encoding: .utf8)
      let rebuildsReferencedTable = version == 2 || version == 4 || version == 5
      if rebuildsReferencedTable { try executeBatch("PRAGMA foreign_keys = OFF;") }
      do {
        try executeBatch("BEGIN IMMEDIATE;")
        try executeBatch(sql)
        if try hasForeignKeyViolation() { throw SQLiteRepositoryError.foreignKeyViolation }
        try executeBatch("PRAGMA user_version = \(version);")
        try executeBatch("COMMIT;")
      } catch {
        try? executeBatch("ROLLBACK;")
        if rebuildsReferencedTable { try? executeBatch("PRAGMA foreign_keys = ON;") }
        throw error
      }
      if rebuildsReferencedTable { try executeBatch("PRAGMA foreign_keys = ON;") }
    }
  }

  private func makePreMigrationBackup(version: Int32) throws {
    guard
      FileManager.default.fileExists(atPath: databaseURL.path),
      let attributes = try? FileManager.default.attributesOfItem(atPath: databaseURL.path),
      ((attributes[.size] as? NSNumber)?.intValue ?? 0) > 0
    else { return }

    try executeBatch("PRAGMA wal_checkpoint(TRUNCATE);")
    let backupName =
      "\(databaseURL.deletingPathExtension().lastPathComponent).sqlite.bak-v\(version)-\(UUID().uuidString)"
    let backupURL = databaseURL.deletingLastPathComponent().appendingPathComponent(backupName)
    try FileManager.default.copyItem(at: databaseURL, to: backupURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
    let prefix = "\(databaseURL.deletingPathExtension().lastPathComponent).sqlite.bak-v"
    let backups = try FileManager.default.contentsOfDirectory(at: backupURL.deletingLastPathComponent(), includingPropertiesForKeys: [.contentModificationDateKey])
      .filter { $0.lastPathComponent.hasPrefix(prefix) }
      .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
    for old in backups.dropFirst(3) { try FileManager.default.removeItem(at: old) }
  }

  private func hasForeignKeyViolation() throws -> Bool {
    let statement = try prepare("PRAGMA foreign_key_check")
    defer { sqlite3_finalize(statement) }
    let status = sqlite3_step(statement)
    if status == SQLITE_ROW { return true }
    guard status == SQLITE_DONE else { throw lastError() }
    return false
  }

  @discardableResult
  private func execute(_ sql: String, _ values: [String]) throws -> Int32 {
    let statement = try prepare(sql)
    defer { sqlite3_finalize(statement) }
    try bind(values, to: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    guard let connection else { throw SQLiteRepositoryError.closed }
    return sqlite3_changes(connection)
  }

  private func bind(_ values: [String], to statement: OpaquePointer) throws {
    for (offset, value) in values.enumerated() {
      let status = value.withCString {
        sqlite3_bind_text(statement, Int32(offset + 1), $0, -1, sqliteTransient)
      }
      guard status == SQLITE_OK else { throw lastError(code: status) }
    }
  }

  private func prepare(_ sql: String) throws -> OpaquePointer {
    guard let connection else { throw SQLiteRepositoryError.closed }
    var statement: OpaquePointer?
    let status = sql.withCString { sqlite3_prepare_v2(connection, $0, -1, &statement, nil) }
    guard status == SQLITE_OK, let statement else { throw lastError(code: status) }
    return statement
  }

  private func executeBatch(_ sql: String) throws {
    guard let connection else { throw SQLiteRepositoryError.closed }
    var errorMessage: UnsafeMutablePointer<CChar>?
    let status = sql.withCString { sqlite3_exec(connection, $0, nil, nil, &errorMessage) }
    guard status == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) } ?? "SQLite operation failed"
      sqlite3_free(errorMessage)
      throw SQLiteRepositoryError.sqlite(code: status, message: message)
    }
  }

  private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
    guard let value = sqlite3_column_text(statement, index) else { return "" }
    return String(cString: value)
  }

  private func optionalColumnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : columnText(statement, index)
  }

  private func lastError(code: Int32? = nil) -> SQLiteRepositoryError {
    let status = code ?? connection.map(sqlite3_errcode) ?? SQLITE_MISUSE
    let message =
      connection.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite connection is closed"
    return .sqlite(code: status, message: message)
  }

  // MARK: - Audit Events (FR-013, FR-026)

  public func recordAuditEvent(
    action: String,
    entityType: String,
    entityID: String?,
    outcome: AuditOutcome,
    errorCode: String?
  ) throws {
    let id = UUID().uuidString.lowercased()
    _ = try execute(
      "INSERT INTO audit_events (id, action, entity_type, entity_id, outcome, error_code) VALUES (?, ?, ?, ?, ?, ?)",
      [id, action, entityType, entityID ?? "", outcome.rawValue, errorCode ?? ""]
    )
  }

  public func listAuditEvents(limit: Int = 100) throws -> [AuditEventRecord] {
    let statement = try prepare(
      "SELECT id, action, entity_type, entity_id, outcome, error_code, strftime('%Y-%m-%dT%H:%M:%SZ', occurred_at) "
        + "FROM audit_events ORDER BY occurred_at DESC, id DESC LIMIT ?"
    )
    defer { sqlite3_finalize(statement) }
    try bind([String(limit)], to: statement)
    var events: [AuditEventRecord] = []
    let formatter = ISO8601DateFormatter()
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { return events }
      guard status == SQLITE_ROW else { throw lastError() }
      let id = columnText(statement, 0)
      let action = columnText(statement, 1)
      let entityType = columnText(statement, 2)
      let rawEntityID = optionalColumnText(statement, 3)
      let entityID = (rawEntityID?.isEmpty == false) ? rawEntityID : nil
      let rawOutcome = columnText(statement, 4)
      let outcome = AuditOutcome(rawValue: rawOutcome) ?? .failure
      let rawErrorCode = optionalColumnText(statement, 5)
      let errorCode = (rawErrorCode?.isEmpty == false) ? rawErrorCode : nil
      let occurredAtStr = columnText(statement, 6)
      let occurredAt = formatter.date(from: occurredAtStr) ?? Date()
      events.append(AuditEventRecord(
        id: id,
        action: action,
        entityType: entityType,
        entityID: entityID,
        outcome: outcome,
        errorCode: errorCode,
        occurredAt: occurredAt
      ))
    }
  }

  // MARK: - Inventory Import (FR-014, US-004, TC-012)

  public func importInventory(
    workspaces: [ImportedWorkspaceDraft],
    groups: [ImportedGroupDraft],
    hosts: [ImportedHostDraft],
    conflictPolicy: ImportConflictPolicy
  ) throws -> ImportExecutionResult {
    do {
      let result = try inImmediateTransaction {
        var addedHosts = 0
        var updatedHosts = 0
        var skippedHosts = 0
        var createdWorkspaces = 0
        var createdGroups = 0

        // Build workspace cache by lowercase name
        var workspaceByName: [String: WorkspaceRecord] = [:]
        for ws in try listWorkspaces() {
          workspaceByName[ws.name.lowercased()] = ws
        }

        // 1. Create missing workspaces
        for wsDraft in workspaces {
          let trimmed = try validatedOrganizationName(wsDraft.name)
          let key = trimmed.lowercased()
          if workspaceByName[key] == nil {
            let id = UUID().uuidString.lowercased()
            _ = try execute("INSERT INTO workspaces (id, name) VALUES (?, ?)", [id, trimmed])
            guard let created = try workspace(id: id) else {
              throw SQLiteRepositoryError.workspaceNotFound
            }
            workspaceByName[key] = created
            createdWorkspaces += 1
          }
        }

        // If no workspace was imported or exists, ensure at least "Local" workspace exists
        if workspaceByName.isEmpty {
          let defaultID = UUID().uuidString.lowercased()
          _ = try execute("INSERT INTO workspaces (id, name) VALUES (?, 'Local')", [defaultID])
          guard let created = try workspace(id: defaultID) else {
            throw SQLiteRepositoryError.workspaceNotFound
          }
          workspaceByName["local"] = created
          createdWorkspaces += 1
        }

        // Build group cache by "\(workspaceID):\(groupName.lowercased())"
        var groupByName: [String: HostGroupRecord] = [:]
        for ws in workspaceByName.values {
          for grp in try listGroups(workspaceID: ws.id) {
            groupByName["\(ws.id):\(grp.name.lowercased())"] = grp
          }
        }

        // 2. Create missing groups
        for grpDraft in groups {
          let wsNameTrimmed = grpDraft.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
          let wsKey = wsNameTrimmed.lowercased()
          guard let targetWs = workspaceByName[wsKey] ?? workspaceByName.values.first else {
            throw SQLiteRepositoryError.workspaceNotFound
          }
          let grpTrimmed = try validatedOrganizationName(grpDraft.name)
          let grpKey = "\(targetWs.id):\(grpTrimmed.lowercased())"
          if groupByName[grpKey] == nil {
            let id = UUID().uuidString.lowercased()
            let nextSort = try nextGroupSortOrder(workspaceID: targetWs.id)
            _ = try execute(
              "INSERT INTO host_groups (id, workspace_id, name, sort_order) VALUES (?, ?, ?, ?)",
              [id, targetWs.id, grpTrimmed, String(nextSort)]
            )
            guard let created = try group(id: id) else {
              throw SQLiteRepositoryError.groupNotFound
            }
            groupByName[grpKey] = created
            createdGroups += 1
          }
          if let group = groupByName[grpKey], let snippets = grpDraft.snippets {
            try importSnippets(snippets, groupID: group.id)
          }
        }

        // 3. Process hosts
        let existingHosts = try listHosts()

        for hostDraft in hosts {
          let wsName = hostDraft.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
          let targetWs = workspaceByName[wsName.lowercased()] ?? workspaceByName.values.first!

          var groupID: String? = nil
          if let grpName = hostDraft.groupName?.trimmingCharacters(in: .whitespacesAndNewlines), !grpName.isEmpty {
            let grpKey = "\(targetWs.id):\(grpName.lowercased())"
            if let grp = groupByName[grpKey] {
              groupID = grp.id
            } else {
              // Create the group if it didn't exist in groups list
              let validGrpName = try validatedOrganizationName(grpName)
              let id = UUID().uuidString.lowercased()
              let nextSort = try nextGroupSortOrder(workspaceID: targetWs.id)
              _ = try execute(
                "INSERT INTO host_groups (id, workspace_id, name, sort_order) VALUES (?, ?, ?, ?)",
                [id, targetWs.id, validGrpName, String(nextSort)]
              )
              guard let created = try group(id: id) else {
                throw SQLiteRepositoryError.groupNotFound
              }
              groupByName[grpKey] = created
              groupID = id
              createdGroups += 1
            }
          }

          let draft = try validated(HostDraft(
            displayName: hostDraft.displayName,
            address: hostDraft.address,
            environment: hostDraft.environment,
            workspaceID: targetWs.id,
            groupID: groupID
          ))

          // Conflict detection in the target workspace:
          // A conflict is defined as existing host in same workspace with same address OR same display name
          let conflict = existingHosts.first { h in
            h.workspaceID == targetWs.id && (
              (!hostDraft.matchAliasOnly && h.address.caseInsensitiveCompare(draft.address) == .orderedSame) ||
              h.displayName.caseInsensitiveCompare(draft.displayName) == .orderedSame
            )
          }

          if let existing = conflict {
            switch conflictPolicy {
            case .skip:
              skippedHosts += 1
            case .overwrite:
              if let groupID {
                _ = try execute(
                  "UPDATE hosts SET display_name = ?, address = ?, environment = ?, group_id = ?, "
                    + "updated_at = CURRENT_TIMESTAMP, version = version + 1 WHERE id = ?",
                  [draft.displayName, draft.address, draft.environment.rawValue, groupID, existing.id]
                )
              } else {
                _ = try execute(
                  "UPDATE hosts SET display_name = ?, address = ?, environment = ?, group_id = NULL, "
                    + "updated_at = CURRENT_TIMESTAMP, version = version + 1 WHERE id = ?",
                  [draft.displayName, draft.address, draft.environment.rawValue, existing.id]
                )
              }
              try importHostMetadata(hostDraft, hostID: existing.id)
              updatedHosts += 1
            case .keepBoth:
              let renamed = "\(draft.displayName) (Imported)"
              let newDraft = try validated(HostDraft(
                displayName: renamed,
                address: draft.address,
                environment: draft.environment,
                workspaceID: targetWs.id,
                groupID: groupID
              ))
              let newID = UUID().uuidString.lowercased()
              if let groupID {
                _ = try execute(
                  "INSERT INTO hosts (id, workspace_id, group_id, display_name, address, environment) "
                    + "VALUES (?, ?, ?, ?, ?, ?)",
                  [newID, targetWs.id, groupID, newDraft.displayName, newDraft.address, newDraft.environment.rawValue]
                )
              } else {
                _ = try execute(
                  "INSERT INTO hosts (id, workspace_id, display_name, address, environment) "
                    + "VALUES (?, ?, ?, ?, ?)",
                  [newID, targetWs.id, newDraft.displayName, newDraft.address, newDraft.environment.rawValue]
                )
              }
              try importHostMetadata(hostDraft, hostID: newID)
              addedHosts += 1
            }
          } else {
            let newID = UUID().uuidString.lowercased()
            if let groupID {
              _ = try execute(
                "INSERT INTO hosts (id, workspace_id, group_id, display_name, address, environment) "
                  + "VALUES (?, ?, ?, ?, ?, ?)",
                [newID, targetWs.id, groupID, draft.displayName, draft.address, draft.environment.rawValue]
              )
            } else {
              _ = try execute(
                "INSERT INTO hosts (id, workspace_id, display_name, address, environment) "
                  + "VALUES (?, ?, ?, ?, ?)",
                [newID, targetWs.id, draft.displayName, draft.address, draft.environment.rawValue]
              )
            }
            try importHostMetadata(hostDraft, hostID: newID)
            addedHosts += 1
          }
        }

        let result = ImportExecutionResult(
          addedHostsCount: addedHosts,
          updatedHostsCount: updatedHosts,
          skippedHostsCount: skippedHosts,
          createdWorkspacesCount: createdWorkspaces,
          createdGroupsCount: createdGroups
        )

        _ = try? recordAuditEvent(
          action: "inventory.import",
          entityType: "inventory",
          entityID: nil,
          outcome: .success,
          errorCode: nil
        )

        RedactedLogger.shared.info("import", "inventory import succeeded")
        return result
      }
      return result
    } catch {
      RedactedLogger.shared.error("import", "inventory import failed")
      let errorCode = error is InventoryImportExportError || error is HostValidationError
        || error is OrganizationNameValidationError ? "validation_failed" : "import_failed"
      _ = try? recordAuditEvent(
        action: "inventory.import",
        entityType: "inventory",
        entityID: nil,
        outcome: .failure,
        errorCode: errorCode
      )
      throw error
    }
  }

  // MARK: - RDP Host Trust (ADR-011, FR-021, US-021)

  public func getRdpHostTrust(host: String, port: Int) throws -> RdpCertificateRecord? {
    let statement = try prepare(
      "SELECT host, port, sha256_fingerprint, subject_cn, issuer_cn, created_at, updated_at, version "
        + "FROM rdp_host_trust WHERE host = ? AND port = ?"
    )
    defer { sqlite3_finalize(statement) }
    try bind([host, String(port)], to: statement)

    let status = sqlite3_step(statement)
    if status == SQLITE_DONE { return nil }
    guard status == SQLITE_ROW else { throw lastError() }

    let hostVal = columnText(statement, 0)
    let portVal = Int(sqlite3_column_int(statement, 1))
    let fp = columnText(statement, 2)
    let subject = columnText(statement, 3)
    let issuer = columnText(statement, 4)
    let version = sqlite3_column_int64(statement, 7)
    return RdpCertificateRecord(
      host: hostVal,
      port: portVal,
      sha256Fingerprint: fp,
      subjectCN: subject,
      issuerCN: issuer,
      version: version
    )
  }

  public func recordRdpHostTrust(record: RdpCertificateRecord) throws {
    let id = UUID().uuidString.lowercased()
    try inImmediateTransaction {
      let existing = try getRdpHostTrust(host: record.host, port: record.port)
      if existing != nil {
        _ = try execute(
          "UPDATE rdp_host_trust SET sha256_fingerprint = ?, subject_cn = ?, issuer_cn = ?, updated_at = CURRENT_TIMESTAMP, version = version + 1 "
            + "WHERE host = ? AND port = ?",
          [record.sha256Fingerprint, record.subjectCN, record.issuerCN, record.host, String(record.port)]
        )
      } else {
        _ = try execute(
          "INSERT INTO rdp_host_trust (id, host, port, sha256_fingerprint, subject_cn, issuer_cn) "
            + "VALUES (?, ?, ?, ?, ?, ?)",
          [id, record.host, String(record.port), record.sha256Fingerprint, record.subjectCN, record.issuerCN]
        )
      }
    }
  }

  public func deleteRdpHostTrust(host: String, port: Int) throws {
    _ = try execute("DELETE FROM rdp_host_trust WHERE host = ? AND port = ?", [host, String(port)])
  }

  public func listRdpHostTrust() throws -> [RdpCertificateRecord] {
    let statement = try prepare(
      "SELECT host, port, sha256_fingerprint, subject_cn, issuer_cn, created_at, updated_at, version "
        + "FROM rdp_host_trust ORDER BY host ASC, port ASC"
    )
    defer { sqlite3_finalize(statement) }

    var results: [RdpCertificateRecord] = []
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { return results }
      guard status == SQLITE_ROW else { throw lastError() }

      let hostVal = columnText(statement, 0)
      let portVal = Int(sqlite3_column_int(statement, 1))
      let fp = columnText(statement, 2)
      let subject = columnText(statement, 3)
      let issuer = columnText(statement, 4)
      let version = sqlite3_column_int64(statement, 7)
      results.append(RdpCertificateRecord(
        host: hostVal,
        port: portVal,
        sha256Fingerprint: fp,
        subjectCN: subject,
        issuerCN: issuer,
        version: version
      ))
    }
  }
}
