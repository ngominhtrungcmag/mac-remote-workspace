import AppCore
import Foundation

/// UI-facing name for non-secret per-host SSH settings.
typealias SSHConnectionPreset = SSHConnectionSettings

extension SSHConnectionSettings {
  init() {
    self.init(
      username: UserDefaults.standard.string(forKey: "defaultSSHUsername") ?? "",
      port: UserDefaults.standard.object(forKey: "defaultSSHPort") as? Int ?? 22)
  }

  var canConnectWithoutPrompt: Bool {
    switch auth {
    case .password: false
    case .keychainCredential: credentialID != nil
    case .sshAgent: true
    }
  }

  static func load(hostID: String) -> Self? {
    guard let repository = try? SQLiteHostRepository.openApplicationRepository() else { return nil }
    defer { try? repository.close() }
    return try? load(hostID: hostID, repository: repository)
  }

  static func load(hostID: String, repository: SQLiteHostRepository) throws -> Self {
    try repository.sshConnectionSettings(hostID: hostID) ?? Self()
  }

  func save(hostID: String) {
    try? saveThrowing(hostID: hostID)
  }

  func saveThrowing(hostID: String) throws {
    let repository = try SQLiteHostRepository.openApplicationRepository()
    defer { try? repository.close() }
    try repository.upsertSSHConnectionSettings(hostID: hostID, settings: self)
  }
}
