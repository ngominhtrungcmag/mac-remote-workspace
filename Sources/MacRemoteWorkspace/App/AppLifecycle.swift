import AppCore
import AppKit

/// Owns the shared transfer queue and tracks live SSH sessions so quit can be confirmed (FR-028 / TC-016).
/// SSH tabs each own an `SSHSessionViewModel`; embedded RDP sessions register as `NativeRdpSession`.
@MainActor
final class AppLifecycle {
  static let shared = AppLifecycle()

  let transferQueue = SFTPTransferQueue()
  private var sessions: [WeakSession] = []

  private var rdpSessions: [WeakRdp] = []

  private struct WeakSession { weak var viewModel: SSHSessionViewModel? }
  private struct WeakRdp { weak var session: NativeRdpSession? }

  func register(_ session: NativeRdpSession) {
    rdpSessions.removeAll { $0.session == nil }
    rdpSessions.append(WeakRdp(session: session))
  }

  private var liveRdpSessions: [NativeRdpSession] {
    rdpSessions.compactMap(\.session).filter {
      switch $0.state {
      case .idle, .disconnecting, .disconnected, .failed: return false
      default: return true
      }
    }
  }

  func register(_ viewModel: SSHSessionViewModel) {
    sessions.removeAll { $0.viewModel == nil }
    sessions.append(WeakSession(viewModel: viewModel))
  }

  private var liveSessions: [SSHSessionViewModel] {
    sessions.compactMap(\.viewModel).filter(\.hasLiveSession)
  }

  func shouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let transfers = transferQueue.hasActiveTransfers
    let live = liveSessions
    let rdp = liveRdpSessions
    guard transfers || !live.isEmpty || !rdp.isEmpty else { return .terminateNow }

    var parts: [String] = []
    if transfers { parts.append(AppLocalization.string("active SFTP transfers")) }
    if !live.isEmpty {
      parts.append(AppLocalization.format(live.count == 1 ? "%1$@ live SSH session" : "%1$@ live SSH sessions", String(live.count)))
    }
    if !rdp.isEmpty {
      parts.append(AppLocalization.format(rdp.count == 1 ? "%1$@ live RDP session" : "%1$@ live RDP sessions", String(rdp.count)))
    }
    let alert = NSAlert()
    alert.messageText = AppLocalization.string("Quit Mac Remote Workspace?")
    alert.informativeText = AppLocalization.format(
      "Quitting will cancel %1$@. Unfinished transfers are discarded.",
      parts.joined(separator: AppLocalization.string(" and "))
    )
    alert.addButton(withTitle: AppLocalization.string("Keep Running"))
    alert.addButton(withTitle: AppLocalization.string("Quit"))
    let confirm = UserDefaults.standard.object(forKey: "confirmQuit") as? Bool ?? true
    guard !confirm || alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }

    Task { @MainActor in
      await transferQueue.cancelAllAndWait()
      live.forEach { $0.terminateSync() }
      for session in rdp { await session.disconnect() }
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}

/// Thin adaptor target; SwiftUI instantiates its own delegate, so forward to the shared state.
final class AppDelegate: NSObject, NSApplicationDelegate {
  @MainActor
  func applicationDidFinishLaunching(_ notification: Notification) {
    try? SSHPasswordAuthenticationService.purgeEphemeralCredentials()
    (UserDefaults.standard.string(forKey: "appearance").flatMap(AppAppearance.init) ?? .system).apply()
  }

  @MainActor
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    AppLifecycle.shared.shouldTerminate(sender)
  }
}
