import XCTest
@testable import MacRemoteWorkspace

final class SSHJumpFormTests: XCTestCase {
  func testSavedJumpParsing() {
    let host = SSHConnectionFormState.jumpComponents("alice@jump.example:2222", defaultUser: "local")
    XCTAssertEqual(host?.user, "alice")
    XCTAssertEqual(host?.host, "jump.example")
    XCTAssertEqual(host?.port, 2222)
    let ipv6 = SSHConnectionFormState.jumpComponents("[::1]", defaultUser: "local")
    XCTAssertEqual(ipv6?.user, "local")
    XCTAssertEqual(ipv6?.host, "::1")
    XCTAssertEqual(ipv6?.port, 22)
    XCTAssertNil(SSHConnectionFormState.jumpComponents("jump:bad", defaultUser: "local"))
    XCTAssertNil(SSHConnectionFormState.jumpComponents("a@b@c", defaultUser: "local"))
  }
}
