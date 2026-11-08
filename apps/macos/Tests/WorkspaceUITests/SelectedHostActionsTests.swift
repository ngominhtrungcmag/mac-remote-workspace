import AppCore
import XCTest
@testable import MacRemoteWorkspace

final class SelectedHostActionsTests: XCTestCase {
  func testProtocolSupportIsCaseInsensitiveAndDoesNotInferUnsupportedProtocols() {
    let host = HostRecord(id: "1", workspaceID: "w", displayName: "Host", address: "example.com", environment: .development, version: 1, protocols: ["SSH"])
    let actions = SelectedHostActions(host: host, connect: {}, sftp: {}, rdp: {}, edit: {}, delete: {})
    XCTAssertTrue(actions.supports("ssh"))
    XCTAssertFalse(actions.supports("rdp"))
  }
}

extension SelectedHostActionsTests {
  func testDefaultProtocolFollowsSettingAndFallsBack() {
    let host = HostRecord(id: "2", workspaceID: "w", displayName: "Host", address: "example.com", environment: .development, version: 1, protocols: ["other", "RDP", "ssh"])
    XCTAssertEqual(host.defaultConnectionProtocol, "ssh")
    XCTAssertTrue(host.supportsProtocol("SSH"))
    UserDefaults.standard.set("rdp", forKey: HostRecord.preferredProtocolKey)
    defer { UserDefaults.standard.removeObject(forKey: HostRecord.preferredProtocolKey) }
    XCTAssertEqual(host.defaultConnectionProtocol, "rdp")
    let sshOnly = HostRecord(id: "4", workspaceID: "w", displayName: "Linux", address: "l.example.com", environment: .development, version: 1, protocols: ["ssh"])
    XCTAssertEqual(sshOnly.defaultConnectionProtocol, "ssh")
    let rdpOnly = HostRecord(id: "3", workspaceID: "w", displayName: "Win", address: "win.example.com", environment: .development, version: 1, protocols: ["other", "RDP"])
    XCTAssertEqual(rdpOnly.defaultConnectionProtocol, "rdp")
  }
}
