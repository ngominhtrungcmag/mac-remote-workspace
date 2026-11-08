import AppCore
import Combine
import Foundation
import SwiftUI

public enum SFTPAuthMethod: String, CaseIterable, Identifiable, Sendable {
  case password = "Password"
  case keychain = "Keychain Credential"
  case agent = "SSH Agent"

  public var id: Self { self }
}

@MainActor
public final class SFTPBrowserViewModel: ObservableObject {
  public let host: HostRecord

  @Published public var username: String
  @Published public var portString: String
  @Published public var authMethod: SFTPAuthMethod
  @Published public var password: String = ""
  @Published public var savePasswordToKeychain: Bool = false
  @Published public var passwordCredentialLabel: String = ""
  @Published public var selectedCredentialID: String? = nil
  @Published public var availableCredentials: [CredentialRefRecord] = []
  @Published public var keyFilePath: String = ""
  @Published public var privateKeyFileURL: URL? = nil
  @Published public var validationError: String? = nil
  @Published public var isDiagnosing: Bool = false
  @Published public var diagnosticsReport: SSHConnectionDiagnosticReport? = nil

  // Connection & Trust State
  @Published public private(set) var isConnected: Bool = false
  @Published public private(set) var isConnecting: Bool = false
  @Published public private(set) var trustChallenge: SSHHostTrustChallenge? = nil
  @Published public private(set) var mismatchBlocked: (recorded: [SSHHostKeyRecord], presented: SSHHostKeyRecord)? = nil
  @Published public var errorMessage: String? = nil

  // Browsing State
  @Published public private(set) var currentPath: String = "/"
  @Published public private(set) var entries: [SFTPFileEntry] = []
  @Published public private(set) var isLoadingDirectory: Bool = false
  @Published public var searchQuery: String = ""
  @Published public var selectedEntryIDs: Set<String> = []

  public func entries(for selection: Set<String>) -> [SFTPFileEntry] {
    Self.entries(filteredEntries, matching: selection)
  }

  static func entries(_ entries: [SFTPFileEntry], matching selection: Set<String>) -> [SFTPFileEntry] {
    entries.filter { selection.contains($0.id) }
  }

  // Navigation History
  @Published public private(set) var history: [String] = ["/"]
  @Published public private(set) var historyIndex: Int = 0

  // Action targets
  @Published public var entriesPendingDeletion: [SFTPFileEntry] = []
  @Published public var entryPendingRename: SFTPFileEntry? = nil
  @Published public var newFolderName: String = ""
  @Published public var isShowingNewFolderSheet: Bool = false

  private var sftpClient: NativeSFTPClient?
  private let trustService: NativeSSHHostTrustService
  private var credentialRepository: SQLiteHostRepository?
  private let passwordAuthService: SSHPasswordAuthenticationServiceProtocol

  private final class EphemeralHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var reference: KeychainCredentialReference?

    func set(_ ref: KeychainCredentialReference?) {
      lock.lock()
      defer { lock.unlock() }
      reference = ref
    }

    func take() -> KeychainCredentialReference? {
      lock.lock()
      defer { lock.unlock() }
      let ref = reference
      reference = nil
      return ref
    }
  }
  private let ephemeralHolder = EphemeralHolder()

  public init(
    host: HostRecord,
    trustService: NativeSSHHostTrustService = NativeSSHHostTrustService(
      knownHostsFileURL: NativeSSHHostTrustService.defaultKnownHostsURL,
      audit: NativeSSHHostTrustService.appAuditSink
    ),
    credentialRepository: SQLiteHostRepository? = nil,
    passwordAuthService: SSHPasswordAuthenticationServiceProtocol = SSHPasswordAuthenticationService()
  ) {
    self.host = host
    self.trustService = trustService
    self.credentialRepository = credentialRepository
    self.passwordAuthService = passwordAuthService

    let preset = SSHConnectionPreset.load(hostID: host.id)
    if let preset {
      self.username = preset.username
      self.portString = String(preset.port)
      self.keyFilePath = preset.keyFilePath
      self.selectedCredentialID = preset.credentialID
      self.authMethod = switch preset.auth {
      case .password: .password
      case .keychainCredential: .keychain
      case .sshAgent: .agent
      }
    } else {
      self.username = NSUserName()
      self.portString = "22"
      self.authMethod = .agent
    }

    self.loadCredentials()
    if let preset, let credID = preset.credentialID {
      if availableCredentials.contains(where: { $0.id == credID }) {
        self.selectedCredentialID = credID
      }
    }
  }

  deinit {
    cleanupEphemeralCredential()
  }

  nonisolated private func cleanupEphemeralCredential() {
    guard let ref = ephemeralHolder.take() else { return }
    passwordAuthService.cleanupEphemeralCredential(ref)
  }

  public func disconnect() {
    isConnected = false
    isConnecting = false
    sftpClient = nil
    entries = []
    currentPath = "/"
    cleanupEphemeralCredential()
  }

  public func loadCredentials() {
    do {
      let repo = try credentialRepository ?? SQLiteHostRepository.openApplicationRepository()
      self.credentialRepository = repo
      self.availableCredentials = try repo.listCredentialRefs()
      if selectedCredentialID == nil || !availableCredentials.contains(where: { $0.id == selectedCredentialID }) {
        self.selectedCredentialID = availableCredentials.first?.id
      }
    } catch {
      self.availableCredentials = []
    }
  }

  public var port: Int {
    Int(portString) ?? 22
  }

  public var resolvedKeyFileURL: URL? {
    let trimmed = keyFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return privateKeyFileURL }
    return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
  }

  public func performDiagnostics() {
    guard let port = Int(portString), (1...65535).contains(port) else {
      validationError = AppLocalization.string("Port must be a valid integer between 1 and 65535.")
      return
    }
    validationError = nil
    diagnosticsReport = nil
    isDiagnosing = true
    let targetHost = host.address
    Task.detached(priority: .userInitiated) {
      let report = SSHConnectionDiagnosticProbe.run(host: targetHost, port: port)
      await MainActor.run {
        self.diagnosticsReport = report
        self.isDiagnosing = false
      }
    }
  }

  public var filteredEntries: [SFTPFileEntry] {
    let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !q.isEmpty else { return entries }
    return entries.filter { $0.name.lowercased().contains(q) }
  }

  public var canNavigateUp: Bool {
    currentPath != "/" && !currentPath.isEmpty
  }

  public var canNavigateBack: Bool {
    historyIndex > 0
  }

  public var canNavigateForward: Bool {
    historyIndex < history.count - 1
  }

  // MARK: - Connection & Trust Flow

  public func connect() {
    guard !isConnecting else { return }
    validationError = nil
    errorMessage = nil
    diagnosticsReport = nil

    let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedUsername.isEmpty, !trimmedUsername.hasPrefix("-") else {
      validationError = AppLocalization.string("Username is required and cannot start with '-'.")
      return
    }

    guard let targetPort = Int(portString), (1...65535).contains(targetPort) else {
      validationError = AppLocalization.string("Port must be an integer between 1 and 65535.")
      return
    }

    switch authMethod {
    case .password:
      guard !password.isEmpty else {
        validationError = AppLocalization.string("Password cannot be empty.")
        return
      }
    case .keychain:
      guard let selectedCredentialID,
            availableCredentials.contains(where: { $0.id == selectedCredentialID }) else {
        validationError = AppLocalization.string("Choose a saved Keychain credential, or manage credentials in Security → Credentials.")
        return
      }
    case .agent:
      guard let sock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], !sock.isEmpty,
            FileManager.default.fileExists(atPath: sock) else {
        validationError = AppLocalization.string("No active SSH agent found (SSH_AUTH_SOCK missing or invalid).")
        return
      }
    }

    isConnecting = true
    trustChallenge = nil
    mismatchBlocked = nil

    let targetHost = host.address

    Task.detached(priority: .userInitiated) { [trustService] in
      do {
        let status = try trustService.evaluateEndpoint(host: targetHost, port: targetPort)
        await MainActor.run {
          switch status {
          case .trusted:
            self.proceedWithSFTPConnection()
          case .unknown(let challenge):
            self.isConnecting = false
            self.trustChallenge = challenge
          case .mismatch(let recorded, let presented):
            self.isConnecting = false
            self.mismatchBlocked = (recorded: recorded, presented: presented)
          }
        }
      } catch {
        await MainActor.run {
          self.isConnecting = false
          self.errorMessage = error.localizedDescription
        }
      }
    }
  }

  public func approveTrustChallengeAndConnect() {
    guard let challenge = trustChallenge else { return }
    isConnecting = true

    Task.detached(priority: .userInitiated) { [trustService] in
      do {
        try trustService.approveChallenge(challenge, expectedHost: challenge.host, expectedPort: challenge.port)
        await MainActor.run {
          self.trustChallenge = nil
          self.proceedWithSFTPConnection()
        }
      } catch {
        await MainActor.run {
          self.isConnecting = false
          self.errorMessage = AppLocalization.format("Failed to trust host key: %1$@", error.localizedDescription)
        }
      }
    }
  }

  /// Explicit, user-confirmed replacement of the recorded key after a mismatch (audited as ssh.hostkey.rotated).
  public func rotateTrustAndConnect() {
    guard let mismatch = mismatchBlocked else { return }
    let challenge = SSHHostTrustChallenge(host: host.address, port: port, presentedKey: mismatch.presented)
    isConnecting = true
    Task.detached(priority: .userInitiated) { [trustService] in
      do {
        try trustService.rotateKnownHostKey(challenge, expectedHost: challenge.host, expectedPort: challenge.port)
        await MainActor.run {
          self.mismatchBlocked = nil
          self.proceedWithSFTPConnection()
        }
      } catch {
        await MainActor.run {
          self.isConnecting = false
          self.errorMessage = AppLocalization.format("Failed to rotate host key: %1$@", error.localizedDescription)
        }
      }
    }
  }

  public func cancelTrust() {
    trustChallenge = nil
    isConnecting = false
  }

  private func proceedWithSFTPConnection() {
    do {
      let auth = try buildAuthentication()
      let config = NativeSSHConfiguration(
        host: host.address,
        port: port,
        username: username.trimmingCharacters(in: .whitespacesAndNewlines),
        knownHostsFileURL: trustService.knownHostsFileURL,
        authentication: auth
      )
      let client = try NativeSFTPClient(configuration: config)
      self.sftpClient = client
      self.isConnected = true
      self.isConnecting = false
      loadDirectory(path: currentPath)
    } catch {
      self.isConnecting = false
      self.cleanupEphemeralCredential()
      self.errorMessage = error.localizedDescription
    }
  }

  private func buildAuthentication() throws -> NativeSSHAuthentication {
    switch authMethod {
    case .password:
      guard !password.isEmpty else {
        throw NativeSSHError.connectionFailed(details: AppLocalization.string("Password cannot be empty."))
      }
      let secret = ProtectedSecret(data: Data(password.utf8))
      let defaultLabel = "\(host.displayName) (\(username.trimmingCharacters(in: .whitespacesAndNewlines)))"
      let trimmedLabel = passwordCredentialLabel.trimmingCharacters(in: .whitespacesAndNewlines)
      let prepared = try passwordAuthService.preparePasswordAuthentication(
        secret: secret,
        saveToKeychain: savePasswordToKeychain,
        label: trimmedLabel.isEmpty ? nil : trimmedLabel,
        defaultLabel: defaultLabel
      )
      if let ephemeral = prepared.ephemeralReference {
        self.ephemeralHolder.set(ephemeral)
      }
      if let saved = prepared.savedRecord {
        self.loadCredentials()
        self.selectedCredentialID = saved.id
      }
      var preset = SSHConnectionPreset.load(hostID: host.id) ?? SSHConnectionPreset()
      preset.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
      preset.port = port
      preset.auth = .password
      if savePasswordToKeychain, let saved = prepared.savedRecord {
        preset.credentialID = saved.id
      }
      preset.save(hostID: host.id)
      return prepared.authentication

    case .keychain:
      guard let id = selectedCredentialID,
            let cred = availableCredentials.first(where: { $0.id == id }),
            let reference = KeychainCredentialReference.decode(cred.keychainItemID) else {
        throw NativeSSHError.invalidAskpassReference
      }
      let identityFileURL = resolvedKeyFileURL

      var preset = SSHConnectionPreset.load(hostID: host.id) ?? SSHConnectionPreset()
      preset.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
      preset.port = port
      preset.auth = .keychainCredential
      preset.credentialID = cred.id
      preset.keyFilePath = keyFilePath
      preset.save(hostID: host.id)

      return .keychainAskpass(
        service: reference.service,
        account: reference.account,
        identityFile: identityFileURL
      )

    case .agent:
      guard let sock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], !sock.isEmpty,
            FileManager.default.fileExists(atPath: sock) else {
        throw NativeSSHError.missingAgentSocket(AppLocalization.string("No active SSH agent found (SSH_AUTH_SOCK missing or invalid)."))
      }
      var preset = SSHConnectionPreset.load(hostID: host.id) ?? SSHConnectionPreset()
      preset.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
      preset.port = port
      preset.auth = .sshAgent
      preset.save(hostID: host.id)
      return .agent(socketURL: URL(fileURLWithPath: sock))
    }
  }

  // MARK: - Directory Navigation

  public func loadDirectory(path: String) {
    guard let client = sftpClient else { return }
    isLoadingDirectory = true
    errorMessage = nil

    Task.detached(priority: .userInitiated) {
      do {
        let loaded = try client.listDirectory(at: path)
        await MainActor.run {
          self.currentPath = path
          self.entries = loaded
          self.isLoadingDirectory = false
          self.selectedEntryIDs = []
        }
      } catch {
        await MainActor.run {
          self.isLoadingDirectory = false
          self.errorMessage = error.localizedDescription
          if self.entries.isEmpty && path == "/" {
            self.disconnect()
            self.errorMessage = error.localizedDescription
          }
        }
      }
    }
  }

  public func navigateTo(entry: SFTPFileEntry) {
    if entry.isDirectory {
      let newPath = entry.path
      if historyIndex < history.count - 1 {
        history.removeSubrange((historyIndex + 1)...)
      }
      history.append(newPath)
      historyIndex = history.count - 1
      loadDirectory(path: newPath)
    }
  }

  public func navigateUp() {
    guard canNavigateUp else { return }
    let parent = (currentPath as NSString).deletingLastPathComponent
    let cleanParent = parent.isEmpty ? "/" : parent
    history.append(cleanParent)
    historyIndex = history.count - 1
    loadDirectory(path: cleanParent)
  }

  public func navigateBack() {
    guard canNavigateBack else { return }
    historyIndex -= 1
    loadDirectory(path: history[historyIndex])
  }

  public func navigateForward() {
    guard canNavigateForward else { return }
    historyIndex += 1
    loadDirectory(path: history[historyIndex])
  }

  // MARK: - File Operations (FR-011)

  public func createFolder(name: String) {
    let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanName.isEmpty, let client = sftpClient else { return }
    let target = currentPath == "/" ? "/\(cleanName)" : "\(currentPath)/\(cleanName)"

    Task.detached(priority: .userInitiated) {
      do {
        try client.createDirectory(at: target)
        await MainActor.run {
          self.loadDirectory(path: self.currentPath)
        }
      } catch {
        await MainActor.run {
          self.errorMessage = error.localizedDescription
        }
      }
    }
  }

  public func deleteConfirmedEntries() {
    // FR-011: only delete the exact entries shown in the confirmation.
    guard let client = sftpClient, !entriesPendingDeletion.isEmpty else { return }
    let targets = entriesPendingDeletion
    entriesPendingDeletion = []
    Task.detached(priority: .userInitiated) {
      do {
        for entry in targets {
          if entry.isDirectory {
            try client.deleteDirectory(at: entry.path)
          } else {
            try client.deleteFile(at: entry.path)
          }
        }
        await MainActor.run { self.loadDirectory(path: self.currentPath) }
      } catch {
        await MainActor.run {
          self.loadDirectory(path: self.currentPath)
          self.errorMessage = error.localizedDescription
        }
      }
    }
  }

  public func renameEntry(_ entry: SFTPFileEntry, to newName: String) {
    guard let client = sftpClient else { return }
    let target: String
    do {
      target = try NativeSFTPClient.renameTarget(for: entry.path, newName: newName)
    } catch {
      entryPendingRename = nil
      errorMessage = error.localizedDescription
      return
    }

    Task.detached(priority: .userInitiated) {
      do {
        try client.rename(from: entry.path, to: target)
        await MainActor.run {
          self.entryPendingRename = nil
          self.loadDirectory(path: self.currentPath)
        }
      } catch {
        await MainActor.run {
          self.entryPendingRename = nil
          self.errorMessage = error.localizedDescription
        }
      }
    }
  }

  // MARK: - Queue Transfers (FR-010)

  public func upload(localURL: URL, queue: SFTPTransferQueue) {
    guard let client = sftpClient else { return }
    let remoteTarget = currentPath == "/" ? "/\(localURL.lastPathComponent)" : "\(currentPath)/\(localURL.lastPathComponent)"
    _ = queue.enqueueUpload(client: client, localURL: localURL, remotePath: remoteTarget, overwrite: false)
  }

  public func download(entry: SFTPFileEntry, localDirectoryURL: URL, queue: SFTPTransferQueue) {
    guard let client = sftpClient else { return }
    _ = queue.enqueueDownload(
      client: client,
      remotePath: entry.path,
      localDirectoryURL: localDirectoryURL,
      filename: entry.name,
      overwrite: false,
      totalBytes: entry.size
    )
  }
}
