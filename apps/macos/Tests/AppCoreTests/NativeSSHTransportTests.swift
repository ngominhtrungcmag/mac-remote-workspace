import Darwin
import Foundation
import XCTest
@testable import AppCore

final class NativeSSHTransportTests: XCTestCase {

  // MARK: - Validation & Injection Tests

  func testValidationRejectsInvalidHostnames() {
    let dummyFile = URL(fileURLWithPath: "/dev/null")
    let validAuth = NativeSSHAuthentication.identityFile(dummyFile)

    let badHosts = [
      "",
      "   ",
      " host",
      "host ",
      "-oProxyCommand=rm",
      "host;rm -rf /",
      "host&whoami",
      "host|sh",
      "host`id`",
      "host$PATH",
      "host (test)",
      "host{test}",
      "host[test]",
      "host@test",
      "host\0test",
      "host\ntest",
      "host\rtest",
    ]

    for badHost in badHosts {
      let config = NativeSSHConfiguration(
        host: badHost,
        port: 22,
        username: "testuser",
        knownHostsFileURL: dummyFile,
        authentication: validAuth
      )
      XCTAssertThrowsError(try NativeSSHSession.validate(configuration: config), "Expected failure for host: '\(badHost)'") { error in
        guard case NativeSSHError.invalidHost = error else {
          XCTFail("Expected invalidHost error but got \(error)")
          return
        }
      }
    }
  }

  func testValidationRejectsInvalidPorts() {
    let dummyFile = URL(fileURLWithPath: "/dev/null")
    let validAuth = NativeSSHAuthentication.identityFile(dummyFile)

    let badPorts = [-1, 0, 65536, 100000]
    for badPort in badPorts {
      let config = NativeSSHConfiguration(
        host: "localhost",
        port: badPort,
        username: "testuser",
        knownHostsFileURL: dummyFile,
        authentication: validAuth
      )
      XCTAssertThrowsError(try NativeSSHSession.validate(configuration: config), "Expected failure for port: \(badPort)") { error in
        guard case NativeSSHError.invalidPort = error else {
          XCTFail("Expected invalidPort error but got \(error)")
          return
        }
      }
    }
  }

  func testValidationRejectsInvalidUsernames() {
    let dummyFile = URL(fileURLWithPath: "/dev/null")
    let validAuth = NativeSSHAuthentication.identityFile(dummyFile)

    let badUsers = [
      "",
      "  ",
      " user",
      "user ",
      "-oProxyCommand",
      "user;rm",
      "user|sh",
      "user`id`",
      "user\nname",
      "user\0name",
      "user:root",
      "user[test]",
      "user@test",
    ]

    for badUser in badUsers {
      let config = NativeSSHConfiguration(
        host: "localhost",
        port: 22,
        username: badUser,
        knownHostsFileURL: dummyFile,
        authentication: validAuth
      )
      XCTAssertThrowsError(try NativeSSHSession.validate(configuration: config), "Expected failure for user: '\(badUser)'") { error in
        guard case NativeSSHError.invalidUsername = error else {
          XCTFail("Expected invalidUsername error but got \(error)")
          return
        }
      }
    }
  }

  func testValidationRejectsMissingKnownHosts() {
    let nonExistentFile = URL(fileURLWithPath: "/tmp/non_existent_known_hosts_\(UUID().uuidString)")
    let dummyFile = URL(fileURLWithPath: "/dev/null")
    let validAuth = NativeSSHAuthentication.identityFile(dummyFile)

    let config = NativeSSHConfiguration(
      host: "localhost",
      port: 22,
      username: "testuser",
      knownHostsFileURL: nonExistentFile,
      authentication: validAuth
    )

    XCTAssertThrowsError(try NativeSSHSession.validate(configuration: config)) { error in
      guard case NativeSSHError.missingKnownHostsFile = error else {
        XCTFail("Expected missingKnownHostsFile error but got \(error)")
        return
      }
    }
  }

  func testValidationRejectsMissingIdentityFileOrAgentSocket() {
    let dummyFile = URL(fileURLWithPath: "/dev/null")
    let nonExistentKey = URL(fileURLWithPath: "/tmp/non_existent_key_\(UUID().uuidString)")

    let keyConfig = NativeSSHConfiguration(
      host: "localhost",
      port: 22,
      username: "testuser",
      knownHostsFileURL: dummyFile,
      authentication: .identityFile(nonExistentKey)
    )
    XCTAssertThrowsError(try NativeSSHSession.validate(configuration: keyConfig)) { error in
      guard case NativeSSHError.missingIdentityFile = error else {
        XCTFail("Expected missingIdentityFile error but got \(error)")
        return
      }
    }

    let nonExistentSocket = URL(fileURLWithPath: "/tmp/non_existent_socket_\(UUID().uuidString)")
    let agentConfig = NativeSSHConfiguration(
      host: "localhost",
      port: 22,
      username: "testuser",
      knownHostsFileURL: dummyFile,
      authentication: .agent(socketURL: nonExistentSocket)
    )
    XCTAssertThrowsError(try NativeSSHSession.validate(configuration: agentConfig)) { error in
      guard case NativeSSHError.missingAgentSocket = error else {
        XCTFail("Expected missingAgentSocket error but got \(error)")
        return
      }
    }
  }

  // MARK: - Argument Security Structure Tests

  func testBuildSSHArgumentsEnforcesStrictIsolation() {
    let knownHosts = URL(fileURLWithPath: "/var/tmp/app_known_hosts")
    let keyFile = URL(fileURLWithPath: "/var/tmp/id_ed25519")

    let config = NativeSSHConfiguration(
      host: "server.example.com",
      port: 2222,
      username: "deploy",
      knownHostsFileURL: knownHosts,
      authentication: .identityFile(keyFile)
    )

    let args = NativeSSHSession.buildSSHArguments(for: config)

    // Check strict host key checking arguments
    XCTAssertTrue(args.contains("-F"))
    XCTAssertEqual(args[args.firstIndex(of: "-F")! + 1], "/dev/null")

    XCTAssertTrue(args.contains("-p"))
    XCTAssertEqual(args[args.firstIndex(of: "-p")! + 1], "2222")

    XCTAssertTrue(args.contains("BatchMode=yes"))
    XCTAssertTrue(args.contains("ServerAliveInterval=30"))
    XCTAssertTrue(args.contains("ServerAliveCountMax=3"))
    XCTAssertTrue(args.contains("StrictHostKeyChecking=yes"))
    XCTAssertTrue(args.contains("UserKnownHostsFile=/var/tmp/app_known_hosts"))
    XCTAssertTrue(args.contains("GlobalKnownHostsFile=/dev/null"))
    XCTAssertTrue(args.contains("UpdateHostKeys=no"))
    XCTAssertTrue(args.contains("PasswordAuthentication=no"))
    XCTAssertTrue(args.contains("KbdInteractiveAuthentication=no"))
    XCTAssertTrue(args.contains("PreferredAuthentications=publickey"))
    XCTAssertTrue(args.contains("ConnectTimeout=10"))
    XCTAssertTrue(args.contains("EscapeChar=none"))
    XCTAssertTrue(args.contains("ClearAllForwardings=yes"))
    XCTAssertTrue(args.contains("ForwardAgent=no"))
    XCTAssertTrue(args.contains("ForwardX11=no"))

    // Key file arguments
    XCTAssertTrue(args.contains("-i"))
    XCTAssertEqual(args[args.firstIndex(of: "-i")! + 1], "/var/tmp/id_ed25519")
    XCTAssertTrue(args.contains("IdentitiesOnly=yes"))
    XCTAssertTrue(args.contains("IdentityAgent=none"))

    // Target host
    XCTAssertEqual(args.last, "deploy@server.example.com")
  }

  func testBuildSSHArgumentsForAgentAuth() {
    let knownHosts = URL(fileURLWithPath: "/var/tmp/app_known_hosts")
    let socketURL = URL(fileURLWithPath: "/var/tmp/agent.sock")

    let config = NativeSSHConfiguration(
      host: "10.0.0.1",
      port: 22,
      username: "admin",
      knownHostsFileURL: knownHosts,
      authentication: .agent(socketURL: socketURL)
    )

    let args = NativeSSHSession.buildSSHArguments(for: config)

    XCTAssertTrue(args.contains("IdentityAgent=/var/tmp/agent.sock"))
    XCTAssertTrue(args.contains("IdentityFile=none"))
    XCTAssertEqual(args.last, "admin@10.0.0.1")
  }

  func testLocalTunnelValidationAndArgumentsAreLoopbackOnly() throws {
    let sshConfig = NativeSSHConfiguration(
      host: "server.example.com",
      port: 2222,
      username: "deploy",
      knownHostsFileURL: URL(fileURLWithPath: "/var/tmp/app_known_hosts"),
      authentication: .agent(socketURL: URL(fileURLWithPath: "/var/tmp/agent.sock"))
    )
    let tunnelConfig = NativeSSHLocalTunnelConfiguration(
      localPort: 15432,
      remoteHost: "db.internal",
      remotePort: 5432
    )

    XCTAssertNoThrow(try NativeSSHSession.validate(localTunnel: tunnelConfig))
    let args = NativeSSHSession.buildLocalTunnelSSHArguments(configuration: sshConfig, localTunnel: tunnelConfig)
    XCTAssertTrue(args.contains("-N"))
    XCTAssertTrue(args.contains("-T"))
    XCTAssertTrue(args.contains("ExitOnForwardFailure=yes"))
    XCTAssertTrue(args.contains("StrictHostKeyChecking=yes"))
    XCTAssertTrue(args.contains("UserKnownHostsFile=/var/tmp/app_known_hosts"))
    XCTAssertTrue(args.contains("IdentityAgent=/var/tmp/agent.sock"))
    XCTAssertTrue(args.contains("ForwardAgent=no"))
    XCTAssertTrue(args.contains("ForwardX11=no"))
    XCTAssertFalse(args.contains("ClearAllForwardings=yes"))
    XCTAssertEqual(args[args.firstIndex(of: "-F")! + 1], "/dev/null")
    XCTAssertFalse(args.contains("-tt"))
    XCTAssertEqual(args[args.firstIndex(of: "-L")! + 1], "127.0.0.1:15432:db.internal:5432")
    XCTAssertEqual(args.last, "deploy@server.example.com")

    let ipv6Args = NativeSSHSession.buildLocalTunnelSSHArguments(
      configuration: sshConfig,
      localTunnel: NativeSSHLocalTunnelConfiguration(localPort: 15432, remoteHost: "::1", remotePort: 5432)
    )
    XCTAssertEqual(ipv6Args[ipv6Args.firstIndex(of: "-L")! + 1], "127.0.0.1:15432:[::1]:5432")

    let badConfigurations = [
      NativeSSHLocalTunnelConfiguration(localPort: 0, remoteHost: "db.internal", remotePort: 5432),
      NativeSSHLocalTunnelConfiguration(localPort: 65536, remoteHost: "db.internal", remotePort: 5432),
      NativeSSHLocalTunnelConfiguration(localPort: 15432, remoteHost: "-oProxyCommand=bad", remotePort: 5432),
      NativeSSHLocalTunnelConfiguration(localPort: 15432, remoteHost: "db.internal;id", remotePort: 5432),
      NativeSSHLocalTunnelConfiguration(localPort: 15432, remoteHost: "db..internal", remotePort: 5432),
      NativeSSHLocalTunnelConfiguration(localPort: 15432, remoteHost: "host:3306", remotePort: 5432),
      NativeSSHLocalTunnelConfiguration(localPort: 15432, remoteHost: "db.internal", remotePort: 0),
      NativeSSHLocalTunnelConfiguration(localPort: 15432, remoteHost: "db.internal", remotePort: 65536),
    ]
    for badConfiguration in badConfigurations {
      XCTAssertThrowsError(try NativeSSHSession.validate(localTunnel: badConfiguration))
    }
  }

  // MARK: - Lifecycle and Fixture Tests

  func testLocalTunnelForwardsEchoAndClosesWithExplicitStopAndOwnerSession() throws {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["MRW_NATIVE_SSH_HOST"],
          let sshPort = env["MRW_NATIVE_SSH_PORT"].flatMap(Int.init),
          let username = env["MRW_NATIVE_SSH_USER"],
          let targetPort = env["MRW_NATIVE_TUNNEL_TARGET_PORT"].flatMap(Int.init),
          let root = env["MRW_NATIVE_FIXTURE_ROOT"] else {
      throw XCTSkip("MRW_NATIVE_SSH tunnel fixture environment not configured; skipping forwarding test.")
    }

    let rootURL = URL(fileURLWithPath: root, isDirectory: true)
    let config = NativeSSHConfiguration(
      host: host,
      port: sshPort,
      username: username,
      knownHostsFileURL: rootURL.appendingPathComponent("known_hosts"),
      authentication: .agent(socketURL: URL(fileURLWithPath: env["MRW_NATIVE_AGENT_SOCK"] ?? ""))
    )
    let session = NativeSSHSession(configuration: config)
    let serverLogURL = rootURL.appendingPathComponent("sshd.log")
    let ownerAuthOffset = try Data(contentsOf: serverLogURL).count
    try session.start()
    try waitForLogMessage("Accepted publickey", in: serverLogURL, after: ownerAuthOffset)

    let knownHostsURL = rootURL.appendingPathComponent("known_hosts")
    let trustedKnownHosts = try Data(contentsOf: knownHostsURL)
    defer { try? trustedKnownHosts.write(to: knownHostsURL) }
    let initialServerLog = try Data(contentsOf: serverLogURL)
    let initialServerLogSize = initialServerLog.count

    // A tunnel connection must independently enforce the owner's pinned known_hosts file.
    try Data(contentsOf: rootURL.appendingPathComponent("wrong_known_hosts")).write(to: knownHostsURL)
    let mismatchExpectation = expectation(description: "Tunnel rejects changed SSH host key")
    let mismatchPort = try unusedLoopbackPort()
    let mismatchedTunnel = try session.startLocalTunnel(
      configuration: NativeSSHLocalTunnelConfiguration(
        localPort: mismatchPort,
        remoteHost: "127.0.0.1",
        remotePort: targetPort
      ),
      onStateChange: { state in
        if case .failed = state {
          mismatchExpectation.fulfill()
        }
      }
    )
    wait(for: [mismatchExpectation], timeout: 5)
    XCTAssertEqual(mismatchedTunnel.state, .failed(exitCode: 255))
    let serverLogAfterMismatch = try Data(contentsOf: serverLogURL)
    let mismatchLog = String(decoding: serverLogAfterMismatch.dropFirst(initialServerLogSize), as: UTF8.self)
    XCTAssertFalse(mismatchLog.contains("userauth-request"), "Host-key mismatch must reject tunnel authentication")
    XCTAssertTrue(session.stopLocalTunnel(id: mismatchedTunnel.id))
    try trustedKnownHosts.write(to: knownHostsURL)

    let (occupiedDescriptor, occupiedPort) = try makeLoopbackListener()
    defer { Darwin.close(occupiedDescriptor) }
    let conflictExpectation = expectation(description: "OpenSSH refuses a tunnel port already in use")
    let conflictTunnel = try session.startLocalTunnel(
      configuration: NativeSSHLocalTunnelConfiguration(
        localPort: occupiedPort,
        remoteHost: "127.0.0.1",
        remotePort: targetPort
      ),
      onStateChange: { state in
        if case .failed = state {
          conflictExpectation.fulfill()
        }
      }
    )
    wait(for: [conflictExpectation], timeout: 5)
    XCTAssertEqual(conflictTunnel.state, .failed(exitCode: 255))
    XCTAssertTrue(canConnectToLoopbackPort(occupiedPort), "The existing listener must remain owned by its original process")
    XCTAssertTrue(session.stopLocalTunnel(id: conflictTunnel.id))

    let explicitPort = try unusedLoopbackPort()
    let explicitTunnel = try session.startLocalTunnel(
      configuration: NativeSSHLocalTunnelConfiguration(
        localPort: explicitPort,
        remoteHost: "127.0.0.1",
        remotePort: targetPort
      )
    )
    XCTAssertEqual(explicitTunnel.state, .running)
    XCTAssertEqual(try waitForEcho(port: explicitPort, payload: Data("explicit-stop".utf8)), Data("explicit-stop".utf8))

    XCTAssertTrue(session.stopLocalTunnel(id: explicitTunnel.id))
    XCTAssertEqual(explicitTunnel.state, .stopped)
    XCTAssertFalse(canConnectToLoopbackPort(explicitPort), "Explicit stop must close the loopback listener")

    let ownerPort = try unusedLoopbackPort()
    let ownerTunnel = try session.startLocalTunnel(
      configuration: NativeSSHLocalTunnelConfiguration(
        localPort: ownerPort,
        remoteHost: "127.0.0.1",
        remotePort: targetPort
      )
    )
    XCTAssertEqual(try waitForEcho(port: ownerPort, payload: Data("owner-shutdown".utf8)), Data("owner-shutdown".utf8))

    session.close()
    XCTAssertEqual(ownerTunnel.state, .stopped)
    XCTAssertFalse(canConnectToLoopbackPort(ownerPort), "Owner session teardown must close its tunnel listener")
  }

  private func unusedLoopbackPort() throws -> Int {
    let (descriptor, port) = try makeLoopbackListener()
    Darwin.close(descriptor)
    return port
  }

  private func makeLoopbackListener() throws -> (Int32, Int) {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw NativeSSHError.systemCallFailed("socket", errno) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else {
      Darwin.close(descriptor)
      throw NativeSSHError.systemCallFailed("bind", errno)
    }
    guard listen(descriptor, 1) == 0 else {
      let code = errno
      Darwin.close(descriptor)
      throw NativeSSHError.systemCallFailed("listen", code)
    }

    var boundAddress = sockaddr_in()
    var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(descriptor, $0, &addressLength)
      }
    }
    guard nameResult == 0 else {
      let code = errno
      Darwin.close(descriptor)
      throw NativeSSHError.systemCallFailed("getsockname", code)
    }
    return (descriptor, Int(UInt16(bigEndian: boundAddress.sin_port)))
  }

  private func waitForEcho(port: Int, payload: Data) throws -> Data {
    let deadline = Date().addingTimeInterval(8)
    var lastError: Error = NativeSSHError.operationTimedOut
    while Date() < deadline {
      do {
        return try echoThroughLoopbackPort(port, payload: payload)
      } catch {
        lastError = error
        Thread.sleep(forTimeInterval: 0.05)
      }
    }
    throw lastError
  }

  private func waitForLogMessage(_ message: String, in fileURL: URL, after offset: Int) throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      let data = try Data(contentsOf: fileURL)
      let suffix = String(decoding: data.dropFirst(min(offset, data.count)), as: UTF8.self)
      if suffix.contains(message) { return }
      Thread.sleep(forTimeInterval: 0.05)
    }
    throw NativeSSHError.operationTimedOut
  }

  private func echoThroughLoopbackPort(_ port: Int, payload: Data) throws -> Data {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw NativeSSHError.systemCallFailed("socket", errno) }
    defer { Darwin.close(descriptor) }

    var noSignal: Int32 = 1
    _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let connectResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard connectResult == 0 else { throw NativeSSHError.systemCallFailed("connect", errno) }

    let bytesSent = payload.withUnsafeBytes { rawBuffer -> Int in
      guard let baseAddress = rawBuffer.baseAddress else { return 0 }
      return Darwin.send(descriptor, baseAddress, rawBuffer.count, 0)
    }
    guard bytesSent == payload.count else { throw NativeSSHError.systemCallFailed("send", errno) }

    var response = Data(count: payload.count)
    let bytesReceived = response.withUnsafeMutableBytes { rawBuffer -> Int in
      guard let baseAddress = rawBuffer.baseAddress else { return 0 }
      return Darwin.recv(descriptor, baseAddress, rawBuffer.count, 0)
    }
    guard bytesReceived == payload.count else { throw NativeSSHError.systemCallFailed("recv", errno) }
    return response
  }

  private func canConnectToLoopbackPort(_ port: Int) -> Bool {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    return withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
    }
  }

  func testSessionLifecycleWithDisposableFixtureIfAvailable() throws {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["MRW_NATIVE_SSH_HOST"],
          let port = env["MRW_NATIVE_SSH_PORT"].flatMap(Int.init),
          let username = env["MRW_NATIVE_SSH_USER"],
          let root = env["MRW_NATIVE_FIXTURE_ROOT"] else {
      throw XCTSkip("MRW_NATIVE_SSH fixture environment not configured; skipping lifecycle tests.")
    }

    let rootURL = URL(fileURLWithPath: root, isDirectory: true)
    let knownHostsURL = rootURL.appendingPathComponent("known_hosts")
    let emptyKnownHostsURL = rootURL.appendingPathComponent("empty_known_hosts")
    let wrongKnownHostsURL = rootURL.appendingPathComponent("wrong_known_hosts")
    let agentSockPath = env["MRW_NATIVE_AGENT_SOCK"] ?? ""
    let agentSocketURL = URL(fileURLWithPath: agentSockPath)

    // 1. Negative Test: Unknown host key must fail with status 255 and reject connection before authentication
    try Data().write(to: emptyKnownHostsURL)
    let unknownConfig = NativeSSHConfiguration(
      host: host,
      port: port,
      username: username,
      knownHostsFileURL: emptyKnownHostsURL,
      authentication: .agent(socketURL: agentSocketURL)
    )

    let serverLogURL = rootURL.appendingPathComponent("sshd.log")
    let serverLogOffset: () throws -> UInt64 = {
      guard FileManager.default.fileExists(atPath: serverLogURL.path) else {
        XCTFail("Server log file missing at \(serverLogURL.path)")
        throw NativeSSHError.connectionFailed(details: "Missing server log")
      }
      let attrs = try FileManager.default.attributesOfItem(atPath: serverLogURL.path)
      guard let size = attrs[.size] as? NSNumber else {
        XCTFail("Could not determine size of server log")
        throw NativeSSHError.connectionFailed(details: "Cannot stat server log")
      }
      return size.uint64Value
    }
    let assertNoAuthSince: (UInt64) -> Void = { offset in
      guard FileManager.default.fileExists(atPath: serverLogURL.path),
            let data = try? Data(contentsOf: serverLogURL) else {
        XCTFail("Server log unreadable or missing for assertNoAuthSince")
        return
      }
      let start = min(Int(offset), data.count)
      let suffix = String(decoding: data.dropFirst(start), as: UTF8.self)
      XCTAssertFalse(suffix.contains("userauth-request"), "Server saw userauth-request on rejected host key")
      XCTAssertFalse(suffix.contains("Accepted publickey"), "Server accepted key on rejected host key")
    }

    let unknownLogOffset = try serverLogOffset()
    let unknownExitExpectation = expectation(description: "Unknown host key session disconnects")
    let testUnknownSession = NativeSSHSession(configuration: unknownConfig)
    testUnknownSession.onStateChange = { state in
      if case .disconnected(let code) = state {
        XCTAssertEqual(code, 255)
        unknownExitExpectation.fulfill()
      }
    }
    try testUnknownSession.start()
    wait(for: [unknownExitExpectation], timeout: 5)
    testUnknownSession.close()
    assertNoAuthSince(unknownLogOffset)

    // 2. Negative Test: Mismatched host key must fail with status 255 and reject connection before authentication
    let mismatchLogOffset = try serverLogOffset()
    let wrongConfig = NativeSSHConfiguration(
      host: host,
      port: port,
      username: username,
      knownHostsFileURL: wrongKnownHostsURL,
      authentication: .agent(socketURL: agentSocketURL)
    )
    let wrongSession = NativeSSHSession(configuration: wrongConfig)
    let wrongExitExpectation = expectation(description: "Mismatched host key session disconnects")
    wrongSession.onStateChange = { state in
      if case .disconnected(let code) = state {
        XCTAssertEqual(code, 255)
        wrongExitExpectation.fulfill()
      }
    }
    try wrongSession.start()
    wait(for: [wrongExitExpectation], timeout: 5)
    wrongSession.close()
    assertNoAuthSince(mismatchLogOffset)

    // 3. Positive Test: Strict trusted host connects, receives remote-generated sentinel, resizes to 40x120, verifies remote stty, server log accepted publickey, and cleanly closes
    let positiveLogOffset = try serverLogOffset()
    let trustedConfig = NativeSSHConfiguration(
      host: host,
      port: port,
      username: username,
      knownHostsFileURL: knownHostsURL,
      authentication: .agent(socketURL: agentSocketURL),
      initialTerminalSize: NativeSSHTerminalSize(rows: 24, columns: 80)
    )
    let trustedSession = NativeSSHSession(configuration: trustedConfig)

    final class OutputAccumulator: @unchecked Sendable {
      var data = Data()
      let lock = NSLock()

      func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
      }

      var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
      }
    }

    let accumulator = OutputAccumulator()
    let sentinelExpectation = expectation(description: "Received remote sentinel NOT matching literal input")
    sentinelExpectation.assertForOverFulfill = false

    let sttyExpectation = expectation(description: "Received remote stty size output verifying 40 120")
    sttyExpectation.assertForOverFulfill = false

    trustedSession.onOutput = { data in
      accumulator.append(data)
      let currentText = accumulator.text
      if currentText.contains("SENTINEL_REMOTE_VERIFIED") {
        sentinelExpectation.fulfill()
      }
      if currentText.contains("STTY_SIZE: 40 120") {
        sttyExpectation.fulfill()
      }
    }

    try trustedSession.start()

    // Command uses printf with split pieces so the literal string 'SENTINEL_REMOTE_VERIFIED' never appears in input or local echo
    try trustedSession.write(string: "printf '%s_%s\\n' 'SENTINEL' 'REMOTE_VERIFIED'\n")
    wait(for: [sentinelExpectation], timeout: 5)

    // Resize terminal to 40 rows and 120 columns
    XCTAssertNoThrow(try trustedSession.resize(rows: 40, columns: 120))

    // Query remote terminal dimensions using stty
    try trustedSession.write(string: "echo STTY_SIZE: $(stty size)\n")
    wait(for: [sttyExpectation], timeout: 5)

    // Verify sshd server log recorded 'Accepted publickey' for this session
    guard let postSessionLog = try? Data(contentsOf: serverLogURL) else {
      XCTFail("Server log missing after session")
      return
    }
    let postSessionText = String(decoding: postSessionLog.dropFirst(Int(positiveLogOffset)), as: UTF8.self)
    XCTAssertTrue(postSessionText.contains("Accepted publickey"), "Server log did not contain 'Accepted publickey' for authenticated session")

    // Close session gracefully
    trustedSession.close()
    XCTAssertEqual(trustedSession.state, .disconnected(exitCode: nil))
  }

  // MARK: - Deterministic Lifecycle & Concurrency Regression Tests

  private final class ThreadSafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
      lock.lock()
      defer { lock.unlock() }
      value += 1
    }

    var count: Int {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
  }

  private final class ThreadSafeStateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [NativeSSHSessionState] = []

    func append(_ state: NativeSSHSessionState) {
      lock.lock()
      defer { lock.unlock() }
      states.append(state)
    }

    var last: NativeSSHSessionState? {
      lock.lock()
      defer { lock.unlock() }
      return states.last
    }
  }

  func testCloseBeforeStartPreventsProcessOrPTYLeak() throws {
    let dummyFile = URL(fileURLWithPath: "/dev/null")
    let config = NativeSSHConfiguration(
      host: "127.0.0.1",
      port: 22,
      username: "user",
      knownHostsFileURL: dummyFile,
      authentication: .identityFile(dummyFile)
    )

    let session = NativeSSHSession(configuration: config)
    session.close()

    XCTAssertEqual(session.state, .disconnected(exitCode: nil))
    XCTAssertThrowsError(try session.start()) { error in
      XCTAssertEqual(error as? NativeSSHError, NativeSSHError.sessionAlreadyRunning)
    }
  }

  func testConcurrentStartsOnlyOneSucceeds() throws {
    let dummyFile = URL(fileURLWithPath: "/dev/null")
    let config = NativeSSHConfiguration(
      host: "127.0.0.1",
      port: 22,
      username: "user",
      knownHostsFileURL: dummyFile,
      authentication: .identityFile(dummyFile)
    )

    let session = NativeSSHSession(configuration: config)

    let group = DispatchGroup()
    let queue = DispatchQueue(label: "test.concurrent.starts", attributes: .concurrent)
    let successCounter = ThreadSafeCounter()
    let errorCounter = ThreadSafeCounter()

    for _ in 0..<10 {
      group.enter()
      queue.async {
        do {
          try session.start()
          successCounter.increment()
        } catch {
          errorCounter.increment()
        }
        group.leave()
      }
    }

    _ = group.wait(timeout: .now() + 5)
    session.close()

    // At most 1 attempt can ever initiate startup
    XCTAssertEqual(successCounter.count, 1)
    XCTAssertEqual(errorCounter.count, 9)
  }

  func testCloseDuringOrImmediatelyAfterStartCleansUpDeterministically() throws {
    let dummyFile = URL(fileURLWithPath: "/dev/null")
    let config = NativeSSHConfiguration(
      host: "127.0.0.1",
      port: 22,
      username: "user",
      knownHostsFileURL: dummyFile,
      authentication: .identityFile(dummyFile)
    )

    for _ in 0..<20 {
      let session = NativeSSHSession(configuration: config)
      let group = DispatchGroup()

      group.enter()
      DispatchQueue.global().async {
        _ = try? session.start()
        group.leave()
      }

      group.enter()
      DispatchQueue.global().async {
        session.close()
        group.leave()
      }

      XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

      session.close() // Idempotent close
      if case .disconnected = session.state {
        // Success
      } else {
        XCTFail("Session state should be disconnected after close, got \(session.state)")
      }

      // I/O operations must be rejected once closed
      XCTAssertThrowsError(try session.write(string: "test\n")) { error in
        XCTAssertEqual(error as? NativeSSHError, NativeSSHError.sessionNotRunning)
      }
      XCTAssertThrowsError(try session.resize(rows: 30, columns: 90)) { error in
        XCTAssertEqual(error as? NativeSSHError, NativeSSHError.sessionNotRunning)
      }
    }
  }

  func testImmediateTerminationDoesNotRestoreRunningState() throws {
    // When process terminates immediately with an error (e.g. invalid key or connection refused)
    let dummyFile = URL(fileURLWithPath: "/dev/null")
    // Using a closed port on loopback to cause rapid exit
    let config = NativeSSHConfiguration(
      host: "127.0.0.1",
      port: 1, // port 1 should refuse connection immediately
      username: "user",
      knownHostsFileURL: dummyFile,
      authentication: .identityFile(dummyFile)
    )

    let session = NativeSSHSession(configuration: config)
    let disconnectedExpectation = expectation(description: "Session transitions to disconnected")
    let stateCollector = ThreadSafeStateCollector()

    session.onStateChange = { state in
      stateCollector.append(state)
      if case .disconnected = state {
        disconnectedExpectation.fulfill()
      }
    }

    try session.start()
    wait(for: [disconnectedExpectation], timeout: 5)

    // Ensure session state remains disconnected
    XCTAssertEqual(session.state, .disconnected(exitCode: 255))
    session.close()
    XCTAssertEqual(session.state, .disconnected(exitCode: 255))

    // State after termination must never bounce back to running
    XCTAssertEqual(stateCollector.last, .disconnected(exitCode: 255))
  }
}
