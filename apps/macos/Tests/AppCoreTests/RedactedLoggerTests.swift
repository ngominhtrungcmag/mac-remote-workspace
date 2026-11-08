import Foundation
import XCTest
@testable import AppCore

final class RedactedLoggerTests: XCTestCase {
  private var tempDir: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("mrw-logger-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let dir = tempDir {
      try? FileManager.default.removeItem(at: dir)
    }
    try super.tearDownWithError()
  }

  // MARK: - Redaction Engine Unit Tests (TC-018 / FR-013)

  func testRedactPrivateKeyPEMBlock() {
    let raw = """
    Loaded identity key from file:
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACD7V/8f6P1...
    -----END OPENSSH PRIVATE KEY-----
    Continuing handshake.
    """

    let sanitized = RedactedLogger.redact(raw)
    XCTAssertFalse(sanitized.contains("b3BlbnNzaC1rZXktdjE"))
    XCTAssertFalse(sanitized.contains("-----BEGIN OPENSSH PRIVATE KEY-----"))
    XCTAssertTrue(sanitized.contains("[REDACTED PRIVATE KEY]"))
    XCTAssertTrue(sanitized.contains("Loaded identity key from file:"))
    XCTAssertTrue(sanitized.contains("Continuing handshake."))
  }

  func testRedactPasswordsAndPassphrases() {
    let testCases = [
      ("Authentication payload: password=SecretPassphrase123! end", "password=[REDACTED]"),
      ("Failed login with passphrase: 'MyKeyPassphrase' for key", "passphrase=[REDACTED]"),
      ("Connecting token=ghp_ABC123456789XYZ to API", "token=[REDACTED]"),
      ("auth_token: sk_live_999999", "auth_token=[REDACTED]"),
    ]

    for (raw, expectedToken) in testCases {
      let sanitized = RedactedLogger.redact(raw)
      XCTAssertTrue(sanitized.contains(expectedToken), "Failed for raw string: '\(raw)'")
      XCTAssertFalse(sanitized.contains("SecretPassphrase123!"))
      XCTAssertFalse(sanitized.contains("MyKeyPassphrase"))
      XCTAssertFalse(sanitized.contains("ghp_ABC123456789XYZ"))
      XCTAssertFalse(sanitized.contains("sk_live_999999"))
    }
  }

  func testRedactBasicAuthInURLs() {
    let url = "Connecting upstream: https://deployer:P@ssw0rd99@internal.gateway.net:8443/v1"
    let sanitized = RedactedLogger.redact(url)
    XCTAssertTrue(sanitized.contains("https://[REDACTED]@internal.gateway.net:8443/v1"))
    XCTAssertFalse(sanitized.contains("P@ssw0rd99"))
    XCTAssertFalse(sanitized.contains("deployer"))
  }

  func testRedactBearerTokens() {
    let authHeader = "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.sig"
    let sanitized = RedactedLogger.redact(authHeader)
    XCTAssertTrue(sanitized.contains("Authorization: Bearer [REDACTED]"))
    XCTAssertFalse(sanitized.contains("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"))
  }

  // MARK: - Diagnostics Bundle Report Tests (US-007 / TC-018)

  func testGenerateDiagnosticsReportContainsEnvironmentAndZeroSecrets() throws {
    let dbURL = tempDir.appendingPathComponent("metadata.sqlite")
    let repo = try SQLiteHostRepository(databaseURL: dbURL)

    // Populate a test host
    let ws = try repo.createWorkspace(name: "Diagnostics Workspace")
    _ = try repo.createHost(HostDraft(
      displayName: "Diag Server",
      address: "diag.internal",
      environment: .staging,
      workspaceID: ws.id
    ))

    // Log a sensitive event to shared logger
    RedactedLogger.shared.info("SSH", "Connecting with password=UnredactedSecret123 to server")

    let report = RedactedLogger.generateDiagnosticsReport(repository: repo, knownHostsCount: 5)

    // Verify report sections
    XCTAssertTrue(report.contains("# Mac Remote Workspace — Diagnostics Report"))
    XCTAssertTrue(report.contains("OS: macOS"))
    XCTAssertTrue(report.contains("Total Configured Hosts: 1"))
    XCTAssertTrue(report.contains("Pinned Known Hosts: 5"))
    XCTAssertTrue(report.contains("StrictHostKeyChecking: Enforced"))

    // Strictly verify no secret canary in report
    XCTAssertFalse(report.contains("UnredactedSecret123"))
    XCTAssertTrue(report.contains("password=[REDACTED]"))

    try repo.close()
  }

  // MARK: - File Logging & Permissions (NFR-009)

  func testLoggerWritesWithStrictPermissions() throws {
    let customDir = tempDir.appendingPathComponent("logs")
    let logger = RedactedLogger(customLogDirectory: customDir)

    logger.info("TestCategory", "Application initialized successfully.")

    logger.flush()
    let logFile = customDir.appendingPathComponent("mrw.log")
    XCTAssertTrue(FileManager.default.fileExists(atPath: logFile.path))

    let content = try String(contentsOf: logFile, encoding: .utf8)
    XCTAssertTrue(content.contains("[INFO] [TestCategory] Application initialized successfully."))

    let attrs = try FileManager.default.attributesOfItem(atPath: logFile.path)
    let permissions = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
    XCTAssertEqual(permissions & 0o777, 0o600, "Log file must have 0600 permissions")
  }
  func testRotationPreservesPreviousLog() throws {
    let dir = tempDir.appendingPathComponent("rotation")
    let logger = RedactedLogger(customLogDirectory: dir)
    let log = dir.appendingPathComponent("mrw.log")
    try Data(repeating: 65, count: 10 * 1024 * 1024 + 1).write(to: log)
    logger.info("test", "new entry")
    logger.flush()
    XCTAssertEqual(try Data(contentsOf: log.appendingPathExtension("1")).count, 10 * 1024 * 1024 + 1)
    XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("new entry"))
  }

}
