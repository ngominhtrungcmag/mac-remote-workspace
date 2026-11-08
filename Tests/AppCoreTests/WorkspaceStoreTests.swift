import XCTest

@testable import AppCore

@MainActor
final class WorkspaceStoreTests: XCTestCase {
  func testStoreTracksWorkspaceGroupHostAndMoveOperations() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("mrw-workspace-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try SQLiteHostRepository(databaseURL: directory.appendingPathComponent("metadata.sqlite"))
    defer { try? repository.close() }
    let store = WorkspaceStore(repository: repository)

    let first = try store.createWorkspace(name: "Build")
    let group = try store.createGroup(workspaceID: first.id, name: "CI")
    let host = try store.createHost(HostDraft(
      displayName: "Runner", address: "runner.example", environment: .staging,
      workspaceID: first.id, groupID: group.id
    ))
    XCTAssertEqual(store.workspaces, [first])
    XCTAssertEqual(store.groups, [group])
    XCTAssertEqual(store.hosts, [host])

    let second = try store.createWorkspace(name: "Operations")
    let moved = try store.moveHost(
      id: host.id, expectedVersion: host.version, toWorkspaceID: second.id, groupID: nil)
    XCTAssertEqual(store.hosts, [moved])
    XCTAssertEqual(store.hosts.first?.workspaceID, second.id)
    XCTAssertNil(store.hosts.first?.groupID)

    try store.deleteGroup(id: group.id, expectedVersion: group.version)
    XCTAssertTrue(store.groups.isEmpty)
    try store.deleteHost(id: host.id)
    XCTAssertTrue(store.hosts.isEmpty)
    try store.deleteWorkspace(id: first.id, expectedVersion: first.version)
    XCTAssertEqual(store.workspaces, [second])
    XCTAssertNil(store.storageError)
  }
}
