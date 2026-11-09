import Foundation

/// Connection protocol selected or parsed for a temporary Quick Connect session.
public enum QuickConnectProtocol: String, CaseIterable, Identifiable, Sendable, Equatable {
  case ssh
  case rdp

  public var id: Self { self }

  public var defaultPort: Int {
    switch self {
    case .ssh: 22
    case .rdp: Int(RdpLauncher.defaultPort)
    }
  }
}

/// Validation errors raised when parsing a Quick Connect target string.
/// Error cases intentionally avoid echoing raw user input so credentials or URLs
/// accidentally pasted into the target field are never surfaced in logs or error strings.
public enum QuickConnectValidationError: Error, Equatable, Sendable, AppCoreLocalizedError {
  case emptyInput
  case inputTooLong
  case containsControlCharacters
  case missingProtocol
  case unsupportedProtocol
  case passwordInTargetNotAllowed
  case queryOrFragmentNotAllowed
  case pathOrCommandNotAllowed
  case invalidSyntax
  case invalidUsername
  case usernameNotSupportedForRDP
  case invalidHost
  case invalidPort

  public func displayDescription(locale: Locale?) -> String? {
    switch self {
    case .emptyInput:
      AppCoreLocalization.string("Enter a host address or connection URL.", locale: locale)
    case .inputTooLong:
      AppCoreLocalization.string("The connection target is too long.", locale: locale)
    case .containsControlCharacters:
      AppCoreLocalization.string("The connection target cannot contain control characters or whitespace.", locale: locale)
    case .missingProtocol:
      AppCoreLocalization.string("Choose SSH or RDP, or enter an ssh:// or rdp:// URL.", locale: locale)
    case .unsupportedProtocol:
      AppCoreLocalization.string("Only ssh:// and rdp:// URLs are supported.", locale: locale)
    case .passwordInTargetNotAllowed:
      AppCoreLocalization.string("Do not include a password in the connection URL.", locale: locale)
    case .queryOrFragmentNotAllowed:
      AppCoreLocalization.string("Connection URLs cannot include query parameters or fragments.", locale: locale)
    case .pathOrCommandNotAllowed:
      AppCoreLocalization.string("Connection targets cannot include paths, commands, or options.", locale: locale)
    case .invalidSyntax:
      AppCoreLocalization.string("Enter a valid target such as ssh://user@host:22 or rdp://host:3389.", locale: locale)
    case .invalidUsername:
      AppCoreLocalization.string("Enter a valid SSH username without leading '-' or special characters.", locale: locale)
    case .usernameNotSupportedForRDP:
      AppCoreLocalization.string("Do not include a username in an rdp:// URL; enter credentials in the RDP connection step.", locale: locale)
    case .invalidHost:
      AppCoreLocalization.string("Enter a valid DNS hostname, IPv4 address, or bracketed IPv6 address.", locale: locale)
    case .invalidPort:
      AppCoreLocalization.string("Port must be between 1 and 65535.", locale: locale)
    }
  }
}

/// Validated, in-memory connection target for Quick Connect (G1, S1-01).
/// Never persists to SQLite inventory or constructs shell command strings.
public struct QuickConnectTarget: Equatable, Sendable {
  public static let maxInputUTF8Bytes = 512
  public static let maxUsernameUTF8Bytes = 128

  public let connectionProtocol: QuickConnectProtocol
  /// Normalized host (IPv6 addresses are stored without enclosing brackets, matching `HostRecord.address` and `RdpLauncher.validateAddress`).
  public let host: String
  public let port: Int
  public let username: String?

  public init(
    connectionProtocol: QuickConnectProtocol,
    host: String,
    port: Int? = nil,
    username: String? = nil
  ) throws {
    let resolvedPort = port ?? connectionProtocol.defaultPort
    let normalizedHost = try Self.validateHostAndPort(host: host, port: resolvedPort)
    let normalizedUsername: String?
    if let username {
      guard connectionProtocol == .ssh else {
        throw QuickConnectValidationError.usernameNotSupportedForRDP
      }
      normalizedUsername = try Self.validateSSHUsername(username)
    } else {
      normalizedUsername = nil
    }

    self.connectionProtocol = connectionProtocol
    self.host = normalizedHost
    self.port = resolvedPort
    self.username = normalizedUsername
  }

  /// Host formatted with brackets if it is an IPv6 literal, suitable for URI/endpoint display.
  public var bracketedHost: String {
    host.contains(":") ? "[\(host)]" : host
  }

  /// Canonical `host:port` or `[ipv6]:port` endpoint string.
  public var endpointString: String {
    "\(bracketedHost):\(port)"
  }

  /// Canonical connection URI without credentials (except optional SSH username).
  public var canonicalURIString: String {
    switch connectionProtocol {
    case .ssh:
      if let username {
        return "ssh://\(username)@\(bracketedHost):\(port)"
      }
      return "ssh://\(bracketedHost):\(port)"
    case .rdp:
      return "rdp://\(bracketedHost):\(port)"
    }
  }

  /// Parses a Quick Connect input string into a validated `QuickConnectTarget`.
  ///
  /// Supported forms:
  /// - `ssh://[user@]host[:port]` (where `host` is a hostname, IPv4, or `[IPv6]`)
  /// - `rdp://host[:port]` (where `host` is a hostname, IPv4, or `[IPv6]`)
  /// - Plain `[user@]host[:port]` for SSH or `host[:port]` for RDP ONLY when `explicitProtocol` is provided.
  public static func parse(
    _ rawInput: String,
    explicitProtocol: QuickConnectProtocol? = nil
  ) throws -> QuickConnectTarget {
    // Reject any control characters (including \0, \r, \n, \t) anywhere in raw input before trimming.
    if rawInput.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
      throw QuickConnectValidationError.containsControlCharacters
    }

    let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw QuickConnectValidationError.emptyInput
    }
    guard trimmed.utf8.count <= maxInputUTF8Bytes else {
      throw QuickConnectValidationError.inputTooLong
    }

    // Reject internal whitespace or newlines after trimming outer spaces.
    if trimmed.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains) {
      throw QuickConnectValidationError.containsControlCharacters
    }

    // Reject percent-encoding to prevent encoded control characters, credentials, or delimiter confusion.
    if trimmed.contains("%") {
      throw QuickConnectValidationError.invalidSyntax
    }

    // Reject query strings and fragments before any other splitting.
    if trimmed.contains("?") || trimmed.contains("#") || trimmed.contains("&") || trimmed.contains("=") {
      throw QuickConnectValidationError.queryOrFragmentNotAllowed
    }

    let resolvedProtocol: QuickConnectProtocol
    let authority: Substring

    if let schemeSeparatorRange = trimmed.range(of: "://") {
      let scheme = trimmed[..<schemeSeparatorRange.lowerBound].lowercased()
      switch scheme {
      case "ssh":
        resolvedProtocol = .ssh
      case "rdp":
        resolvedProtocol = .rdp
      default:
        throw QuickConnectValidationError.unsupportedProtocol
      }
      authority = trimmed[schemeSeparatorRange.upperBound...]
    } else if trimmed.contains(":/") || trimmed.contains("\\") {
      throw QuickConnectValidationError.invalidSyntax
    } else {
      guard let explicitProtocol else {
        throw QuickConnectValidationError.missingProtocol
      }
      resolvedProtocol = explicitProtocol
      authority = Substring(trimmed)
    }

    guard !authority.isEmpty else {
      throw QuickConnectValidationError.invalidSyntax
    }

    // Reject any path segments, trailing slashes, backslashes, or shell/command delimiters.
    let pathOrCommandCharacters = CharacterSet(charactersIn: "/\\;'\"`$|<>(){}")
    if authority.unicodeScalars.contains(where: pathOrCommandCharacters.contains) {
      throw QuickConnectValidationError.pathOrCommandNotAllowed
    }

    // Split optional userinfo@hostport
    let userParts = authority.split(separator: "@", omittingEmptySubsequences: false)
    guard (1...2).contains(userParts.count) else {
      throw QuickConnectValidationError.invalidSyntax
    }

    let rawUser: String?
    let hostPortPart: Substring
    if userParts.count == 2 {
      let userCandidate = String(userParts[0])
      // Reject `user:password@...` or empty password `user:@...` or `:pass@...`
      if userCandidate.contains(":") {
        throw QuickConnectValidationError.passwordInTargetNotAllowed
      }
      guard !userCandidate.isEmpty else {
        throw QuickConnectValidationError.invalidUsername
      }
      guard resolvedProtocol == .ssh else {
        throw QuickConnectValidationError.usernameNotSupportedForRDP
      }
      rawUser = userCandidate
      hostPortPart = userParts[1]
    } else {
      rawUser = nil
      hostPortPart = userParts[0]
    }

    guard !hostPortPart.isEmpty else {
      throw QuickConnectValidationError.invalidHost
    }

    let (parsedHost, parsedPort) = try parseHostAndPort(hostPortPart, defaultPort: resolvedProtocol.defaultPort)
    return try QuickConnectTarget(
      connectionProtocol: resolvedProtocol,
      host: parsedHost,
      port: parsedPort,
      username: rawUser
    )
  }

  // MARK: - Private Helpers

  private static func parseHostAndPort(
    _ hostPort: Substring,
    defaultPort: Int
  ) throws -> (host: String, port: Int) {
    if hostPort.hasPrefix("[") {
      guard let closingBracket = hostPort.firstIndex(of: "]") else {
        throw QuickConnectValidationError.invalidHost
      }
      let innerHost = String(hostPort[hostPort.index(after: hostPort.startIndex)..<closingBracket])
      guard !innerHost.isEmpty, !innerHost.contains("["), !innerHost.contains("]") else {
        throw QuickConnectValidationError.invalidHost
      }
      let remainder = hostPort[hostPort.index(after: closingBracket)...]
      if remainder.isEmpty {
        return ("[\(innerHost)]", defaultPort)
      }
      guard remainder.first == ":" else {
        throw QuickConnectValidationError.invalidSyntax
      }
      let portSlice = remainder.dropFirst()
      let port = try parseStrictPort(portSlice)
      return ("[\(innerHost)]", port)
    } else {
      if hostPort.contains("[") || hostPort.contains("]") {
        throw QuickConnectValidationError.invalidHost
      }
      let colonParts = hostPort.split(separator: ":", omittingEmptySubsequences: false)
      if colonParts.count == 1 {
        let hostCandidate = String(colonParts[0])
        return (hostCandidate, defaultPort)
      } else if colonParts.count == 2 {
        let hostCandidate = String(colonParts[0])
        guard !hostCandidate.isEmpty else {
          throw QuickConnectValidationError.invalidHost
        }
        let port = try parseStrictPort(colonParts[1])
        return (hostCandidate, port)
      } else {
        // Multiple colons without brackets (e.g. unbracketed IPv6 literal) -> reject as invalidHost
        throw QuickConnectValidationError.invalidHost
      }
    }
  }

  private static func parseStrictPort(_ slice: Substring) throws -> Int {
    guard !slice.isEmpty, slice.count <= 5,
          slice.unicodeScalars.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }),
          let port = Int(slice),
          (1...65535).contains(port) else {
      throw QuickConnectValidationError.invalidPort
    }
    return port
  }

  private static func validateHostAndPort(host: String, port: Int) throws -> String {
    guard (1...65535).contains(port) else {
      throw QuickConnectValidationError.invalidPort
    }

    if host.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      || host.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains) {
      throw QuickConnectValidationError.containsControlCharacters
    }

    // Reject option injection or path/command injection in host before delegating
    let pathOrCommandCharacters = CharacterSet(charactersIn: "/\\;'\"`$|<>(){}")
    if host.hasPrefix("-") || host.unicodeScalars.contains(where: pathOrCommandCharacters.contains) {
      throw QuickConnectValidationError.pathOrCommandNotAllowed
    }
    if host.contains("?") || host.contains("#") || host.contains("&") || host.contains("=") {
      throw QuickConnectValidationError.queryOrFragmentNotAllowed
    }

    // Require IPv6 literals to be bracketed (e.g., "[::1]"), rejecting bare unbracketed IPv6 strings.
    if host.contains(":") && !(host.hasPrefix("[") && host.hasSuffix("]")) {
      throw QuickConnectValidationError.invalidHost
    }

    // Reuse RdpLauncher.validateAddress which validates RFC 1123 DNS hostnames,
    // strict IPv4 via inet_pton(AF_INET), and IPv6 via inet_pton(AF_INET6), returning unbracketed host.
    let normalized: String
    do {
      normalized = try RdpLauncher.validateAddress(host)
    } catch {
      throw QuickConnectValidationError.invalidHost
    }

    // Also verify with NativeSSHHostTrustService.validateEndpoint so SSH and RDP rules stay aligned.
    do {
      let sshHostFormat = normalized.contains(":") ? "[\(normalized)]" : normalized
      try NativeSSHHostTrustService.validateEndpoint(host: sshHostFormat, port: port)
    } catch SSHHostTrustError.invalidPort {
      throw QuickConnectValidationError.invalidPort
    } catch {
      throw QuickConnectValidationError.invalidHost
    }

    return normalized
  }

  private static func validateSSHUsername(_ username: String) throws -> String {
    guard !username.isEmpty,
          username.utf8.count <= maxUsernameUTF8Bytes,
          username == username.trimmingCharacters(in: .whitespacesAndNewlines) else {
      throw QuickConnectValidationError.invalidUsername
    }
    if username.hasPrefix("-") {
      throw QuickConnectValidationError.invalidUsername
    }
    if username.contains(":") {
      throw QuickConnectValidationError.passwordInTargetNotAllowed
    }
    // Reuse existing SSHConnectionSettings.validateProxyJump username validation rules
    do {
      try SSHConnectionSettings.validateProxyJump("\(username)@example.com:22")
    } catch {
      throw QuickConnectValidationError.invalidUsername
    }
    return username
  }
}
