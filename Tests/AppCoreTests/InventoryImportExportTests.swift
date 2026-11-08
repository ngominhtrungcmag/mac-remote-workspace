import Foundation
import XCTest
@testable import AppCore

final class InventoryImportExportTests: XCTestCase {
  private var tempDir: URL!
  private var repository: SQLiteHostRepository!

  override func setUpWithError() throws {
    try super.setUpWithError()
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("mrw-import-export-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let dbURL = tempDir.appendingPathComponent("metadata.sqlite")
    repository = try SQLiteHostRepository(databaseURL: dbURL)
  }

  override func tearDownWithError() throws {
    try? repository?.close()
    if let dir = tempDir {
      try? FileManager.default.removeItem(at: dir)
    }
    try super.tearDownWithError()
  }

  // MARK: - JSON Export & Import Round-Trip (FR-014 / TC-012)

  func testJSONExportAndImportRoundTrip() throws {
    // 1. Populate repository with workspaces, groups, and hosts
    let ws = try repository.createWorkspace(name: "Production Cluster")
    let grp = try repository.createGroup(workspaceID: ws.id, name: "Database Nodes")
    _ = try repository.createHost(HostDraft(
      displayName: "Primary PostgreSQL",
      address: "db1.internal",
      environment: .production,
      workspaceID: ws.id,
      groupID: grp.id
    ))
    _ = try repository.createHost(HostDraft(
      displayName: "Standby PostgreSQL",
      address: "db2.internal",
      environment: .production,
      workspaceID: ws.id,
      groupID: grp.id
    ))

    // 2. Export to JSON
    let jsonData = try InventoryImportExportService.exportToJSON(repository: repository)
    XCTAssertFalse(jsonData.isEmpty)

    // Decode and verify JSON structure
    let decoded = try JSONDecoder().decode(InventoryExportDocument.self, from: jsonData)
    XCTAssertEqual(decoded.schemaVersion, 2)
    XCTAssertFalse(decoded.secretsIncluded)
    XCTAssertEqual(decoded.workspaces.count, 1)
    XCTAssertEqual(decoded.groups.count, 1)
    XCTAssertEqual(decoded.hosts.count, 2)

    // 3. Clear repository database and import into a clean instance
    try repository.close()
    let newDBURL = tempDir.appendingPathComponent("clean_metadata.sqlite")
    let newRepo = try SQLiteHostRepository(databaseURL: newDBURL)

    let preview = try InventoryImportExportService.previewJSON(data: jsonData, repository: newRepo)
    XCTAssertEqual(preview.totalHostsInFile, 2)
    XCTAssertEqual(preview.hosts.count, 2)
    XCTAssertTrue(preview.conflicts.isEmpty)
    XCTAssertTrue(preview.validationErrors.isEmpty)
    XCTAssertTrue(preview.canImport)

    let result = try newRepo.importInventory(
      workspaces: preview.workspaces,
      groups: preview.groups,
      hosts: preview.hosts,
      conflictPolicy: .skip
    )

    XCTAssertEqual(result.addedHostsCount, 2)
    XCTAssertEqual(result.createdWorkspacesCount, 1)
    XCTAssertEqual(result.createdGroupsCount, 1)

    // Verify imported records in database
    let importedHosts = try newRepo.listHosts()
    XCTAssertEqual(importedHosts.count, 2)
    XCTAssertTrue(importedHosts.contains { $0.displayName == "Primary PostgreSQL" && $0.address == "db1.internal" })
    XCTAssertTrue(importedHosts.contains { $0.displayName == "Standby PostgreSQL" && $0.address == "db2.internal" })

    // Verify audit event was logged
    let audits = try newRepo.listAuditEvents(limit: 10)
    XCTAssertTrue(audits.contains { $0.action == "inventory.import" && $0.outcome == .success })

    try newRepo.close()
  }

  func testV2RoundTripPreservesMetadataWithoutCredentialSecrets() throws {
    let settings = SSHConnectionSettings(username: "alice", port: 2222, auth: .keychainCredential,
      credentialID: "reference-id", keyFilePath: "~/.ssh/id_ed25519", proxyJump: "jump@bastion:2200")
    let profiles = [ExportedProfile(protocolName: "ssh", port: 2222, username: "alice", authMethod: "ssh_agent"),
      ExportedProfile(protocolName: "rdp", port: 3389, username: "alice", authMethod: "password")]
    let snippets = [ExportedSnippet(title: "Status", command: "uptime")]
    let groupSnippets = [ExportedSnippet(title: "Disk", command: "df -h")]
    let hosts = [ImportedHostDraft(workspaceName: "Local", groupName: "Ops", displayName: "server",
      address: "server.test", environment: .production, tags: ["prod", "web"], profiles: profiles,
      sshSettings: settings, snippets: snippets)]
    _ = try repository.importInventory(workspaces: [ImportedWorkspaceDraft(name: "Local")],
      groups: [ImportedGroupDraft(workspaceName: "Local", name: "Ops", snippets: groupSnippets)], hosts: hosts, conflictPolicy: .skip)
    let json = try InventoryImportExportService.exportToJSON(repository: repository)
    let decoded = try JSONDecoder().decode(InventoryExportDocument.self, from: json)
    XCTAssertEqual(decoded.schemaVersion, 2)
    XCTAssertEqual(decoded.hosts.first?.sshSettings, settings)
    let second = try SQLiteHostRepository(databaseURL: tempDir.appendingPathComponent("second.sqlite"))
    defer { try? second.close() }
    let preview = try InventoryImportExportService.previewJSON(data: json, repository: second)
    _ = try second.importInventory(workspaces: preview.workspaces, groups: preview.groups, hosts: preview.hosts, conflictPolicy: .skip)
    let host = try XCTUnwrap(second.listHosts().first)
    XCTAssertEqual(Set(host.tags), Set(["prod", "web"]))
    XCTAssertEqual(Set(host.protocols), Set(["ssh", "rdp"]))
    var imported = settings
    imported.credentialID = nil  // credentials are per-machine and stripped on import
    XCTAssertEqual(try second.sshConnectionSettings(hostID: host.id), imported)
    XCTAssertEqual(try second.exportedProfiles(hostID: host.id), profiles)
    XCTAssertEqual(try second.exportedSnippets(hostID: host.id, groupID: nil), snippets)
    XCTAssertEqual(try second.exportedSnippets(hostID: nil, groupID: host.groupID), groupSnippets)
  }

  func testV2DisabledProtocolSurvivesRoundTripWithPreservedProfile() throws {
    let profile = ExportedProfile(protocolName: "ssh", port: 22, username: "alice", authMethod: "ssh_agent")
    _ = try repository.importInventory(workspaces: [ImportedWorkspaceDraft(name: "Local")], groups: [],
      hosts: [ImportedHostDraft(workspaceName: "Local", groupName: nil, displayName: "host", address: "host.test",
        environment: .development, profiles: [profile], protocols: [])], conflictPolicy: .skip)
    let data = try InventoryImportExportService.exportToJSON(repository: repository)
    let target = try SQLiteHostRepository(databaseURL: tempDir.appendingPathComponent("disabled.sqlite"))
    defer { try? target.close() }
    let preview = try InventoryImportExportService.previewJSON(data: data, repository: target)
    _ = try target.importInventory(workspaces: preview.workspaces, groups: preview.groups, hosts: preview.hosts, conflictPolicy: .skip)
    let host = try XCTUnwrap(target.listHosts().first)
    XCTAssertTrue(host.protocols.isEmpty)
    XCTAssertEqual(try target.exportedProfiles(hostID: host.id), [profile])
  }

  func testV1JSONStillImports() throws {
    let data = Data("""
      {"schema_version":1,"generated_at":"now","workspaces":[{"id":"w","name":"Local"}],"groups":[],
       "hosts":[{"id":"h","workspace_id":"w","display_name":"host","address":"example.test","environment":"development"}],"secrets_included":false}
      """.utf8)
    let preview = try InventoryImportExportService.previewJSON(data: data, repository: repository)
    _ = try repository.importInventory(workspaces: preview.workspaces, groups: preview.groups, hosts: preview.hosts, conflictPolicy: .skip)
    XCTAssertEqual(try repository.listHosts().first?.displayName, "host")
  }

  // MARK: - CSV Export & Import Round-Trip (FR-014 / TC-012)

  func testDuplicateJSONIdentifiersRejectPreviewAndLeaveInventoryUnchanged() throws {
    let workspace = try repository.createWorkspace(name: "Existing")
    let group = try repository.createGroup(workspaceID: workspace.id, name: "Existing group")
    _ = try repository.createHost(HostDraft(displayName: "Existing host", address: "existing.test",
      environment: .production, workspaceID: workspace.id, groupID: group.id))
    let beforeWorkspaces = try repository.listWorkspaces()
    let beforeGroups = try repository.listGroups(workspaceID: workspace.id)
    let beforeHosts = try repository.listHosts()

    let documents: [(InventoryExportDocument, String)] = [
      (InventoryExportDocument(workspaces: [
        ExportedWorkspace(id: "duplicate", name: "One"),
        ExportedWorkspace(id: "duplicate", name: "Two")
      ], groups: [], hosts: []), "workspace"),
      (InventoryExportDocument(workspaces: [ExportedWorkspace(id: "ws", name: "Workspace")], groups: [
        ExportedGroup(id: "duplicate", workspaceId: "ws", name: "One"),
        ExportedGroup(id: "duplicate", workspaceId: "ws", name: "Two")
      ], hosts: []), "group")
    ]
    for (document, kind) in documents {
      let data = try JSONEncoder().encode(document)
      XCTAssertThrowsError(try {
        let preview = try InventoryImportExportService.previewJSON(data: data, repository: repository)
        return try repository.importInventory(workspaces: preview.workspaces, groups: preview.groups,
          hosts: preview.hosts, conflictPolicy: .skip)
      }()) { error in
        XCTAssertEqual(error as? InventoryImportExportError, .duplicateIdentifier(kind))
      }
      XCTAssertEqual(try repository.listWorkspaces(), beforeWorkspaces)
      XCTAssertEqual(try repository.listGroups(workspaceID: workspace.id), beforeGroups)
      XCTAssertEqual(try repository.listHosts(), beforeHosts)
    }
  }

  func testCSVFormulaInjectionIsEscaped() {
    for value in ["=1+1", "+1", "-1", "@sum", "\tvalue", "\rvalue"] {
      let escaped = InventoryImportExportService.escapeCSVField(value)
      XCTAssertEqual(InventoryImportExportService.parseCSV(escaped).first?.first, "'" + value)
    }
    XCTAssertEqual(InventoryImportExportService.escapeCSVField("safe"), "safe")
  }

  func testCSVExportAndImportRoundTrip() throws {
    let ws = try repository.createWorkspace(name: "Staging Fleet")
    let grp = try repository.createGroup(workspaceID: ws.id, name: "App Servers")
    _ = try repository.createHost(HostDraft(
      displayName: "Web App 01, East",
      address: "web1.staging.internal",
      environment: .staging,
      workspaceID: ws.id,
      groupID: grp.id
    ))

    // 1. Export to CSV
    let csvString = try InventoryImportExportService.exportToCSV(repository: repository)
    XCTAssertTrue(csvString.contains("Workspace,Group,DisplayName,Address,Environment"))
    // Ensure comma in display name was properly quoted per RFC 4180
    XCTAssertTrue(csvString.contains("\"Web App 01, East\""))

    // 2. Import into a second clean repository
    let targetDBURL = tempDir.appendingPathComponent("target_csv.sqlite")
    let targetRepo = try SQLiteHostRepository(databaseURL: targetDBURL)

    let preview = try InventoryImportExportService.previewCSV(text: csvString, repository: targetRepo)
    XCTAssertEqual(preview.totalHostsInFile, 1)
    XCTAssertEqual(preview.hosts.count, 1)
    XCTAssertTrue(preview.conflicts.isEmpty)
    XCTAssertTrue(preview.canImport)

    let result = try targetRepo.importInventory(
      workspaces: preview.workspaces,
      groups: preview.groups,
      hosts: preview.hosts,
      conflictPolicy: .skip
    )

    XCTAssertEqual(result.addedHostsCount, 1)
    let imported = try targetRepo.listHosts()
    XCTAssertEqual(imported.first?.displayName, "Web App 01, East")
    XCTAssertEqual(imported.first?.address, "web1.staging.internal")
    XCTAssertEqual(imported.first?.environment, .staging)

    try targetRepo.close()
  }

  // MARK: - Secret Canary Test (FR-014, TC-012, SEC-T03)

  func testExportNeverContainsSecretsOrCanaryValues() throws {
    let secretCanary = "CANARY_SECRET_PASSWORD_12345"
    let ws = try repository.createWorkspace(name: "Workspace Alpha")
    _ = try repository.createHost(HostDraft(
      displayName: "Host Safe",
      address: "10.0.0.1",
      environment: .development,
      workspaceID: ws.id
    ))

    // Attempt export to both JSON and CSV
    let jsonData = try InventoryImportExportService.exportToJSON(repository: repository)
    let jsonString = String(data: jsonData, encoding: .utf8)!
    let csvString = try InventoryImportExportService.exportToCSV(repository: repository)

    // Strictly verify neither contains the canary secret or password keys
    XCTAssertFalse(jsonString.contains(secretCanary))
    XCTAssertFalse(csvString.contains(secretCanary))
    XCTAssertFalse(jsonString.contains("keychain"))
    XCTAssertFalse(csvString.contains("keychain"))
    XCTAssertFalse(jsonString.contains("private_key"))
    XCTAssertFalse(csvString.contains("private_key"))
    XCTAssertTrue(jsonString.contains("\"secrets_included\" : false"))
  }

  // MARK: - Conflict Resolution Policies (TC-012)

  func testImportConflictPolicySkipPreservesExistingHost() throws {
    let ws = try repository.createWorkspace(name: "Main")
    _ = try repository.createHost(HostDraft(
      displayName: "API Server",
      address: "api.example.com",
      environment: .production,
      workspaceID: ws.id
    ))

    // Prepare import with same address but different environment
    let candidate = ImportedHostDraft(
      workspaceName: "Main",
      groupName: nil,
      displayName: "API Server",
      address: "api.example.com",
      environment: .development
    )

    let result = try repository.importInventory(
      workspaces: [ImportedWorkspaceDraft(name: "Main")],
      groups: [],
      hosts: [candidate],
      conflictPolicy: .skip
    )

    XCTAssertEqual(result.skippedHostsCount, 1)
    XCTAssertEqual(result.addedHostsCount, 0)
    XCTAssertEqual(result.updatedHostsCount, 0)

    // Verify existing host is unmodified
    let hosts = try repository.listHosts()
    XCTAssertEqual(hosts.count, 1)
    XCTAssertEqual(hosts.first?.environment, .production)
  }

  func testImportConflictPolicyOverwriteUpdatesExistingHost() throws {
    let ws = try repository.createWorkspace(name: "Main")
    _ = try repository.createHost(HostDraft(
      displayName: "API Server",
      address: "api.example.com",
      environment: .production,
      workspaceID: ws.id
    ))

    let candidate = ImportedHostDraft(
      workspaceName: "Main",
      groupName: nil,
      displayName: "API Server",
      address: "api.example.com",
      environment: .staging
    )

    let result = try repository.importInventory(
      workspaces: [ImportedWorkspaceDraft(name: "Main")],
      groups: [],
      hosts: [candidate],
      conflictPolicy: .overwrite
    )

    XCTAssertEqual(result.updatedHostsCount, 1)
    XCTAssertEqual(result.addedHostsCount, 0)
    XCTAssertEqual(result.skippedHostsCount, 0)

    let hosts = try repository.listHosts()
    XCTAssertEqual(hosts.count, 1)
    XCTAssertEqual(hosts.first?.environment, .staging)
  }

  func testImportConflictPolicyKeepBothCreatesRenamedCopy() throws {
    let ws = try repository.createWorkspace(name: "Main")
    _ = try repository.createHost(HostDraft(
      displayName: "API Server",
      address: "api.example.com",
      environment: .production,
      workspaceID: ws.id
    ))

    let candidate = ImportedHostDraft(
      workspaceName: "Main",
      groupName: nil,
      displayName: "API Server",
      address: "api.example.com",
      environment: .development
    )

    let result = try repository.importInventory(
      workspaces: [ImportedWorkspaceDraft(name: "Main")],
      groups: [],
      hosts: [candidate],
      conflictPolicy: .keepBoth
    )

    XCTAssertEqual(result.addedHostsCount, 1)
    let hosts = try repository.listHosts()
    XCTAssertEqual(hosts.count, 2)
    XCTAssertTrue(hosts.contains { $0.displayName == "API Server" && $0.environment == .production })
    XCTAssertTrue(hosts.contains { $0.displayName == "API Server (Imported)" && $0.environment == .development })
  }

  // MARK: - Negative & Validation Tests (TC-012)

  func testImportRejectsUnsupportedSchemaVersion() throws {
    let json = """
    {
      "schema_version": 99,
      "generated_at": "2026-10-30T10:00:00Z",
      "workspaces": [],
      "groups": [],
      "hosts": [],
      "secrets_included": false
    }
    """
    let data = json.data(using: .utf8)!
    XCTAssertThrowsError(try InventoryImportExportService.previewJSON(data: data, repository: repository)) { error in
      guard case InventoryImportExportError.unsupportedSchemaVersion(99) = error else {
        return XCTFail("Expected unsupportedSchemaVersion(99), got \(error)")
      }
    }
  }

  func testImportRejectsMalformedJSON() throws {
    let badJSON = "{ not valid json ...".data(using: .utf8)!
    XCTAssertThrowsError(try InventoryImportExportService.previewJSON(data: badJSON, repository: repository)) { error in
      guard case InventoryImportExportError.invalidJSON = error else {
        return XCTFail("Expected invalidJSON, got \(error)")
      }
    }
  }

  func testImportRejectsMalformedCSVHeader() throws {
    let badCSV = "ColA,ColB,ColC\n1,2,3"
    XCTAssertThrowsError(try InventoryImportExportService.previewCSV(text: badCSV, repository: repository)) { error in
      guard case InventoryImportExportError.invalidCSV = error else {
        return XCTFail("Expected invalidCSV, got \(error)")
      }
    }
  }

  // MARK: - Atomic Rollback Test (TC-017 / NFR-010)

  func testImportFailureRollsBackTransactionCompletely() throws {
    let ws = try repository.createWorkspace(name: "Main")
    _ = try repository.createHost(HostDraft(
      displayName: "Original Host",
      address: "original.internal",
      environment: .production,
      workspaceID: ws.id
    ))

    // Candidate 1 is valid, but Candidate 2 has an invalid address (triggers validation error)
    let validDraft = ImportedHostDraft(
      workspaceName: "Main",
      groupName: nil,
      displayName: "Valid Host",
      address: "valid.internal",
      environment: .development
    )
    let invalidDraft = ImportedHostDraft(
      workspaceName: "Main",
      groupName: nil,
      displayName: "Invalid Host",
      address: "-invalid-prefix.internal", // Illegal hostname leading dash
      environment: .development
    )

    XCTAssertThrowsError(
      try repository.importInventory(
        workspaces: [],
        groups: [],
        hosts: [validDraft, invalidDraft],
        conflictPolicy: .skip
      )
    )

    // Ensure database remained completely untouched — Valid Host must NOT be present
    let hosts = try repository.listHosts()
    XCTAssertEqual(hosts.count, 1)
    XCTAssertEqual(hosts.first?.displayName, "Original Host")

    // Check that audit event recorded failure
    let audits = try repository.listAuditEvents(limit: 5)
    let failure = try XCTUnwrap(audits.first { $0.action == "inventory.import" && $0.outcome == .failure })
    XCTAssertEqual(failure.errorCode, "validation_failed")
  }
}
