import Foundation
import XCTest
@testable import AppCore

final class QuickConnectTargetTests: XCTestCase {

  // MARK: - Valid SSH Targets

  func testParsesValidSSHURLWithUserHostAndPort() throws {
    let target = try QuickConnectTarget.parse("ssh://deploy@app-01.example.com:2222")
    XCTAssertEqual(target.connectionProtocol, .ssh)
    XCTAssertEqual(target.username, "deploy")
    XCTAssertEqual(target.host, "app-01.example.com")
    XCTAssertEqual(target.port, 2222)
    XCTAssertEqual(target.bracketedHost, "app-01.example.com")
    XCTAssertEqual(target.endpointString, "app-01.example.com:2222")
    XCTAssertEqual(target.canonicalURIString, "ssh://deploy@app-01.example.com:2222")
  }

  func testParsesValidSSHURLDefaultsToPort22AndNilUsername() throws {
    let withoutPort = try QuickConnectTarget.parse("ssh://root@192.168.1.50")
    XCTAssertEqual(withoutPort.connectionProtocol, .ssh)
    XCTAssertEqual(withoutPort.username, "root")
    XCTAssertEqual(withoutPort.host, "192.168.1.50")
    XCTAssertEqual(withoutPort.port, 22)

    let withoutUser = try QuickConnectTarget.parse("ssh://10.0.0.1:2200")
    XCTAssertEqual(withoutUser.connectionProtocol, .ssh)
    XCTAssertNil(withoutUser.username)
    XCTAssertEqual(withoutUser.host, "10.0.0.1")
    XCTAssertEqual(withoutUser.port, 2200)
    XCTAssertEqual(withoutUser.canonicalURIString, "ssh://10.0.0.1:2200")
  }

  func testParsesValidSSHIPv6BracketedURL() throws {
    let ipv6WithPort = try QuickConnectTarget.parse("ssh://ops@[2001:db8::1]:2201")
    XCTAssertEqual(ipv6WithPort.connectionProtocol, .ssh)
    XCTAssertEqual(ipv6WithPort.username, "ops")
    XCTAssertEqual(ipv6WithPort.host, "2001:db8::1")
    XCTAssertEqual(ipv6WithPort.bracketedHost, "[2001:db8::1]")
    XCTAssertEqual(ipv6WithPort.port, 2201)
    XCTAssertEqual(ipv6WithPort.endpointString, "[2001:db8::1]:2201")
    XCTAssertEqual(ipv6WithPort.canonicalURIString, "ssh://ops@[2001:db8::1]:2201")

    let ipv6DefaultPort = try QuickConnectTarget.parse("ssh://[::1]")
    XCTAssertEqual(ipv6DefaultPort.connectionProtocol, .ssh)
    XCTAssertNil(ipv6DefaultPort.username)
    XCTAssertEqual(ipv6DefaultPort.host, "::1")
    XCTAssertEqual(ipv6DefaultPort.port, 22)
  }

  func testCaseInsensitiveSchemeAndTrimmedOuterWhitespace() throws {
    let sshUpper = try QuickConnectTarget.parse("  SSH://alice@host.local:2222  ")
    XCTAssertEqual(sshUpper.connectionProtocol, .ssh)
    XCTAssertEqual(sshUpper.username, "alice")
    XCTAssertEqual(sshUpper.host, "host.local")
    XCTAssertEqual(sshUpper.port, 2222)

    let rdpMixed = try QuickConnectTarget.parse("  RdP://win.local:3390 ")
    XCTAssertEqual(rdpMixed.connectionProtocol, .rdp)
    XCTAssertEqual(rdpMixed.host, "win.local")
    XCTAssertEqual(rdpMixed.port, 3390)
  }

  // MARK: - Valid RDP Targets

  func testParsesValidRDPURLHostnameIPv4AndBracketedIPv6() throws {
    let hostnameTarget = try QuickConnectTarget.parse("rdp://win-srv.corp.internal:3390")
    XCTAssertEqual(hostnameTarget.connectionProtocol, .rdp)
    XCTAssertNil(hostnameTarget.username)
    XCTAssertEqual(hostnameTarget.host, "win-srv.corp.internal")
    XCTAssertEqual(hostnameTarget.port, 3390)
    XCTAssertEqual(hostnameTarget.canonicalURIString, "rdp://win-srv.corp.internal:3390")

    let ipv4DefaultPort = try QuickConnectTarget.parse("rdp://172.16.0.10")
    XCTAssertEqual(ipv4DefaultPort.connectionProtocol, .rdp)
    XCTAssertNil(ipv4DefaultPort.username)
    XCTAssertEqual(ipv4DefaultPort.host, "172.16.0.10")
    XCTAssertEqual(ipv4DefaultPort.port, 3389)

    let ipv6Target = try QuickConnectTarget.parse("rdp://[fe80::1]:3389")
    XCTAssertEqual(ipv6Target.connectionProtocol, .rdp)
    XCTAssertEqual(ipv6Target.host, "fe80::1")
    XCTAssertEqual(ipv6Target.bracketedHost, "[fe80::1]")
    XCTAssertEqual(ipv6Target.port, 3389)
    XCTAssertEqual(ipv6Target.endpointString, "[fe80::1]:3389")
  }

  // MARK: - Plain Host Requires Explicit Protocol

  func testPlainHostRequiresExplicitProtocolSelection() throws {
    let plainInputs = [
      "example.com",
      "example.com:22",
      "user@example.com",
      "user@example.com:2222",
      "192.168.1.10:3389",
      "[::1]:22",
    ]
    for input in plainInputs {
      XCTAssertThrowsError(try QuickConnectTarget.parse(input), "Expected missingProtocol for '\(input)'") { error in
        XCTAssertEqual(error as? QuickConnectValidationError, .missingProtocol)
      }
    }

    let sshPlain = try QuickConnectTarget.parse("deploy@bastion.internal:2202", explicitProtocol: .ssh)
    XCTAssertEqual(sshPlain.connectionProtocol, .ssh)
    XCTAssertEqual(sshPlain.username, "deploy")
    XCTAssertEqual(sshPlain.host, "bastion.internal")
    XCTAssertEqual(sshPlain.port, 2202)

    let rdpPlain = try QuickConnectTarget.parse("[2001:db8::42]", explicitProtocol: .rdp)
    XCTAssertEqual(rdpPlain.connectionProtocol, .rdp)
    XCTAssertNil(rdpPlain.username)
    XCTAssertEqual(rdpPlain.host, "2001:db8::42")
    XCTAssertEqual(rdpPlain.port, 3389)
  }

  // MARK: - Security & Negative Validation Tests (C4)

  func testRejectsPasswordInURLAndDoesNotEchoSecretInError() {
    let canary = "CANARY_SECRET_P4SS_9981"
    let passwordInputs = [
      "ssh://admin:\(canary)@example.com:22",
      "ssh://admin:\(canary)@127.0.0.1",
      "ssh://admin:@example.com",
      "ssh://:\(canary)@example.com",
      "rdp://admin:\(canary)@example.com:3389",
      "admin:\(canary)@example.com",
    ]

    for input in passwordInputs {
      XCTAssertThrowsError(try QuickConnectTarget.parse(input, explicitProtocol: .ssh), "Accepted password input: \(input)") { error in
        XCTAssertEqual(error as? QuickConnectValidationError, .passwordInTargetNotAllowed)
        XCTAssertFalse(error.localizedDescription.contains(canary), "Error leaked secret canary!")
        XCTAssertFalse(String(describing: error).contains(canary), "Error debug description leaked secret canary!")
      }
    }
  }

  func testRejectsUsernameInRDPTarget() {
    let rdpUserInputs = [
      "rdp://administrator@win.example.com:3389",
      "rdp://corp@10.0.0.5",
    ]
    for input in rdpUserInputs {
      XCTAssertThrowsError(try QuickConnectTarget.parse(input)) { error in
        XCTAssertEqual(error as? QuickConnectValidationError, .usernameNotSupportedForRDP)
      }
    }

    XCTAssertThrowsError(try QuickConnectTarget.parse("administrator@win.example.com", explicitProtocol: .rdp)) { error in
      XCTAssertEqual(error as? QuickConnectValidationError, .usernameNotSupportedForRDP)
    }
  }

  func testRejectsQueryParametersFragmentsAndURIInjection() {
    let canary = "CANARY_QUERY_SECRET_7721"
    let queryAndFragmentInputs = [
      "ssh://user@example.com?ProxyCommand=sh",
      "ssh://user@example.com:22?password=\(canary)",
      "ssh://user@example.com#fragment",
      "rdp://example.com:3389?full%20address=s:evil.com",
      "rdp://example.com:3389&username=admin",
      "rdp://example.com:3389#section",
      "rdp://full=address",
      "example.com?foo=bar",
    ]

    for input in queryAndFragmentInputs {
      XCTAssertThrowsError(try QuickConnectTarget.parse(input, explicitProtocol: .ssh), "Accepted query/fragment input: \(input)") { error in
        XCTAssertFalse(error.localizedDescription.contains(canary))
      }
    }
  }

  func testRejectsPathsCommandsAndOptionInjection() {
    let commandAndOptionInputs = [
      "ssh://user@example.com/bin/sh",
      "ssh://user@example.com:22/path",
      "ssh://user@example.com:22/",
      "rdp://example.com:3389/",
      "ssh://-oProxyCommand=sh@example.com",
      "ssh://user@-oProxyCommand=sh",
      "ssh://-Jjump@example.com",
      "-oProxyCommand=id",
      "-L1234:localhost:22",
      "ssh://user@example.com;id",
      "ssh://user@example.com|sh",
      "ssh://user@example.com`whoami`",
      "ssh://user@example.com$(id)",
      "ssh://user\\name@example.com",
    ]

    for input in commandAndOptionInputs {
      XCTAssertThrowsError(try QuickConnectTarget.parse(input, explicitProtocol: .ssh), "Accepted path/command/option input: \(input)")
    }
  }

  func testRejectsControlCharactersInternalWhitespaceAndPercentEncoding() {
    let controlAndEncodingInputs = [
      "ssh://user@example.com\0",
      "ssh://user@example.com\n22",
      "ssh://user@example.com\r:22",
      "ssh://user\t@example.com",
      "ssh://user@exam\u{0007}ple.com",
      "ssh://user@exam\u{001B}ple.com",
      "ssh://user@exam\u{007F}ple.com",
      "ssh://user name@example.com",
      "ssh://user@example.com :22",
      "ssh://user@example.com: 22",
      "ssh://user%40evil@example.com",
      "ssh://user%3Apass@example.com",
      "rdp://example%2Ecom:3389",
    ]

    for input in controlAndEncodingInputs {
      XCTAssertThrowsError(try QuickConnectTarget.parse(input, explicitProtocol: .ssh), "Accepted control/whitespace/encoded input: \(input)")
    }
  }

  func testRejectsUnsupportedProtocolsAndMalformedHostsAndPorts() {
    let unsupportedSchemes = [
      "http://example.com",
      "https://example.com",
      "sftp://example.com",
      "vnc://example.com:5900",
      "telnet://example.com:23",
      "file:///etc/passwd",
    ]
    for input in unsupportedSchemes {
      XCTAssertThrowsError(try QuickConnectTarget.parse(input)) { error in
        XCTAssertEqual(error as? QuickConnectValidationError, .unsupportedProtocol)
      }
    }

    let invalidPorts = [
      "ssh://example.com:0",
      "ssh://example.com:65536",
      "ssh://example.com:-22",
      "ssh://example.com:+22",
      "ssh://example.com:abc",
      "ssh://example.com:",
      "rdp://[::1]:0",
      "rdp://[::1]:70000",
      "rdp://[::1]:",
    ]
    for input in invalidPorts {
      XCTAssertThrowsError(try QuickConnectTarget.parse(input), "Accepted invalid port: \(input)") { error in
        XCTAssertEqual(error as? QuickConnectValidationError, .invalidPort)
      }
    }

    let invalidHosts = [
      "ssh://",
      "ssh://user@",
      "ssh://:22",
      "ssh://2001:db8::1", // unbracketed IPv6 must be rejected
      "rdp://::1:3389",    // unbracketed IPv6 must be rejected
      "ssh://[not-ipv6]:22",
      "ssh://[127.0.0.1]:22",
      "ssh://[::1",
      "ssh://::1]",
      "ssh://[[::1]]:22",
      "ssh://999.999.999.999:22",
      "ssh://256.1.1.1:22",
      "ssh://1.2.3.4.5:22",
      "ssh://.example.com",
      "ssh://example.com.",
      "ssh://a..b.com",
      "ssh://-badhost.com",
      "ssh://bad-.com",
      "ssh://host_with_underscore.com",
    ]
    for input in invalidHosts {
      XCTAssertThrowsError(try QuickConnectTarget.parse(input), "Accepted invalid host: \(input)")
    }
  }

  func testDirectInitializerEnforcesSameValidationAndBounds() {
    XCTAssertThrowsError(try QuickConnectTarget(connectionProtocol: .ssh, host: "::1", port: 22)) { error in
      XCTAssertEqual(error as? QuickConnectValidationError, .invalidHost)
    }
    XCTAssertThrowsError(try QuickConnectTarget(connectionProtocol: .ssh, host: "-oProxyCommand=sh", port: 22)) { error in
      XCTAssertEqual(error as? QuickConnectValidationError, .pathOrCommandNotAllowed)
    }
    XCTAssertThrowsError(try QuickConnectTarget(connectionProtocol: .rdp, host: "example.com", port: 3389, username: "admin")) { error in
      XCTAssertEqual(error as? QuickConnectValidationError, .usernameNotSupportedForRDP)
    }
    XCTAssertThrowsError(try QuickConnectTarget(connectionProtocol: .ssh, host: "example.com", port: 22, username: "user:pass")) { error in
      XCTAssertEqual(error as? QuickConnectValidationError, .passwordInTargetNotAllowed)
    }

    let oversized = "ssh://" + String(repeating: "a", count: QuickConnectTarget.maxInputUTF8Bytes) + ".com"
    XCTAssertThrowsError(try QuickConnectTarget.parse(oversized)) { error in
      XCTAssertEqual(error as? QuickConnectValidationError, .inputTooLong)
    }
  }
}
