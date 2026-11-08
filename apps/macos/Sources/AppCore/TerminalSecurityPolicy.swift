import Foundation

/// FR-026 / TC-019: remote terminal output may never write the clipboard (OSC 52) or
/// trigger link opens on its own. A link may only be opened via `validatedLinkURL`
/// after the user confirms the full URL.
public enum TerminalSecurityPolicy {
  public static let maxURLLength = 2048
  /// OSC 52: remote output must never write the local clipboard.
  public static let allowsRemoteClipboardWrite = false

  /// Returns a URL safe to offer for confirmed opening: http/https only, host required,
  /// no control/whitespace chars, no userinfo, bounded length. Otherwise nil.
  public static func validatedLinkURL(_ raw: String) -> URL? {
    guard !raw.isEmpty, raw.utf8.count <= maxURLLength,
      !raw.unicodeScalars.contains(where: {
        $0.value < 0x21 || $0.value == 0x7F || ($0.value >= 0x80 && $0.value < 0xA0)
      }),
      let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = url.host, !host.isEmpty, url.user == nil, url.password == nil
    else { return nil }
    return url
  }
}
