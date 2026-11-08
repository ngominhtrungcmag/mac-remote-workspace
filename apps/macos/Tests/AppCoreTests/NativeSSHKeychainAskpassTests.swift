import Foundation
import XCTest
@testable import AppCore

/// Verifies that Keychain-backed SSH authentication never places secret
/// values into argv, environment, files, or the PTY (US-008 / FR-005 /
/// SEC-T03 / TC-006 negative surfaces).
final class NativeSSHKeychainAskpassTests: XCTestCase {
  private let dummyKnownHosts = URL(fileURLWithPath: "/dev/null")

  private func askpassConfiguration(
    service: String = "com.macremoteworkspace.tests.credentials",
    account: String = "70ED860A-6D32-4326-9D42-B6E5B2E9411C",
    identityFile: URL? = nil
  ) -> NativeSSHConfiguration {
    NativeSSHConfiguration(
      host: "127.0.0.1",
      port: 22,
      username: "fixture-user",
      knownHostsFileURL: dummyKnownHosts,
      authentication: .keychainAskpass(
        service: service, account: account, identityFile: identityFile)
    )
  }

  func testAskpassArgumentsAreStrictWithoutBatchMode() {
    let arguments = NativeSSHSession.buildSSHArguments(for: askpassConfiguration())
    let joined = arguments.joined(separator: " ")

    XCTAssertFalse(arguments.contains("BatchMode=yes"), "BatchMode would suppress the askpass interaction.")
    XCTAssertTrue(joined.contains("StrictHostKeyChecking=yes"), "Host trust stays strict for credential auth.")
    XCTAssertTrue(joined.contains("UserKnownHostsFile=\(dummyKnownHosts.path)"))
    XCTAssertTrue(joined.contains("GlobalKnownHostsFile=/dev/null"))
    XCTAssertTrue(joined.contains("UpdateHostKeys=no"))
    XCTAssertTrue(joined.contains("CheckHostIP=no"))
    XCTAssertTrue(joined.contains("PasswordAuthentication=yes"))
    XCTAssertTrue(joined.contains("KbdInteractiveAuthentication=yes"))
    XCTAssertTrue(joined.contains("NumberOfPasswordPrompts=1"), "Only one prompt attempt is allowed.")
    XCTAssertTrue(joined.contains("IdentityAgent=none"))
  }

  func testAskpassMetadataReferenceDoesNotLeakIntoArgv() {
    let service = "com.macremoteworkspace.tests.credentials"
    let account = "70ED860A-6D32-4326-9D42-B6E5B2E9411C"
    let arguments = NativeSSHSession.buildSSHArguments(
      for: askpassConfiguration(service: service, account: account)
    )
    let joined = arguments.joined(separator: " ")
    // The metadata reference travels in the child process environment, not argv.
    XCTAssertFalse(joined.contains(service), "Reference metadata must stay out of argv.")
    XCTAssertFalse(joined.contains(account), "Reference metadata must stay out of argv.")
    XCTAssertFalse(joined.contains("SSH_ASKPASS"), "No environment configuration may leak into argv.")
  }

  func testAskpassConfigurationValidationStillGuardsHostnameAndTrust() {
    var configuration = askpassConfiguration()
    configuration = NativeSSHConfiguration(
      host: "-oProxyCommand=evil",
      port: 22,
      username: "fixture-user",
      knownHostsFileURL: dummyKnownHosts,
      authentication: .keychainAskpass(
        service: "com.macremoteworkspace.tests.credentials",
        account: "70ED860A-6D32-4326-9D42-B6E5B2E9411C",
        identityFile: nil)
    )
    XCTAssertThrowsError(try NativeSSHSession.validate(configuration: configuration)) { error in
      guard case NativeSSHError.invalidHost = error else {
        XCTFail("Expected invalidHost but got \(error)")
        return
      }
    }

    let badReference = NativeSSHConfiguration(
      host: "127.0.0.1",
      port: 22,
      username: "fixture-user",
      knownHostsFileURL: dummyKnownHosts,
      authentication: .keychainAskpass(service: "svc", account: "", identityFile: nil)
    )
    XCTAssertThrowsError(try NativeSSHSession.validate(configuration: badReference)) { error in
      guard case NativeSSHError.invalidAskpassReference = error else {
        XCTFail("Expected invalidAskpassReference but got \(error)")
        return
      }
    }
  }

  func testHelperDeliversSecretOnceThroughPrivateFIFO() throws {
    let secret = "askpass-canary"
    let helper = try KeychainAskpassHelper.install(secret: ProtectedSecret(bytes: Array(secret.utf8)))
    defer { helper.cleanup() }
    let environment = helper.childEnvironment(for: .keychainAskpass(service: "svc", account: "a", identityFile: nil))
    let script = try XCTUnwrap(environment["SSH_ASKPASS"])
    let fifo = try XCTUnwrap(environment["MRW_ASKPASS_FIFO"])
    XCTAssertFalse(environment.values.contains { $0.contains(secret) })
    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: fifo)[.posixPermissions] as? NSNumber)?.uint32Value, 0o600)
    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: script)[.posixPermissions] as? NSNumber)?.uint32Value, 0o700)
    XCTAssertEqual(KeychainAskpassHelper.scriptContents, "#!/bin/sh\nexec /bin/cat \"$MRW_ASKPASS_FIFO\"")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: script)
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    XCTAssertEqual(String(data: data, encoding: .utf8), secret)
    XCTAssertEqual(process.terminationStatus, 0)
    helper.cleanup()
    XCTAssertFalse(FileManager.default.fileExists(atPath: script))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fifo))
  }

  func testSecretIsNotReadWithoutAnAskpassReader() throws {
    final class ReadCounter: @unchecked Sendable {
      let lock = NSLock()
      var value = 0
      func increment() { lock.lock(); value += 1; lock.unlock() }
      func count() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    }
    let counter = ReadCounter()
    let helper = try KeychainAskpassHelper.install(readSecret: {
      counter.increment()
      return ProtectedSecret(bytes: [1])
    })
    helper.cleanup()
    XCTAssertEqual(counter.count(), 0)
  }

  func testCancelledBeforeTrustDoesNotInstallAskpass() {
    XCTAssertThrowsError(try KeychainAskpassHelper.install(for: askpassConfiguration(), isCancelled: { true }))
  }

  func testHelperCleanupWithoutReaderIsIdempotent() throws {
    let helper = try KeychainAskpassHelper.install(secret: ProtectedSecret(bytes: [1]))
    let env = helper.childEnvironment(for: .keychainAskpass(service: "svc", account: "a", identityFile: nil))
    helper.cleanup()
    helper.cleanup()
    XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(env["MRW_ASKPASS_FIFO"])))
  }

  func testProxyJumpRejectsCredentialAuthAndKeepsAgentStrict() throws {
    XCTAssertThrowsError(try NativeSSHProxyJumpConfigurationFile.contents(
      jump: NativeSSHProxyJumpEndpoint(host: "127.0.0.1", port: 2222, username: "jump-user"),
      knownHostsFileURL: dummyKnownHosts,
      authentication: .keychainAskpass(
        service: "com.macremoteworkspace.tests.credentials",
        account: "70ED860A-6D32-4326-9D42-B6E5B2E9411C",
        identityFile: nil),
      alias: "_mrw_jump_test"
    )) { error in
      XCTAssertTrue(error.localizedDescription.contains("ProxyJump requires SSH agent"))
    }

    let strictContents = try NativeSSHProxyJumpConfigurationFile.contents(
      jump: NativeSSHProxyJumpEndpoint(host: "127.0.0.1", port: 2222, username: "jump-user"),
      knownHostsFileURL: dummyKnownHosts,
      authentication: .agent(socketURL: dummyKnownHosts),
      alias: "_mrw_jump_test"
    )
    XCTAssertTrue(strictContents.contains("StrictHostKeyChecking yes"))
    XCTAssertTrue(strictContents.contains("BatchMode yes"))
    XCTAssertTrue(strictContents.contains("PasswordAuthentication no"))
  }

  // MARK: - Disposable fixture (TC-006 password/key-passphrase surfaces)

  func testEncryptedKeyPassphraseAuthenticatesThroughKeychainAskpass() throws {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["MRW_NATIVE_SSH_HOST"],
      let port = env["MRW_NATIVE_SSH_PORT"].flatMap(Int.init),
      let username = env["MRW_NATIVE_SSH_USER"],
      let root = env["MRW_NATIVE_FIXTURE_ROOT"],
      let encryptedKeyPath = env["MRW_NATIVE_ENC_KEY"],
      let askpassAccount = env["MRW_NATIVE_ASKPASS_ACCOUNT"]
    else {
      throw XCTSkip("MRW_NATIVE_SSH keychain-askpass fixture environment not configured; skipping.")
    }

    let knownHostsURL = URL(fileURLWithPath: root, isDirectory: true)
      .appendingPathComponent("known_hosts")
    let config = NativeSSHConfiguration(
      host: host,
      port: port,
      username: username,
      knownHostsFileURL: knownHostsURL,
      authentication: .keychainAskpass(
        service: "com.macremoteworkspace.tests.credentials",
        account: askpassAccount,
        identityFile: URL(fileURLWithPath: encryptedKeyPath)
      )
    )

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

    let session = NativeSSHSession(configuration: config)
    defer { session.close() }

    let runningExpectation = expectation(description: "Session reached .running")
    let sentinel = "PASSPHRASE_ASKPASS_OK"
    let sentinelExpectation = expectation(description: "Echoed remote sentinel")
    sentinelExpectation.assertForOverFulfill = false

    let accumulator = OutputAccumulator()
    session.onOutput = { data in
      accumulator.append(data)
      if accumulator.text.contains(sentinel) {
        sentinelExpectation.fulfill()
      }
    }
    session.onStateChange = { state in
      if case .running = state {
        runningExpectation.fulfill()
      }
      if case .disconnected = state {
        sentinelExpectation.fulfill()
      }
    }

    try session.start()
    wait(for: [runningExpectation], timeout: 10)
    guard case .running = session.state else {
      return XCTFail("Askpass passphrase session never reached .running; state \(session.state)")
    }
    try session.write(string: "echo \(sentinel)\n", timeout: 5)
    wait(for: [sentinelExpectation], timeout: 8)
    XCTAssertTrue(accumulator.text.contains(sentinel), "Expected remote echo of the sentinel.")
    XCTAssertEqual(session.state, .running)
  }

  func testMissingKeychainCredentialFailsWithoutAuthenticationSuccess() throws {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["MRW_NATIVE_SSH_HOST"],
      let port = env["MRW_NATIVE_SSH_PORT"].flatMap(Int.init),
      let username = env["MRW_NATIVE_SSH_USER"],
      let root = env["MRW_NATIVE_FIXTURE_ROOT"],
      let encryptedKeyPath = env["MRW_NATIVE_ENC_KEY"]
    else {
      throw XCTSkip("MRW_NATIVE_SSH keychain-askpass fixture environment not configured; skipping.")
    }

    let knownHostsURL = URL(fileURLWithPath: root, isDirectory: true)
      .appendingPathComponent("known_hosts")
    let config = NativeSSHConfiguration(
      host: host,
      port: port,
      username: username,
      knownHostsFileURL: knownHostsURL,
      authentication: .keychainAskpass(
        service: "com.macremoteworkspace.tests.credentials",
        // An account that was never registered in the Keychain.
        account: "missing-\(UUID().uuidString.lowercased())",
        identityFile: URL(fileURLWithPath: encryptedKeyPath)
      )
    )

    let disconnectExpectation = expectation(description: "Session disconnects for unknown credential")
    let session = NativeSSHSession(configuration: config)
    session.onStateChange = { state in
      if case .disconnected(let code) = state, code != nil { disconnectExpectation.fulfill() }
    }
    try session.start()
    wait(for: [disconnectExpectation], timeout: 12)
    XCTAssertEqual(session.state, .disconnected(exitCode: 255))
    session.close()
  }
}

extension NativeSSHSessionState {
  var isDisconnected: Bool {
    if case .disconnected = self { return true }
    return false
  }
}
