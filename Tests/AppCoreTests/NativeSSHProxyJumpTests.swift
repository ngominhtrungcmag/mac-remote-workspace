import Foundation
import XCTest
@testable import AppCore

final class NativeSSHProxyJumpTests: XCTestCase {
  private final class OutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var foundMarker = false
    let markerFound = DispatchSemaphore(value: 0)

    func append(_ data: Data) {
      lock.lock()
      bytes.append(data)
      let text = String(decoding: bytes, as: UTF8.self)
      let shouldSignal = !foundMarker && text.contains("MRW_PROXYJUMP_OK")
      if shouldSignal { foundMarker = true }
      lock.unlock()
      if shouldSignal { markerFound.signal() }
    }

    var text: String {
      lock.lock()
      defer { lock.unlock() }
      return String(decoding: bytes, as: UTF8.self)
    }
  }

  func testJumpConfigurationUsesStrictIndependentHopPolicy() throws {
    let jump = NativeSSHProxyJumpEndpoint(host: "jump.example.net", port: 2201, username: "relay")
    let knownHostsURL = URL(fileURLWithPath: "/tmp/private known_hosts")
    let agentURL = URL(fileURLWithPath: "/tmp/agent.sock")

    let configuration = try NativeSSHProxyJumpConfigurationFile.contents(
      jump: jump,
      knownHostsFileURL: knownHostsURL,
      authentication: .agent(socketURL: agentURL),
      alias: "_mrw_test_jump"
    )

    XCTAssertTrue(configuration.contains("Host _mrw_test_jump\n"))
    XCTAssertTrue(configuration.contains("HostName \"jump.example.net\""))
    XCTAssertTrue(configuration.contains("Port 2201"))
    XCTAssertTrue(configuration.contains("User \"relay\""))
    XCTAssertTrue(configuration.contains("StrictHostKeyChecking yes"))
    XCTAssertTrue(configuration.contains("UserKnownHostsFile \"/tmp/private known_hosts\""))
    XCTAssertTrue(configuration.contains("GlobalKnownHostsFile /dev/null"))
    XCTAssertTrue(configuration.contains("UpdateHostKeys no"))
    XCTAssertTrue(configuration.contains("CheckHostIP no"))
    XCTAssertTrue(configuration.contains("PasswordAuthentication no"))
    XCTAssertTrue(configuration.contains("KbdInteractiveAuthentication no"))
    XCTAssertTrue(configuration.contains("ForwardAgent no"))
    XCTAssertFalse(configuration.contains("ProxyCommand"))
    XCTAssertFalse(configuration.contains("StrictHostKeyChecking no"))
  }

  func testProxyJumpRejectsNonAgentCredentialsBeforeProbeOrSessionStart() throws {
    let jump = NativeSSHProxyJumpEndpoint(host: "jump.example.net", username: "relay")
    let knownHostsURL = URL(fileURLWithPath: "/dev/null")
    let authenticationMethods: [NativeSSHAuthentication] = [
      .keychainAskpass(service: "test", account: "target", identityFile: nil),
      .identityFile(URL(fileURLWithPath: "/dev/null"))
    ]
    for authentication in authenticationMethods {
      let configuration = NativeSSHConfiguration(
        host: "target.example.net", username: "deploy", knownHostsFileURL: knownHostsURL,
        authentication: authentication, proxyJump: jump
      )
      XCTAssertThrowsError(try NativeSSHProxyJumpProbe.evaluateTargetHost(
        configuration: configuration,
        trustService: NativeSSHHostTrustService(knownHostsFileURL: knownHostsURL)
      )) { error in
        XCTAssertTrue(error.localizedDescription.contains("ProxyJump requires SSH agent"))
      }
      let session = NativeSSHSession(configuration: configuration)
      XCTAssertThrowsError(try session.start()) { error in
        XCTAssertTrue(error.localizedDescription.contains("ProxyJump requires SSH agent"))
      }
    }
  }

  func testProxyJumpArgumentsKeepTargetAndJumpSeparate() {
    let knownHostsURL = URL(fileURLWithPath: "/tmp/known_hosts")
    let configURL = URL(fileURLWithPath: "/tmp/mrw-ssh-config")
    let config = NativeSSHConfiguration(
      host: "target.internal",
      port: 2222,
      username: "deploy",
      knownHostsFileURL: knownHostsURL,
      authentication: .agent(socketURL: URL(fileURLWithPath: "/tmp/agent.sock")),
      proxyJump: NativeSSHProxyJumpEndpoint(host: "bastion.example.net", port: 2201, username: "relay")
    )

    let arguments = NativeSSHSession.buildSSHArguments(for: config, proxyJumpConfigURL: configURL, jumpAlias: "_mrw_jump")

    XCTAssertEqual(arguments[arguments.firstIndex(of: "-F")! + 1], configURL.path)
    XCTAssertEqual(arguments[arguments.firstIndex(of: "-J")! + 1], "_mrw_jump")
    XCTAssertTrue(arguments.contains("StrictHostKeyChecking=yes"))
    XCTAssertTrue(arguments.contains("UserKnownHostsFile=/tmp/known_hosts"))
    XCTAssertTrue(arguments.contains("GlobalKnownHostsFile=/dev/null"))
    XCTAssertEqual(arguments.last, "deploy@target.internal")
  }

  func testProxyJumpTunnelArgumentsReusePrivateHopConfigAndStrictPolicies() {
    let knownHostsURL = URL(fileURLWithPath: "/tmp/known_hosts")
    let configURL = URL(fileURLWithPath: "/tmp/mrw-ssh-config")
    let config = NativeSSHConfiguration(
      host: "target.internal",
      port: 2222,
      username: "deploy",
      knownHostsFileURL: knownHostsURL,
      authentication: .agent(socketURL: URL(fileURLWithPath: "/tmp/agent.sock")),
      proxyJump: NativeSSHProxyJumpEndpoint(host: "bastion.example.net", port: 2201, username: "relay")
    )

    let arguments = NativeSSHSession.buildLocalTunnelSSHArguments(
      configuration: config,
      localTunnel: NativeSSHLocalTunnelConfiguration(localPort: 15432, remoteHost: "db.internal", remotePort: 5432),
      proxyJumpConfigURL: configURL,
      jumpAlias: "_mrw_jump"
    )

    XCTAssertEqual(arguments.first, "-T")
    XCTAssertEqual(arguments[arguments.firstIndex(of: "-F")! + 1], configURL.path)
    XCTAssertEqual(arguments[arguments.firstIndex(of: "-J")! + 1], "_mrw_jump")
    XCTAssertTrue(arguments.contains("StrictHostKeyChecking=yes"))
    XCTAssertTrue(arguments.contains("UserKnownHostsFile=/tmp/known_hosts"))
    XCTAssertTrue(arguments.contains("GlobalKnownHostsFile=/dev/null"))
    XCTAssertTrue(arguments.contains("IdentityAgent=/tmp/agent.sock"))
    XCTAssertFalse(arguments.contains("ClearAllForwardings=yes"))
    XCTAssertEqual(arguments[arguments.firstIndex(of: "-L")! + 1], "127.0.0.1:15432:db.internal:5432")
    XCTAssertEqual(arguments.last, "deploy@target.internal")
  }

  func testValidationRejectsUnsafeJumpHostBeforeLaunchingSSH() {
    let config = NativeSSHConfiguration(
      host: "target.internal",
      username: "deploy",
      knownHostsFileURL: URL(fileURLWithPath: "/dev/null"),
      authentication: .agent(socketURL: URL(fileURLWithPath: "/tmp/agent.sock")),
      proxyJump: NativeSSHProxyJumpEndpoint(host: "-oProxyCommand=sh", username: "relay")
    )

    XCTAssertThrowsError(try NativeSSHSession.validate(configuration: config)) { error in
      guard case NativeSSHError.invalidHost = error else {
        XCTFail("Expected invalidHost error but got \(error)")
        return
      }
    }
  }

  func testProxyJumpKeyProbeAuthenticatesOnlyToTrustedJump() throws {
    let fixture = try proxyJumpFixture()
    let jumpOnlyKnownHosts = fixture.rootURL.appendingPathComponent("jump_only_known_hosts")
    let targetLog = fixture.rootURL.appendingPathComponent("target.log")
    let jumpLog = fixture.rootURL.appendingPathComponent("jump.log")
    let targetOffset = try fileSize(targetLog)
    let jumpOffset = try fileSize(jumpLog)
    let service = NativeSSHHostTrustService(knownHostsFileURL: jumpOnlyKnownHosts)

    let status = try NativeSSHProxyJumpProbe.evaluateTargetHost(
      configuration: fixture.configuration(knownHostsName: "jump_only_known_hosts"),
      trustService: service
    )

    guard case .unknown(let challenge) = status else {
      XCTFail("Expected an unknown target-key challenge.")
      return
    }
    XCTAssertEqual(challenge.host, fixture.targetHost)
    XCTAssertEqual(challenge.port, fixture.targetPort)
    XCTAssertTrue(challenge.presentedKey.rawLine.hasPrefix("[\(fixture.targetHost)]:\(fixture.targetPort) "))
    XCTAssertFalse(try logSuffix(targetLog, after: targetOffset).contains("Accepted publickey"))
    XCTAssertTrue(try logSuffix(jumpLog, after: jumpOffset).contains("Accepted publickey"))
  }

  func testProxyJumpSessionWorksAndRejectsEachMismatchedHopBeforeThatHopAuth() throws {
    let fixture = try proxyJumpFixture()
    let targetLog = fixture.rootURL.appendingPathComponent("target.log")
    let jumpLog = fixture.rootURL.appendingPathComponent("jump.log")

    // A changed target key is rejected after the verified jump authenticates, but before target auth.
    let targetMismatchOffset = try fileSize(targetLog)
    let targetMismatchSession = NativeSSHSession(configuration: fixture.configuration(knownHostsName: "wrong_target_known_hosts"))
    try assertSessionExits(targetMismatchSession)
    XCTAssertFalse(try logSuffix(targetLog, after: targetMismatchOffset).contains("Accepted publickey"))

    // A changed jump key is rejected before auth to that hop and before any target connection.
    let jumpMismatchOffset = try fileSize(jumpLog)
    let targetAuthBeforeJumpMismatch = try logSuffix(targetLog, after: 0)
      .components(separatedBy: "Accepted publickey").count - 1
    let jumpMismatchSession = NativeSSHSession(configuration: fixture.configuration(knownHostsName: "wrong_jump_known_hosts"))
    try assertSessionExits(jumpMismatchSession)
    XCTAssertFalse(try logSuffix(jumpLog, after: jumpMismatchOffset).contains("Accepted publickey"))
    let targetAuthAfterJumpMismatch = try logSuffix(targetLog, after: 0)
      .components(separatedBy: "Accepted publickey").count - 1
    XCTAssertEqual(targetAuthAfterJumpMismatch, targetAuthBeforeJumpMismatch)

    // With both endpoint keys recorded, a terminal session traverses the jump to the target.
    let successSession = NativeSSHSession(configuration: fixture.configuration(knownHostsName: "known_hosts"))
    let outputCapture = OutputCapture()
    successSession.onOutput = { data in outputCapture.append(data) }
    try successSession.start()
    usleep(500_000)
    let encodedMarker = "MRW_PROXYJUMP_OK".utf8.map { String(format: "\\x%02x", $0) }.joined()
    try successSession.write(string: "printf '\(encodedMarker)\\n'\n")
    XCTAssertEqual(
      outputCapture.markerFound.wait(timeout: .now() + 12),
      .success,
      "ProxyJump PTY did not reach the target shell. Captured: \(outputCapture.text)"
    )
    successSession.close()
  }

  private struct ProxyJumpFixture {
    let rootURL: URL
    let targetHost: String
    let targetPort: Int
    let jumpPort: Int
    let username: String
    let agentSocketURL: URL

    func configuration(knownHostsName: String) -> NativeSSHConfiguration {
      NativeSSHConfiguration(
        host: targetHost,
        port: targetPort,
        username: username,
        knownHostsFileURL: rootURL.appendingPathComponent(knownHostsName),
        authentication: .agent(socketURL: agentSocketURL),
        proxyJump: NativeSSHProxyJumpEndpoint(host: "127.0.0.1", port: jumpPort, username: username)
      )
    }
  }

  private func proxyJumpFixture() throws -> ProxyJumpFixture {
    let environment = ProcessInfo.processInfo.environment
    guard let root = environment["MRW_PROXYJUMP_FIXTURE_ROOT"],
          let targetPort = environment["MRW_PROXYJUMP_TARGET_PORT"].flatMap(Int.init),
          let jumpPort = environment["MRW_PROXYJUMP_JUMP_PORT"].flatMap(Int.init),
          let username = environment["MRW_PROXYJUMP_USER"],
          let agentSocket = environment["MRW_PROXYJUMP_AGENT_SOCK"] else {
      throw XCTSkip("MRW_PROXYJUMP disposable fixture environment not configured; run run-proxyjump-fixture.sh.")
    }
    return ProxyJumpFixture(
      rootURL: URL(fileURLWithPath: root, isDirectory: true),
      targetHost: "127.0.0.1",
      targetPort: targetPort,
      jumpPort: jumpPort,
      username: username,
      agentSocketURL: URL(fileURLWithPath: agentSocket)
    )
  }

  private func assertSessionExits(_ session: NativeSSHSession, file: StaticString = #filePath, line: UInt = #line) throws {
    let exited = DispatchSemaphore(value: 0)
    session.onStateChange = { state in
      if case .disconnected = state { exited.signal() }
    }
    try session.start()
    XCTAssertEqual(exited.wait(timeout: .now() + 12), .success, "Strict ProxyJump session did not exit.", file: file, line: line)
    session.close()
  }

  private func fileSize(_ url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
  }

  private func logSuffix(_ url: URL, after offset: UInt64) throws -> String {
    let data = try Data(contentsOf: url)
    guard offset < data.count else { return "" }
    return String(decoding: data.dropFirst(Int(offset)), as: UTF8.self)
  }
}
