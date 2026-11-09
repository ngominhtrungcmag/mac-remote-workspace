import AppCore
import Foundation

/// Local nonsecret preferences only; host IDs are opaque inventory identifiers.
struct RdpConnectionPreferences {
  let defaults: UserDefaults
  static let globalKey = "rdpConnectionOptions.v1"
  static func hostKey(_ hostID: String) -> String { "rdpConnectionOptions.v1.host.\(hostID)" }

  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  var globalOptions: RdpConnectionOptions {
    load(Self.globalKey) ?? RdpConnectionOptions()
  }

  func override(hostID: String) -> RdpConnectionOptions? { load(Self.hostKey(hostID)) }

  func resolved(hostID: String) -> RdpConnectionOptions { override(hostID: hostID) ?? globalOptions }

  func saveGlobal(_ options: RdpConnectionOptions) throws {
    defaults.set(try JSONEncoder().encode(options), forKey: Self.globalKey)
  }

  func saveOverride(_ options: RdpConnectionOptions?, hostID: String) throws {
    let key = Self.hostKey(hostID)
    if let options {
      defaults.set(try JSONEncoder().encode(options), forKey: key)
    } else {
      defaults.removeObject(forKey: key)
    }
  }

  private func load(_ key: String) -> RdpConnectionOptions? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(RdpConnectionOptions.self, from: data)
  }
}
