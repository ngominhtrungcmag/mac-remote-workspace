import Foundation

/// Non-secret connection settings; credentials are referenced only by their inventory ID.
public struct SSHConnectionSettings: Codable, Equatable, Sendable {
  public enum Auth: String, Codable, CaseIterable, Sendable { case password, keychainCredential, sshAgent }

  public var username: String
  public var port: Int
  public var auth: Auth
  public var credentialID: String?
  public var keyFilePath: String
  public var proxyJump: String?

  public init(username: String, port: Int, auth: Auth = .password, credentialID: String? = nil, keyFilePath: String = "", proxyJump: String? = nil) {
    self.username = username
    self.port = port
    self.auth = auth
    self.credentialID = credentialID
    self.keyFilePath = keyFilePath
    self.proxyJump = proxyJump
  }
}


extension SSHConnectionSettings {
  /// Validate the supported single-hop OpenSSH [user@]host[:port] form.
  public static func validateProxyJump(_ value: String) throws {
    let userAndHost = value.split(separator: "@", omittingEmptySubsequences: false)
    guard (1...2).contains(userAndHost.count) else { throw NativeSSHError.invalidHost(value) }
    let user = userAndHost.count == 2 ? String(userAndHost[0]) : "placeholder"
    let endpoint = String(userAndHost.last!)
    let host: String
    let port: Int
    if endpoint.hasPrefix("[") {
      guard let close = endpoint.firstIndex(of: "]") else { throw NativeSSHError.invalidHost(value) }
      host = String(endpoint[endpoint.index(after: endpoint.startIndex)..<close])
      let suffix = endpoint[endpoint.index(after: close)...]
      if suffix.isEmpty { port = 22 }
      else if suffix.first == ":", let parsed = Int(suffix.dropFirst()) { port = parsed }
      else { throw NativeSSHError.invalidHost(value) }
    } else {
      let parts = endpoint.split(separator: ":", omittingEmptySubsequences: false)
      guard (1...2).contains(parts.count), let parsed = parts.count == 2 ? Int(parts[1]) : 22 else {
        throw NativeSSHError.invalidHost(value)
      }
      host = String(parts[0]); port = parsed
    }
    try NativeSSHSession.validateProxyJump(NativeSSHProxyJumpEndpoint(host: host, port: port, username: user))
  }
}
