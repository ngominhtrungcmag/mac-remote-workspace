import Foundation
import XCTest
@testable import AppCore

final class SSHConfigDataSourceTests: XCTestCase {
  private var tempDir: URL!
  private var repository: SQLiteHostRepository!

  override func setUpWithError() throws {
    tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mrw-sshcfg-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    repository = try SQLiteHostRepository(databaseURL: tempDir.appendingPathComponent("m.sqlite"))
  }

  override func tearDownWithError() throws {
    try? repository.close()
    try? FileManager.default.removeItem(at: tempDir)
  }

  func testParsesHostsSkipsWildcardsAndDetectsConflicts() throws {
    let ws = try repository.createWorkspace(name: "Local")
    _ = try repository.createHost(HostDraft(
      displayName: "old", address: "web.example.com", environment: .development,
      workspaceID: ws.id, groupID: nil))
    let p = try InventoryImportExportService.previewSSHConfig(text: """
      Host *
        User root
      Host web db
        HostName web.example.com
      Host bare
      Host staging
        HostName = 10.0.0.5
      """, repository: repository)
    XCTAssertEqual(p.hosts.map(\.displayName), ["web", "db", "bare", "staging"])
    XCTAssertEqual(p.hosts.last?.address, "10.0.0.5")
    XCTAssertEqual(p.hosts[2].address, "bare")
    XCTAssertFalse(p.conflicts.contains { $0.address == "web.example.com" })
    XCTAssertTrue(p.canImport)
  }

  func testSecretsAndCommandsNeverImported() throws {
    let canary = "CANARY-SECRET-9f3a"
    let p = try InventoryImportExportService.previewSSHConfig(text: """
      Host prod
        HostName prod.example.com
        IdentityFile ~/.ssh/id_ed25519
        Password \(canary)
        ProxyCommand sh -c 'echo \(canary)'
      Include /etc/\(canary)
      """, repository: repository)
    XCTAssertEqual(p.hosts.count, 1)
    XCTAssertEqual(p.hosts[0].address, "prod.example.com")
    XCTAssertFalse("\(p)".contains(canary))
  }

  func testIncludesGlobsCyclesAndReimportsByAlias() throws {
    let ssh = tempDir.appendingPathComponent("ssh")
    try FileManager.default.createDirectory(at: ssh.appendingPathComponent("conf.d"), withIntermediateDirectories: true)
    let config = ssh.appendingPathComponent("config")
    try "Include conf.d/*.conf\nHost first\n HostName same.example\n User alice\n Port 2201\n IdentityFile ~/.ssh/id_ed25519\n ProxyJump jump@bastion:2222\n".write(to: config, atomically: true, encoding: .utf8)
    try "Include config\nHost second\n HostName same.example\n User bob\n".write(to: ssh.appendingPathComponent("conf.d/a.conf"), atomically: true, encoding: .utf8)
    let preview = try InventoryImportExportService.previewSSHConfig(fileURL: config, sshDirectory: ssh, repository: repository)
    XCTAssertEqual(Set(preview.hosts.map(\.displayName)), Set(["first", "second"]))
    let first = try XCTUnwrap(preview.hosts.first { $0.displayName == "first" })
    XCTAssertEqual(first.sshSettings?.username, "alice")
    XCTAssertEqual(first.sshSettings?.port, 2201)
    XCTAssertEqual(first.sshSettings?.keyFilePath, "~/.ssh/id_ed25519")
    XCTAssertEqual(first.sshSettings?.proxyJump, "jump@bastion:2222")
    _ = try repository.importInventory(workspaces: preview.workspaces, groups: preview.groups, hosts: preview.hosts, conflictPolicy: .overwrite)
    XCTAssertEqual(try repository.listHosts().count, 2)
    let next = try InventoryImportExportService.previewSSHConfig(fileURL: config, sshDirectory: ssh, repository: repository)
    _ = try repository.importInventory(workspaces: next.workspaces, groups: next.groups, hosts: next.hosts, conflictPolicy: .overwrite)
    XCTAssertEqual(try repository.listHosts().count, 2)
    let host = try XCTUnwrap(repository.listHosts().first { $0.displayName == "first" })
    XCTAssertEqual(try repository.sshConnectionSettings(hostID: host.id), first.sshSettings)
  }

  func testMalformedInput() throws {
    XCTAssertThrowsError(try InventoryImportExportService.previewSSHConfig(text: "", repository: repository))
    XCTAssertThrowsError(try InventoryImportExportService.previewSSHConfig(text: "garbage\n#x", repository: repository))
    XCTAssertThrowsError(try InventoryImportExportService.previewSSHConfig(text: "Host a\0b", repository: repository))
    XCTAssertThrowsError(try InventoryImportExportService.previewSSHConfig(
      text: String(repeating: "#", count: 2_000_000), repository: repository))
    let p = try InventoryImportExportService.previewSSHConfig(
      text: "Host evil\n HostName -oProxyCommand=x\nHost ok", repository: repository)
    XCTAssertFalse(p.canImport)
    XCTAssertEqual(p.hosts.map(\.displayName), ["ok"])
  }
}
