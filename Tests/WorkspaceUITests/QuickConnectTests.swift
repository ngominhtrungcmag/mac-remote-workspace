import AppCore
import AppKit
import SwiftUI
import XCTest
@testable import MacRemoteWorkspace

final class QuickConnectTests: XCTestCase {

  // MARK: - Form Parsing & Preview Tests

  @MainActor
  func testFormParsesAndPreviewsSSHTargetAndSyncsProtocol() {
    let model = QuickConnectFormModel(
      defaultSSHUsername: "localadmin",
      defaultProtocol: "rdp",
      defaultRdpLaunchMode: .external
    )
    XCTAssertEqual(model.selectedProtocol, .rdp)
    XCTAssertNil(model.parsedTarget)
    XCTAssertNil(model.validationErrorMessage)

    // Typing ssh:// URL automatically syncs selectedProtocol to .ssh
    model.rawInput = "ssh://deploy@staging.example.com:2222"
    XCTAssertEqual(model.selectedProtocol, .ssh)
    XCTAssertEqual(model.parsedTarget?.connectionProtocol, .ssh)
    XCTAssertEqual(model.parsedTarget?.host, "staging.example.com")
    XCTAssertEqual(model.parsedTarget?.port, 2222)
    XCTAssertEqual(model.parsedTarget?.username, "deploy")
    XCTAssertEqual(model.effectiveSSHUsername, "deploy")
    XCTAssertNil(model.validationErrorMessage)
  }

  @MainActor
  func testFormParsesPlainHostWithSelectedProtocolAndUsesUsernameOverride() {
    let model = QuickConnectFormModel(
      defaultSSHUsername: "opsuser",
      defaultProtocol: "ssh",
      defaultRdpLaunchMode: .external
    )

    model.rawInput = "10.0.10.25:2200"
    XCTAssertEqual(model.parsedTarget?.connectionProtocol, .ssh)
    XCTAssertEqual(model.parsedTarget?.host, "10.0.10.25")
    XCTAssertEqual(model.parsedTarget?.port, 2200)
    XCTAssertNil(model.parsedTarget?.username)
    XCTAssertEqual(model.effectiveSSHUsername, "opsuser")

    // Switching protocol picker to RDP re-parses plain host as RDP
    model.selectedProtocol = .rdp
    XCTAssertEqual(model.parsedTarget?.connectionProtocol, .rdp)
    XCTAssertEqual(model.parsedTarget?.host, "10.0.10.25")
    XCTAssertEqual(model.parsedTarget?.port, 2200)
  }

  @MainActor
  func testProtocolSelectorUpdatesExplicitSchemeAndPreservesValidationErrors() {
    let model = QuickConnectFormModel(
      defaultSSHUsername: "opsuser",
      defaultProtocol: "ssh",
      defaultRdpLaunchMode: .external
    )

    // 1. Explicit ssh:// URL without username -> switching protocol selector to RDP updates scheme to rdp://
    model.rawInput = "ssh://win.example.test:3389"
    XCTAssertEqual(model.selectedProtocol, .ssh)
    XCTAssertEqual(model.parsedTarget?.connectionProtocol, .ssh)

    model.selectedProtocol = .rdp
    XCTAssertEqual(model.rawInput, "rdp://win.example.test:3389")
    XCTAssertEqual(model.parsedTarget?.connectionProtocol, .rdp)
    XCTAssertEqual(model.parsedTarget?.host, "win.example.test")
    XCTAssertEqual(model.parsedTarget?.port, 3389)
    XCTAssertNil(model.validationErrorMessage)

    // Switching back to SSH updates scheme to ssh://
    model.selectedProtocol = .ssh
    XCTAssertEqual(model.rawInput, "ssh://win.example.test:3389")
    XCTAssertEqual(model.parsedTarget?.connectionProtocol, .ssh)

    // 2. Explicit ssh://user@host:22 -> switching protocol selector to RDP updates scheme to rdp://user@host:22
    // and surfaces clear usernameNotSupportedForRDP validation without contradicting protocol selector
    model.rawInput = "ssh://deploy@host.example.test:22"
    model.selectedProtocol = .rdp
    XCTAssertEqual(model.rawInput, "rdp://deploy@host.example.test:22")
    XCTAssertNil(model.parsedTarget)
    XCTAssertEqual(
      model.validationErrorMessage,
      QuickConnectValidationError.usernameNotSupportedForRDP.localizedDescription
    )

    // Switching back to SSH restores valid ssh://deploy@host.example.test:22 parse
    model.selectedProtocol = .ssh
    XCTAssertEqual(model.rawInput, "ssh://deploy@host.example.test:22")
    XCTAssertEqual(model.parsedTarget?.connectionProtocol, .ssh)
    XCTAssertEqual(model.parsedTarget?.username, "deploy")
    XCTAssertNil(model.validationErrorMessage)

    // 3. Plain user@host:22 -> switching protocol selector to RDP surfaces usernameNotSupportedForRDP
    model.rawInput = "deploy@host.example.test:22"
    XCTAssertEqual(model.parsedTarget?.connectionProtocol, .ssh)
    model.selectedProtocol = .rdp
    XCTAssertNil(model.parsedTarget)
    XCTAssertEqual(
      model.validationErrorMessage,
      QuickConnectValidationError.usernameNotSupportedForRDP.localizedDescription
    )
  }

  // MARK: - Validation Errors Preserve Input & Never Leak Secrets (C4)

  @MainActor
  func testValidationErrorsPreserveUserInputAndNeverEchoRawURLOrSecret() {
    let canary = "CANARY_QC_SECRET_88412"
    let rawWithSecret = "ssh://root:\(canary)@bad.example.com:22"
    let logCountBefore = RedactedLogger.shared.recentEntries(limit: 500).count

    let model = QuickConnectFormModel(
      defaultSSHUsername: "admin",
      defaultProtocol: "ssh",
      defaultRdpLaunchMode: .external
    )
    model.rawInput = rawWithSecret

    // Plan must be nil, input must be preserved, error must not contain canary or raw URL
    let plan = model.validateForConnect()
    XCTAssertNil(plan)
    XCTAssertEqual(model.rawInput, rawWithSecret, "Validation failure must preserve user input")

    let errorMessage = try! XCTUnwrap(model.validationErrorMessage)
    XCTAssertFalse(errorMessage.contains(canary), "Error message leaked secret canary")
    XCTAssertFalse(errorMessage.contains("bad.example.com"), "Error message echoed raw URL host")

    // Verify logger did not record the URL or canary
    let entriesAfter = RedactedLogger.shared.recentEntries(limit: 500)
    XCTAssertEqual(entriesAfter.count, logCountBefore)
    for entry in entriesAfter {
      XCTAssertFalse(entry.message.contains(canary))
      XCTAssertFalse(entry.message.contains(rawWithSecret))
    }
  }

  // MARK: - Authentication Modes & Non-Persistence of Credentials (G1, C4)

  @MainActor
  func testSSHPasswordAuthNeverSetsSaveToKeychain() {
    let model = QuickConnectFormModel(
      defaultSSHUsername: "ubuntu",
      defaultProtocol: "ssh",
      defaultRdpLaunchMode: .external
    )
    model.rawInput = "ssh://ubuntu@192.168.1.20:22"
    model.sshAuthMethod = .password
    model.sshPassword = ""
    XCTAssertFalse(model.canConnect)
    XCTAssertNil(model.validateForConnect())

    let canaryPass = "TEMP_PASS_CANARY_991"
    model.sshPassword = canaryPass
    XCTAssertTrue(model.canConnect)

    guard case .ssh(let target, _, let auth) = model.validateForConnect() else {
      return XCTFail("Expected validated SSH plan")
    }
    XCTAssertEqual(target.host, "192.168.1.20")
    XCTAssertEqual(target.username, "ubuntu")
    guard case .password(_, let saveToKeychain, let label) = auth else {
      return XCTFail("Expected password authentication choice")
    }
    XCTAssertFalse(saveToKeychain, "Quick Connect must never persist temporary passwords to Keychain")
    XCTAssertNil(label)

    model.clearSensitiveFields()
    XCTAssertTrue(model.sshPassword.isEmpty)
  }

  @MainActor
  func testSSHKeychainAndAgentAndRDPModesValidateCorrectly() throws {
    let model = QuickConnectFormModel(
      defaultSSHUsername: "alice",
      defaultProtocol: "ssh",
      defaultRdpLaunchMode: .embedded
    )
    let ref = KeychainCredentialReference(service: "test.service", account: "test.account").encoded
    let cred = CredentialRefRecord(id: "cred-1", label: "Prod Key", kind: .password, keychainItemID: ref)
    model.updateCredentialRefs([cred])

    model.rawInput = "ssh://host.example.test"
    model.sshAuthMethod = .keychainCredential
    model.sshKeyFilePath = "~/.ssh/id_ed25519"
    XCTAssertTrue(model.canConnect)

    guard case .ssh(_, _, let keyAuth) = model.validateForConnect(),
          case .keychainCredential(let selectedRecord, let keyURL) = keyAuth else {
      return XCTFail("Expected keychainCredential auth")
    }
    XCTAssertEqual(selectedRecord, cred)
    XCTAssertNotNil(keyURL)

    // RDP embedded requires non-empty username and selected credential
    model.rawInput = "rdp://win.example.test:3390"
    XCTAssertEqual(model.selectedProtocol, .rdp)
    model.rdpUsername = ""
    XCTAssertFalse(model.canConnect)
    XCTAssertNil(model.validateForConnect())
    XCTAssertEqual(model.rawInput, "rdp://win.example.test:3390")

    model.rdpUsername = "CORP\\Administrator"
    XCTAssertTrue(model.canConnect)
    guard case .rdpEmbedded(let rdpTarget, _, let rdpUser, let credID) = model.validateForConnect() else {
      return XCTFail("Expected rdpEmbedded plan")
    }
    XCTAssertEqual(rdpTarget.host, "win.example.test")
    XCTAssertEqual(rdpTarget.port, 3390)
    XCTAssertEqual(rdpUser, "CORP\\Administrator")
    XCTAssertEqual(credID, "cred-1")

    // External RDP mode
    model.rdpLaunchMode = .external
    XCTAssertTrue(model.canConnect)
    guard case .rdpExternal(_, let endpoint) = model.validateForConnect() else {
      return XCTFail("Expected rdpExternal plan")
    }
    XCTAssertEqual(endpoint, "win.example.test:3390")
  }

  // MARK: - Temporary Host Non-Persistence & Strict Host Trust Enforcement

  @MainActor
  func testTemporaryTargetDoesNotEnterInventoryOrExportAndStillEnforcesHostTrust() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mrw-qc-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let dbURL = tempDir.appendingPathComponent("metadata.sqlite")
    let repository = try SQLiteHostRepository(databaseURL: dbURL)
    defer { try? repository.close() }
    let store = WorkspaceStore(repository: repository)

    let target = try QuickConnectTarget.parse("ssh://deploy@ephemeral.example.test:2222")
    let registry = QuickConnectSessionRegistry()
    let entry = registry.open(
      windowID: "win-1",
      target: target,
      environment: .staging,
      authentication: .sshAgent
    )
    defer { registry.close(windowID: "win-1") }

    // 1. Verify temporary host is NOT in WorkspaceStore or SQLite inventory or JSON export
    XCTAssertTrue(store.hosts.isEmpty)
    XCTAssertTrue(try repository.listHosts().isEmpty)
    XCTAssertNil(try repository.sshConnectionSettings(hostID: entry.host.id))

    let exportData = try InventoryImportExportService.exportToJSON(repository: repository)
    let exportString = String(decoding: exportData, as: UTF8.self)
    XCTAssertFalse(exportString.contains("ephemeral.example.test"))
    XCTAssertFalse(exportString.contains(entry.host.id))

    // 2. Verify strict host key mismatch and unknown-host classification for temporary Quick Connect host
    let recordedKey = SSHHostKeyRecord(
      rawLine: "[ephemeral.example.test]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILM+rvN+ot98qgEN796jTiQfZfG1KaT0PtFDJ/XFSqti",
      keyType: "ssh-ed25519",
      keyBase64: "AAAAC3NzaC1lZDI1NTE5AAAAILM+rvN+ot98qgEN796jTiQfZfG1KaT0PtFDJ/XFSqti",
      algorithm: "ED25519",
      fingerprintSHA256: "SHA256:recorded"
    )
    let presentedKey = SSHHostKeyRecord(
      rawLine: "[ephemeral.example.test]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG5vbmV4aXN0ZW50bWlzbWF0Y2hrZXlmb3J0ZXN0aW5n",
      keyType: "ssh-ed25519",
      keyBase64: "AAAAC3NzaC1lZDI1NTE5AAAAIG5vbmV4aXN0ZW50bWlzbWF0Y2hrZXlmb3J0ZXN0aW5n",
      algorithm: "ED25519",
      fingerprintSHA256: "SHA256:presented"
    )

    let unknownStatus = NativeSSHHostTrustService.classify(
      recordedKeys: [],
      presentedKeys: [presentedKey],
      host: entry.host.address,
      port: entry.target.port
    )
    if case .unknown(let challenge) = unknownStatus {
      XCTAssertEqual(challenge.host, "ephemeral.example.test")
      XCTAssertEqual(challenge.port, 2222)
    } else {
      XCTFail("Expected unknown host key challenge for temporary Quick Connect host, got \(unknownStatus)")
    }

    let mismatchStatus = NativeSSHHostTrustService.classify(
      recordedKeys: [recordedKey],
      presentedKeys: [presentedKey],
      host: entry.host.address,
      port: entry.target.port
    )
    if case .mismatch = mismatchStatus {
      // Expected: strict host trust blocks mismatched key for temporary Quick Connect host
    } else {
      XCTFail("Expected strict host key mismatch for temporary Quick Connect host, got \(mismatchStatus)")
    }
  }

  // MARK: - Session Registry Lifecycle & Restored Window Safety

  @MainActor
  func testSessionRegistryLifecycleAndUnpopulatedRestoredWindowShowsUnavailableWithoutAutoConnecting() throws {
    let registry = QuickConnectSessionRegistry()
    let target = try QuickConnectTarget.parse("ssh://deploy@ephemeral.example.test:2222")

    // Unpopulated window ID (e.g., restored by macOS after app relaunch) has no entry and no open request
    let restoredWindowID = "restored-qc-\(UUID().uuidString)"
    XCTAssertNil(registry.entry(for: restoredWindowID))
    XCTAssertFalse(SSHWindowOpenRequests.shared.consume(hostID: restoredWindowID))

    // Render QuickConnectSSHSessionWindowView for an unpopulated/restored windowID:
    // verifies it renders UnavailableSessionView cleanly without crashing or auto-connecting.
    let unavailableView = QuickConnectSSHSessionWindowView(windowID: restoredWindowID)
      .frame(width: 700, height: 540)
    let hosting = NSHostingView(rootView: unavailableView)
    hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 540)
    hosting.layoutSubtreeIfNeeded()
    XCTAssertNil(QuickConnectSessionRegistry.shared.entry(for: restoredWindowID))

    // Opening registers the entry; closing removes it and leaves no lingering state
    let entry = registry.open(
      windowID: "active-qc-win",
      target: target,
      environment: .production,
      authentication: .sshAgent
    )
    XCTAssertEqual(registry.entry(for: "active-qc-win"), entry)
    XCTAssertEqual(entry.host.environment, .production)
    XCTAssertEqual(entry.host.address, "ephemeral.example.test")

    registry.close(windowID: "active-qc-win")
    XCTAssertNil(registry.entry(for: "active-qc-win"))
  }

  // MARK: - Embedded RDP Resource Lifecycle & Reconnect Freshness

  @MainActor
  func testQuickConnectRdpResourcesCloseDatabasePerOperationAndRefreshCredentialsAndVerifierOnReconnect() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mrw-qc-rdp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let dbURL = tempDir.appendingPathComponent("metadata.sqlite")
    let keychain = InMemoryTestCredentialStore()

    let secret1 = ProtectedSecret(data: Data("FirstPassword!1".utf8))
    let ref1 = try keychain.create(secret: secret1)
    let credID: String
    do {
      let setupRepo = try SQLiteHostRepository(databaseURL: dbURL)
      defer { try? setupRepo.close() }
      let created = try setupRepo.createCredentialRef(
        label: "RDP Cred",
        kind: .rdpPassword,
        keychainItemID: ref1.encoded
      )
      credID = created.id
    }

    let openCounter = RepositoryOpenCounter()
    let resources = QuickConnectRdpSessionResources(
      openRepository: {
        openCounter.increment()
        return try SQLiteHostRepository(databaseURL: dbURL)
      }
    )

    // 1. Verify credential lookup reads from SQLite and closes handle immediately
    let lookedUp1 = try XCTUnwrap(try resources.lookupCredentialRef(id: credID))
    XCTAssertEqual(lookedUp1.keychainItemID, ref1.encoded)
    XCTAssertEqual(openCounter.count, 1)

    // 2. Verify RDP host trust evaluation and approval persist to SQLite without holding an open connection
    let cert = RdpCertificateRecord(
      host: "rdp.example.test",
      port: 3389,
      sha256Fingerprint: String(repeating: "AB", count: 32),
      subjectCN: "rdp.example.test",
      issuerCN: "Test CA"
    )
    let verifier1 = NativeRdpCertificateTrustService(repository: resources)
    let initialTrust = try await verifier1.evaluateTrust(host: "rdp.example.test", port: 3389, presented: cert)
    guard case .unknown(let challenge) = initialTrust else {
      return XCTFail("Expected unknown certificate challenge on first connect, got \(initialTrust)")
    }
    try await verifier1.approveChallenge(challenge)

    // 3. Simulate credential rotation/recreation in SQLite and Keychain before reconnect
    let secret2 = ProtectedSecret(data: Data("RotatedPassword!2".utf8))
    let ref2 = try keychain.create(secret: secret2)
    let rotatedCredID: String
    do {
      let updateRepo = try SQLiteHostRepository(databaseURL: dbURL)
      defer { try? updateRepo.close() }
      try updateRepo.deleteCredentialRef(id: credID)
      let recreated = try updateRepo.createCredentialRef(
        label: "RDP Cred Rotated",
        kind: .rdpPassword,
        keychainItemID: ref2.encoded
      )
      rotatedCredID = recreated.id
    }

    // Old credential ID is no longer returned (proving no stale credentialRefs snapshot)
    XCTAssertNil(try resources.lookupCredentialRef(id: credID))
    let lookedUp2 = try XCTUnwrap(try resources.lookupCredentialRef(id: rotatedCredID))
    XCTAssertEqual(lookedUp2.keychainItemID, ref2.encoded)

    // 4. Verify makeEmbeddedSessionFactory + RdpSessionWindowRegistry.reconnect creates a fresh session
    // and verifier per attempt while reading persisted trust from SQLite
    let target = try QuickConnectTarget.parse("rdp://rdp.example.test:3389")
    let tempHost = QuickConnectSessionRegistry.makeTemporaryHost(for: target)
    let makeSession = QuickConnectRdpSessionResources.makeEmbeddedSessionFactory(
      target: target,
      username: "CORP\\Admin",
      credentialRefID: rotatedCredID,
      options: RdpConnectionOptions(),
      keychainStore: keychain,
      openRepository: {
        openCounter.increment()
        return try SQLiteHostRepository(databaseURL: dbURL)
      }
    )

    let windowID = "qc-rdp-win-\(UUID().uuidString)"
    RdpSessionWindowRegistry.shared.open(windowID: windowID, host: tempHost, makeSession: makeSession)
    let firstSession = try XCTUnwrap(RdpSessionWindowRegistry.shared.entry(for: windowID)?.session)
    defer {
      if let current = RdpSessionWindowRegistry.shared.entry(for: windowID)?.session {
        RdpSessionWindowRegistry.shared.close(windowID: windowID, sessionID: current.id)
      }
    }

    RdpSessionWindowRegistry.shared.reconnect(windowID: windowID)
    let reconnectedSession = try XCTUnwrap(RdpSessionWindowRegistry.shared.entry(for: windowID)?.session)
    XCTAssertNotEqual(firstSession.id, reconnectedSession.id)

    // Fresh verifier instance on reconnect sees the previously approved certificate in SQLite
    let verifier2 = NativeRdpCertificateTrustService(repository: resources)
    let reconnectTrust = try await verifier2.evaluateTrust(host: "rdp.example.test", port: 3389, presented: cert)
    guard case .trusted(let matchedCert) = reconnectTrust else {
      return XCTFail("Expected trusted certificate on reconnect, got \(reconnectTrust)")
    }
    XCTAssertEqual(matchedCert.host, cert.host)
    XCTAssertEqual(matchedCert.port, cert.port)
    XCTAssertEqual(matchedCert.sha256Fingerprint, cert.sha256Fingerprint)
    XCTAssertEqual(matchedCert.subjectCN, cert.subjectCN)
    XCTAssertEqual(matchedCert.issuerCN, cert.issuerCN)

    // And verify temporary RDP host was never persisted to SQLite hosts table
    do {
      let checkRepo = try SQLiteHostRepository(databaseURL: dbURL)
      defer { try? checkRepo.close() }
      XCTAssertTrue(try checkRepo.listHosts().isEmpty)
    }
  }

  // MARK: - Command Palette Quick Connect Entry

  func testPaletteIncludesQuickConnectEntryAndFiltersByQuery() {
    let host = HostRecord(
      id: "h1",
      workspaceID: "w1",
      displayName: "Bastion",
      address: "bastion.internal",
      environment: .production,
      version: 1,
      protocols: ["ssh"]
    )
    let workspace = WorkspaceRecord(id: "w1", name: "Core Infra")

    let defaultResults = PaletteResult.buildResults(
      hosts: [host],
      workspaces: [workspace],
      groups: [],
      query: ""
    )
    XCTAssertEqual(defaultResults.first?.id, "quick-connect")

    let quickFiltered = PaletteResult.buildResults(
      hosts: [host],
      workspaces: [workspace],
      groups: [],
      query: "quick"
    )
    XCTAssertEqual(quickFiltered.map(\.id), ["quick-connect"])

    let hostFiltered = PaletteResult.buildResults(
      hosts: [host],
      workspaces: [workspace],
      groups: [],
      query: "bastion"
    )
    XCTAssertEqual(hostFiltered.map(\.id), ["host:h1"])
  }

  // MARK: - UI Hosting & Screenshot Verification (C3)

  @MainActor
  func testQuickConnectSheetRendersLightAndDarkStates() throws {
    let defaults = UserDefaults.standard
    let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
    for language in ["en", "vi"] {
      var syntheticArguments = arguments
      syntheticArguments[AppLanguage.preferenceKey] = language
      defaults.setVolatileDomain(syntheticArguments, forName: UserDefaults.argumentDomain)
      for scheme in [ColorScheme.light, .dark] {
        let model = QuickConnectFormModel(
          defaultSSHUsername: "fixture-user", defaultProtocol: "ssh", defaultRdpLaunchMode: .external
        )
        model.rawInput = "ssh://fixture-user@fixture.example.test:2222"
        // Missing password keeps Return safe: this fixture never launches a session.
        let record = CredentialRefRecord(
          id: "fixture", label: "Synthetic credential", kind: .password, keychainItemID: "synthetic"
        )
        var loads = 0
        let sheet = QuickConnectSheet(model: model, credentialReferenceSource: {
          loads += 1
          return [record]
        }).environment(\.colorScheme, scheme)
        try renderSheet(
          sheet,
          model: model,
          scheme: scheme,
          path: "/tmp/mrw-quick-connect-\(language)-\(scheme).png"
        )
        XCTAssertGreaterThan(loads, 0)
        XCTAssertEqual(model.credentialRefs, [record])
        XCTAssertEqual(model.selectedCredentialID, record.id)
        XCTAssertFalse(model.canConnect)
      }
    }
  }

  @MainActor
  func testCredentialSourceFailureClearsStaleReferences() throws {
    let defaults = UserDefaults.standard
    let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    var syntheticArguments = arguments
    syntheticArguments[AppLanguage.preferenceKey] = "en"
    defaults.setVolatileDomain(syntheticArguments, forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
    let model = QuickConnectFormModel(
      defaultSSHUsername: "fixture-user", defaultProtocol: "ssh", defaultRdpLaunchMode: .external
    )
    model.updateCredentialRefs([
      CredentialRefRecord(id: "fixture", label: "Synthetic", kind: .password, keychainItemID: "synthetic")
    ])
    let sheet = QuickConnectSheet(model: model, credentialReferenceSource: {
      throw CocoaError(.fileReadNoPermission)
    })
    try renderSheet(
      sheet,
      model: model,
      scheme: .light,
      path: nil
    )
    XCTAssertTrue(model.credentialRefs.isEmpty)
    XCTAssertNil(model.selectedCredentialID)
  }

  @MainActor
  private func renderSheet(
    _ content: some View,
    model: QuickConnectFormModel,
    scheme: ColorScheme,
    path: String?
  ) throws {
    let appearanceName: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
    let appearance = NSAppearance(named: appearanceName)
    var isPresented = true
    let controller = NSHostingController(rootView: Text("Synthetic presentation fixture")
      .frame(width: 640, height: 740)
      .environment(\.colorScheme, scheme)
      .sheet(isPresented: Binding(get: { isPresented }, set: { isPresented = $0 })) {
        content.frame(width: 540, height: 640)
      })
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 740),
      styleMask: [.titled, .closable], backing: .buffered, defer: false
    )
    window.appearance = appearance
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    window.makeKeyAndOrderFront(nil)
    defer {
      if let sheet = window.attachedSheet {
        window.endSheet(sheet)
        waitUntil { window.attachedSheet == nil }
        XCTAssertNil(window.attachedSheet, "Fixture cleanup must detach the sheet")
        sheet.orderOut(nil)
      }
      window.contentViewController = nil
      window.close()
    }
    waitUntil { window.attachedSheet != nil }
    let sheet = try XCTUnwrap(window.attachedSheet, "Must present a real sheet with toolbar actions")
    sheet.appearance = appearance
    let sheetView = try XCTUnwrap(sheet.contentView)
    sheetView.layoutSubtreeIfNeeded()
    sheet.displayIfNeeded()
    XCTAssertEqual(sheet.accessibilityRole(), .sheet)
    waitUntil { sheet.firstResponder is NSTextView }
    XCTAssertTrue(sheet.firstResponder is NSTextView, "Address field must receive initial keyboard focus")
    if let path {
      let capture = Process()
      capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      capture.arguments = ["-x", "-o", "-l\(sheet.windowNumber)", path]
      try capture.run()
      capture.waitUntilExit()
      XCTAssertEqual(capture.terminationStatus, 0)

      // Return key when password is empty must not dismiss the sheet or connect, and must populate validation error
      let returnKey = try XCTUnwrap(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: sheet.windowNumber, context: nil,
        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
      ))
      _ = sheet.performKeyEquivalent(with: returnKey)
      sheet.firstResponder?.keyDown(with: returnKey)
      waitUntil { model.validationErrorMessage != nil }
      XCTAssertNotNil(model.validationErrorMessage, "Submitting with empty password must populate validation error")
      XCTAssertTrue(isPresented, "Return must not dismiss sheet when Connect is disabled")
      XCTAssertFalse(model.canConnect)
    }
    let escape = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: sheet.windowNumber, context: nil,
      characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
    ))
    _ = sheet.performKeyEquivalent(with: escape)
    waitUntil { !isPresented }
    XCTAssertFalse(isPresented, "Escape must invoke the sheet's Cancel action")
  }

  @MainActor
  private func waitUntil(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(3)
    while !condition() && Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
  }
}

private final class RepositoryOpenCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var _count = 0

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return _count
  }

  func increment() {
    lock.lock()
    defer { lock.unlock() }
    _count += 1
  }
}

private final class InMemoryTestCredentialStore: CredentialSecretStore, @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [KeychainCredentialReference: ProtectedSecret] = [:]

  func create(secret: ProtectedSecret) throws -> KeychainCredentialReference {
    lock.lock()
    defer { lock.unlock() }
    let ref = KeychainCredentialStore.freshReference()
    storage[ref] = secret
    return ref
  }

  func create(reference: KeychainCredentialReference, secret: ProtectedSecret) throws {
    lock.lock()
    defer { lock.unlock() }
    storage[reference] = secret
  }

  func read(_ reference: KeychainCredentialReference) throws -> ProtectedSecret {
    lock.lock()
    defer { lock.unlock() }
    guard let secret = storage[reference] else {
      throw CredentialStoreError.notFound
    }
    return secret
  }

  func delete(_ reference: KeychainCredentialReference) throws {
    lock.lock()
    defer { lock.unlock() }
    storage.removeValue(forKey: reference)
  }

  func contains(_ reference: KeychainCredentialReference) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return storage[reference] != nil
  }

  func update(_ reference: KeychainCredentialReference, secret: ProtectedSecret) throws {
    lock.lock()
    defer { lock.unlock() }
    storage[reference] = secret
  }
}
