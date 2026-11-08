import XCTest
import AppCore
@testable import MacRemoteWorkspace

final class SSHConnectionPresetTests: XCTestCase {
  func testMissingPresetUsesConfiguredDefaults() throws {
    let defaults = UserDefaults.standard
    let oldUsername = defaults.object(forKey: "defaultSSHUsername")
    let oldPort = defaults.object(forKey: "defaultSSHPort")
    defer {
      defaults.set(oldUsername, forKey: "defaultSSHUsername")
      defaults.set(oldPort, forKey: "defaultSSHPort")
    }
    defaults.set("example-user", forKey: "defaultSSHUsername")
    defaults.set(2222, forKey: "defaultSSHPort")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try SQLiteHostRepository(databaseURL: directory.appendingPathComponent("metadata.sqlite"))
    defer { try? repository.close() }
    let preset = try SSHConnectionPreset.load(hostID: UUID().uuidString, repository: repository)
    XCTAssertEqual(preset.username, "example-user")
    XCTAssertEqual(preset.port, 2222)
  }

  func testDirectConnectionRequiresAnAgentOrExplicitSavedCredential() {
    var preset = SSHConnectionPreset()
    preset.auth = .password
    XCTAssertFalse(preset.canConnectWithoutPrompt)
    preset.credentialID = "saved-password"
    XCTAssertFalse(preset.canConnectWithoutPrompt)
    preset.auth = .keychainCredential
    XCTAssertTrue(preset.canConnectWithoutPrompt)
    preset.credentialID = nil
    XCTAssertFalse(preset.canConnectWithoutPrompt)
    preset.auth = .sshAgent
    XCTAssertTrue(preset.canConnectWithoutPrompt)
  }
}
