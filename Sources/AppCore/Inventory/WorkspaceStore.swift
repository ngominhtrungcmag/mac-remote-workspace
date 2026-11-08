import Combine
import Foundation

@MainActor
public final class WorkspaceStore: ObservableObject {
  @Published public private(set) var workspaces: [WorkspaceRecord] = []
  @Published public private(set) var groups: [HostGroupRecord] = []
  @Published public private(set) var hosts: [HostRecord] = []
  @Published public private(set) var storageError: String?

  private var repository: HostRepository?

  public init() {
    retry()
  }

  public init(repository: HostRepository) {
    self.repository = repository
    retry()
  }

  public func retry() {
    do {
      if repository == nil {
        guard let supportDirectory = FileManager.default.urls(
          for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
          throw CocoaError(.fileNoSuchFile)
        }
        repository = try SQLiteHostRepository(
          databaseURL: SQLiteHostRepository.applicationDatabaseURL(
            applicationSupportDirectory: supportDirectory
          )
        )
      }
      try reload()
    } catch {
      storageError = error.localizedDescription
    }
  }

  public func reload() throws {
    guard let repository else { throw SQLiteRepositoryError.closed }
    let loadedWorkspaces = try repository.listWorkspaces()
    var loadedGroups: [HostGroupRecord] = []
    for workspace in loadedWorkspaces {
      loadedGroups += try repository.listGroups(workspaceID: workspace.id)
    }
    let loadedHosts = try repository.listHosts()
    workspaces = loadedWorkspaces
    groups = loadedGroups
    hosts = loadedHosts
    storageError = nil
  }

  @discardableResult
  public func createWorkspace(name: String) throws -> WorkspaceRecord {
    let workspace = try requiredRepository().createWorkspace(name: name)
    try reload()
    return workspace
  }

  @discardableResult
  public func updateWorkspace(id: String, expectedVersion: Int64, name: String) throws -> WorkspaceRecord {
    let workspace = try requiredRepository().updateWorkspace(id: id, expectedVersion: expectedVersion, name: name)
    try reload()
    return workspace
  }

  public func deleteWorkspace(id: String, expectedVersion: Int64) throws {
    try requiredRepository().deleteWorkspace(id: id, expectedVersion: expectedVersion)
    try reload()
  }

  @discardableResult
  public func createGroup(workspaceID: String, name: String) throws -> HostGroupRecord {
    let group = try requiredRepository().createGroup(workspaceID: workspaceID, name: name)
    try reload()
    return group
  }

  @discardableResult
  public func updateGroup(id: String, expectedVersion: Int64, name: String) throws -> HostGroupRecord {
    let group = try requiredRepository().updateGroup(id: id, expectedVersion: expectedVersion, name: name)
    try reload()
    return group
  }

  public func deleteGroup(id: String, expectedVersion: Int64) throws {
    try requiredRepository().deleteGroup(id: id, expectedVersion: expectedVersion)
    try reload()
  }

  @discardableResult
  public func createHost(_ draft: HostDraft) throws -> HostRecord {
    let host = try requiredRepository().createHost(draft)
    try reload()
    return host
  }

  @discardableResult
  public func updateHost(id: String, expectedVersion: Int64, draft: HostDraft) throws -> HostRecord {
    let host = try requiredRepository().updateHost(id: id, expectedVersion: expectedVersion, draft: draft)
    try reload()
    return host
  }

  @discardableResult
  public func moveHost(
    id: String,
    expectedVersion: Int64,
    toWorkspaceID workspaceID: String,
    groupID: String?
  ) throws -> HostRecord {
    let host = try requiredRepository().moveHost(
      id: id, expectedVersion: expectedVersion, toWorkspaceID: workspaceID, groupID: groupID)
    try reload()
    return host
  }

  public func deleteHost(id: String) throws {
    try requiredRepository().deleteHost(id: id)
    try reload()
  }

  @discardableResult
  public func importInventory(
    workspaces: [ImportedWorkspaceDraft],
    groups: [ImportedGroupDraft],
    hosts: [ImportedHostDraft],
    conflictPolicy: ImportConflictPolicy
  ) throws -> ImportExecutionResult {
    let result = try requiredRepository().importInventory(
      workspaces: workspaces,
      groups: groups,
      hosts: hosts,
      conflictPolicy: conflictPolicy
    )
    try reload()
    return result
  }

  public var currentRepository: HostRepository? {
    repository
  }

  private func requiredRepository() throws -> HostRepository {
    guard let repository else { throw SQLiteRepositoryError.closed }
    return repository
  }
}
