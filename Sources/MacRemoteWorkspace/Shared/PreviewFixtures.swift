#if DEBUG
import AppCore
import Foundation

@MainActor
enum PreviewFixtures {
  static func repository() throws -> SQLiteHostRepository {
    try SQLiteHostRepository(databaseURL: FileManager.default.temporaryDirectory
      .appendingPathComponent("preview-\(UUID())/metadata.sqlite"))
  }

  static func store() throws -> WorkspaceStore {
    let store = WorkspaceStore(repository: try repository())
    let workspace = try store.createWorkspace(name: "Example")
    let group = try store.createGroup(workspaceID: workspace.id, name: "Servers")
    try store.createHost(HostDraft(displayName: "Production", address: "prod.example.test",
      environment: .production, workspaceID: workspace.id, groupID: group.id, tags: ["web"], protocols: ["ssh"]))
    try store.createHost(HostDraft(displayName: "Development", address: "dev.example.test",
      environment: .development, workspaceID: workspace.id, groupID: group.id, protocols: ["ssh"]))
    return store
  }

  static let host = HostRecord(id: "preview-host", workspaceID: "preview-workspace", displayName: "Production",
    address: "prod.example.test", environment: .production, version: 1, tags: ["web"], protocols: ["ssh"])
  static let hostKey = SSHHostKeyRecord(rawLine: "example.test ssh-ed25519 AAAA", keyType: "ssh-ed25519",
    keyBase64: "AAAA", algorithm: "ED25519", fingerprintSHA256: "SHA256:example")
  static let credential = CredentialRefRecord(id: "preview-credential", label: "Example", kind: .password, keychainItemID: "preview")
}
#endif
