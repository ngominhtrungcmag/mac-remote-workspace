import XCTest
@testable import AppCore

final class TerminalSecurityPolicyTests: XCTestCase {
  func testRemoteClipboardWriteDenied() {
    XCTAssertFalse(TerminalSecurityPolicy.allowsRemoteClipboardWrite)
  }

  func testURLAllowlist() {
    XCTAssertEqual(TerminalSecurityPolicy.validatedLinkURL("https://example.com/a?b=1")?.host, "example.com")
    XCTAssertNotNil(TerminalSecurityPolicy.validatedLinkURL("http://example.com"))
    let bad = [
      "file:///etc/passwd", "javascript:alert(1)", "ssh://h", "x-custom://a", "mailto:a@b.c",
      "https://exa mple.com", "https://example.com/\u{1B}[", "https://example.com/\n",
      "https://u:p@example.com", "https://", "",
      "https://example.com/" + String(repeating: "a", count: 3000),
    ]
    for b in bad { XCTAssertNil(TerminalSecurityPolicy.validatedLinkURL(b), b) }
  }
}
