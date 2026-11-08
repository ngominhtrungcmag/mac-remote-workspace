import AppCore
import Foundation
import SwiftUI

/// Polling choices are bounded: off (manual) or no faster than every 15 seconds.
public enum HostMetricsPollInterval: Int, CaseIterable, Identifiable, Sendable {
  case off = 0
  case seconds15 = 15
  case seconds30 = 30
  case seconds60 = 60

  public var id: Int { rawValue }
  public var label: String {
    self == .off
      ? AppLocalization.string("Manual")
      : AppLocalization.format("Every %1$@ seconds", String(rawValue))
  }
}

/// Authentication method for host metrics polling.
public enum HostMetricsAuthMethod: String, CaseIterable, Identifiable, Sendable {
  case agent = "SSH Agent"
  case keychain = "Keychain Credential"

  public var id: Self { self }
  public var localizedTitle: String { AppLocalization.string(rawValue) }
}

@MainActor
public final class HostMetricsViewModel: ObservableObject {
  public let host: HostRecord

  @Published public var username = NSUserName()
  @Published public var portString = "22"
  @Published public var authMethod: HostMetricsAuthMethod = .agent
  @Published public var selectedCredentialID: String?
  @Published public private(set) var availableCredentials: [CredentialRefRecord] = []
  @Published public var pollInterval: HostMetricsPollInterval = .off {
    didSet { restartPolling() }
  }

  @Published public private(set) var metrics: RemoteHostMetrics?
  @Published public private(set) var lastUpdated: Date?
  @Published public private(set) var isLoading = false
  @Published public private(set) var trustChallenge: SSHHostTrustChallenge?
  @Published public private(set) var mismatchBlocked: (recorded: [SSHHostKeyRecord], presented: SSHHostKeyRecord)?
  @Published public var errorMessage: String?

  private let trustService: NativeSSHHostTrustService
  private var pollTask: Task<Void, Never>?
  private var fetchTask: Task<Void, Never>?
  private var credentialRepository: SQLiteHostRepository?

  public init(
    host: HostRecord,
    trustService: NativeSSHHostTrustService = NativeSSHHostTrustService(
      knownHostsFileURL: NativeSSHHostTrustService.defaultKnownHostsURL)
  ) {
    self.host = host
    self.trustService = trustService
    if let preset = SSHConnectionPreset.load(hostID: host.id) {
      username = preset.username
      portString = String(preset.port)
      authMethod = preset.auth == .keychainCredential ? .keychain : .agent
      selectedCredentialID = preset.credentialID
    }
    if let repo = try? SQLiteHostRepository.openApplicationRepository() {
      credentialRepository = repo
      availableCredentials = (try? repo.listCredentialRefs()) ?? []
      if selectedCredentialID == nil { selectedCredentialID = availableCredentials.first?.id }
    }
  }

  public var port: Int { Int(portString) ?? 22 }

  /// Evaluates trust first (explicit decision for unknown keys; mismatch blocks), then fetches.
  public func refresh() {
    guard !isLoading else { return }
    isLoading = true
    errorMessage = nil
    trustChallenge = nil
    mismatchBlocked = nil
    let address = host.address
    let targetPort = port
    fetchTask = Task { [trustService] in
      do {
        let status = try await Task.detached { try trustService.evaluateEndpoint(host: address, port: targetPort) }.value
        switch status {
        case .trusted: await fetch()
        case .unknown(let challenge):
          isLoading = false
          trustChallenge = challenge
        case .mismatch(let recorded, let presented):
          isLoading = false
          mismatchBlocked = (recorded, presented)
          stopPolling()
        }
      } catch {
        isLoading = false
        errorMessage = error.localizedDescription
        stopPolling()
      }
    }
  }

  public func approveTrustChallengeAndRefresh() {
    guard let challenge = trustChallenge else { return }
    do {
      try trustService.approveChallenge(challenge, expectedHost: challenge.host, expectedPort: challenge.port)
      trustChallenge = nil
      refresh()
    } catch {
      errorMessage = AppLocalization.format("Failed to trust host key: %1$@", error.localizedDescription)
    }
  }

  /// Explicit, user-confirmed replacement of the recorded key after a mismatch (audited as ssh.hostkey.rotated).
  public func rotateTrustAndRefresh() {
    guard let mismatch = mismatchBlocked else { return }
    let challenge = SSHHostTrustChallenge(host: host.address, port: port, presentedKey: mismatch.presented)
    do {
      try trustService.rotateKnownHostKey(challenge, expectedHost: challenge.host, expectedPort: challenge.port)
      mismatchBlocked = nil
      refresh()
    } catch {
      errorMessage = AppLocalization.format("Failed to rotate host key: %1$@", error.localizedDescription)
    }
  }

  public func cancelTrust() { trustChallenge = nil }

  public func stop() {
    stopPolling()
    fetchTask?.cancel()
  }

  private func fetch() async {
    do {
      let config = NativeSSHConfiguration(
        host: host.address, port: port, username: username,
        knownHostsFileURL: trustService.knownHostsFileURL, authentication: try buildAuthentication())
      let client = try NativeSSHMetricsClient(configuration: config)
      let result = try await Task.detached {
        try client.fetch()
      }.value
      metrics = result
      lastUpdated = Date()
    } catch is CancellationError {
    } catch {
      errorMessage = error.localizedDescription
      // A trust failure must not keep polling.
      if case NativeSSHError.hostVerificationFailed = error { stopPolling() }
    }
    isLoading = false
  }

  private func restartPolling() {
    stopPolling()
    guard pollInterval != .off else { return }
    let seconds = max(15, pollInterval.rawValue)
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
        guard !Task.isCancelled, let self else { return }
        // Polling only runs against an already-trusted endpoint; unknown/mismatch stops it.
        if self.trustChallenge == nil { self.refresh() } else { return }
      }
    }
  }

  private func stopPolling() {
    pollTask?.cancel()
    pollTask = nil
  }

  private func buildAuthentication() throws -> NativeSSHAuthentication {
    switch authMethod {
    case .agent:
      guard let sock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], !sock.isEmpty,
        FileManager.default.fileExists(atPath: sock)
      else {
        throw NativeSSHError.missingAgentSocket(AppLocalization.string("No active SSH agent found (SSH_AUTH_SOCK missing or invalid)."))
      }
      return .agent(socketURL: URL(fileURLWithPath: sock))
    case .keychain:
      guard let id = selectedCredentialID,
        let cred = availableCredentials.first(where: { $0.id == id }),
        let reference = KeychainCredentialReference.decode(cred.keychainItemID)
      else { throw NativeSSHError.invalidAskpassReference }
      return .keychainAskpass(service: reference.service, account: reference.account, identityFile: nil)
    }
  }
}
