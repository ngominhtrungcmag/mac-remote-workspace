import Foundation

public enum RdpLauncherError: Error, Equatable, AppCoreLocalizedError {
  case invalidEndpoint(String)
  case clientNotFound
  case launchFailed(String)

  public func displayDescription(locale: Locale?) -> String? {
    switch self {
    case .invalidEndpoint(let reason):
      return AppCoreLocalization.format(
        "Invalid RDP endpoint: %1$@", Self.localizedEndpointReason(reason, locale: locale), locale: locale)
    case .clientNotFound:
      return AppCoreLocalization.string("Windows App was not found. Install it in /Applications or copy the endpoint manually.", locale: locale)
    case .launchFailed(let message):
      return AppCoreLocalization.format("Could not open Windows App: %1$@", message, locale: locale)
    }
  }

  private static func localizedEndpointReason(_ reason: String, locale: Locale?) -> String {
    let prefix = "Invalid port in endpoint: '"
    guard reason.hasPrefix(prefix), reason.hasSuffix("'.") else {
      return AppCoreLocalization.string(reason, locale: locale)
    }
    let start = reason.index(reason.startIndex, offsetBy: prefix.count)
    let end = reason.index(reason.endIndex, offsetBy: -2)
    return AppCoreLocalization.format("Invalid port in endpoint: '%1$@'.", String(reason[start..<end]), locale: locale)
  }
}

public protocol RdpClientLaunching: Sendable {
  func isClientAvailable() -> Bool
  func launch(endpoint: String) async throws
}

public struct RdpLauncher: RdpClientLaunching, Sendable {
  public static let defaultPort: UInt16 = 3389
  public static let bundleID = "com.microsoft.rdc.macos"

  public let searchRoots: [URL]

  public init(searchRoots: [URL]? = nil) {
    if let searchRoots {
      self.searchRoots = searchRoots
    } else {
      let homeApps: URL? = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
      self.searchRoots = [
        URL(fileURLWithPath: "/Applications"),
        homeApps,
      ].compactMap { $0 }
    }
  }

  /// Formats an address and port into an endpoint string, e.g. "192.168.1.1:3389" or "[::1]:3389".
  public static func formatEndpoint(address: String, port: UInt16 = defaultPort) throws -> String {
    let validatedAddress = try validateAddress(address)
    guard (1...65535).contains(port) else {
      throw RdpLauncherError.invalidEndpoint("Port must be between 1 and 65535.")
    }
    if validatedAddress.contains(":") {
      return "[\(validatedAddress)]:\(port)"
    } else {
      return "\(validatedAddress):\(port)"
    }
  }

  /// Validates an address rigorously according to domain rules and IPv6 safety.
  /// Prevents URI injection, whitespace, control characters, query params, etc.
  public static func validateAddress(_ rawAddress: String) throws -> String {
    let trimmed = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed != rawAddress {
      throw RdpLauncherError.invalidEndpoint("Address must not contain leading or trailing whitespace.")
    }
    if trimmed.isEmpty || trimmed.utf8.count > 253 {
      throw RdpLauncherError.invalidEndpoint("Address length must be between 1 and 253 bytes.")
    }
    if trimmed.hasPrefix("-") || trimmed.hasPrefix(".") || trimmed.hasSuffix(".") {
      throw RdpLauncherError.invalidEndpoint("Address cannot start with a dash/dot or end with a dot.")
    }

    // Check for URI injection characters (? & = # / \ @ etc.)
    let allowedChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:_[]")
    if !trimmed.unicodeScalars.allSatisfy(allowedChars.contains) {
      throw RdpLauncherError.invalidEndpoint("Address contains disallowed characters.")
    }

    // Strip brackets if present for IPv6 check
    let stripped: String
    if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
      stripped = String(trimmed.dropFirst().dropLast())
    } else {
      stripped = trimmed
    }

    if stripped.contains(":") {
      // Must be a valid IPv6 address
      var sin6 = sockaddr_in6()
      let status = stripped.withCString { cstr in
        inet_pton(AF_INET6, cstr, &sin6.sin6_addr)
      }
      guard status == 1 else {
        throw RdpLauncherError.invalidEndpoint("Invalid IPv6 address.")
      }
      return stripped
    } else {
      // Must not contain brackets if IPv4/hostname
      if trimmed.contains("[") || trimmed.contains("]") {
        throw RdpLauncherError.invalidEndpoint("Disallowed brackets in non-IPv6 address.")
      }

      // Check if it's a numeric IPv4 address (digits and dots)
      var sin4 = sockaddr_in()
      let isNumericIpCandidate = stripped.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789.").contains($0) }
      if isNumericIpCandidate {
        let status = stripped.withCString { cstr in
          inet_pton(AF_INET, cstr, &sin4.sin_addr)
        }
        guard status == 1 else {
          throw RdpLauncherError.invalidEndpoint("Invalid IPv4 address.")
        }
        return stripped
      }

      // Validate DNS hostname labels (RFC 1123 / RFC 952)
      // Disallow underscores, consecutive dots (a..b), leading/trailing hyphens per label (a.-b, a-.b), label length > 63
      let labels = stripped.split(separator: ".", omittingEmptySubsequences: false)
      guard !labels.isEmpty else {
        throw RdpLauncherError.invalidEndpoint("Hostname cannot be empty.")
      }

      let labelAllowedChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
      for label in labels {
        if label.isEmpty {
          throw RdpLauncherError.invalidEndpoint("Hostname label cannot be empty (consecutive dots are not allowed).")
        }
        if label.utf8.count > 63 {
          throw RdpLauncherError.invalidEndpoint("Hostname label exceeds 63 characters.")
        }
        if label.hasPrefix("-") || label.hasSuffix("-") {
          throw RdpLauncherError.invalidEndpoint("Hostname label cannot start or end with a hyphen.")
        }
        if !label.unicodeScalars.allSatisfy(labelAllowedChars.contains) {
          throw RdpLauncherError.invalidEndpoint("Hostname label contains disallowed characters.")
        }
      }

      return stripped
    }
  }

  /// Builds the safe, credentials-free rdp:// URI matching macOS client standards:
  /// rdp://full%20address=s%3A...
  public static func makeRdpURI(endpoint: String) throws -> URL {
    let parts = endpoint.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count >= 2 else {
      throw RdpLauncherError.invalidEndpoint("Endpoint must contain host and port separated by ':'.")
    }

    // Parse host and port: port is the last component
    let portString = String(parts.last!)
    guard let port = UInt16(portString), (1...65535).contains(port) else {
      throw RdpLauncherError.invalidEndpoint("Invalid port in endpoint: '\(portString)'.")
    }

    let hostPart = String(endpoint.dropLast(portString.count + 1))
    let address = try validateAddress(hostPart)

    let formattedAddress: String
    if address.contains(":") {
      formattedAddress = "[\(address)]"
    } else {
      formattedAddress = address
    }

    // Build URI with percent-encoded delimiters
    let encodedEndpoint = "\(formattedAddress):\(port)"
      .replacingOccurrences(of: ":", with: "%3A")
      .replacingOccurrences(of: "[", with: "%5B")
      .replacingOccurrences(of: "]", with: "%5D")

    let uriString = "rdp://full%20address=s%3A\(encodedEndpoint)"
    guard let url = URL(string: uriString) else {
      throw RdpLauncherError.invalidEndpoint("Failed to construct URI from endpoint.")
    }
    return url
  }

  public func isClientAvailable() -> Bool {
    let candidateNames = ["Windows App.app", "Microsoft Remote Desktop.app"]

    for root in searchRoots {
      for name in candidateNames {
        let plistURL = root.appendingPathComponent(name).appendingPathComponent("Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: plistURL.path) else { continue }
        if let data = try? Data(contentsOf: plistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let bundleId = plist["CFBundleIdentifier"] as? String,
           bundleId == Self.bundleID {
          return true
        }
      }
    }
    return false
  }

  public func launch(endpoint: String) async throws {
    let uri = try Self.makeRdpURI(endpoint: endpoint)

    guard isClientAvailable() else {
      RedactedLogger.shared.error("rdp", "session start failed: client not found")
      throw RdpLauncherError.clientNotFound
    }

    RedactedLogger.shared.info("rdp", "session start \(endpoint)")
    do { try await Task.detached(priority: .userInitiated) {
      // Execute /usr/bin/open directly without any shell
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      process.arguments = ["-b", Self.bundleID, uri.absoluteString]
      let pipe = Pipe()
      process.standardError = pipe
      process.standardOutput = pipe

      do {
        try process.run()
        // Drain pipe asynchronously before or alongside waitUntilExit to prevent buffer deadlock
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
          let output = String(data: outputData, encoding: .utf8) ?? ""
          throw RdpLauncherError.launchFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
      } catch let error as RdpLauncherError {
        throw error
      } catch {
        throw RdpLauncherError.launchFailed(error.localizedDescription)
      }
    }.value
    } catch {
      RedactedLogger.shared.error("rdp", "session start failed \(endpoint)")
      throw error
    }
  }
}
