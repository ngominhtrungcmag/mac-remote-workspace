import AppCore
import SwiftUI

/// Hosts several independent SSH sessions (one view model, trust flow and PTY per tab) for one host.
/// All tabs stay alive while hidden; closing a tab or the sheet disconnects its session.
struct SSHSessionTabsSheet: View {
  @Environment(\.dismiss) private var dismiss
  private let host: HostRecord
  private let group: HostGroupRecord?
  @State private var tabs: [Int] = [1]
  @State private var selected = 1
  @State private var nextID = 2
  @State private var running: Set<Int> = []
  @State private var live: Set<Int> = []
  @State private var usernames: [Int: String] = [:]
  @State private var pendingCloseTab: Int?

  private static let maxTabs = 8

  init(host: HostRecord, group: HostGroupRecord? = nil) {
    self.host = host
    self.group = group
    // Restored tabs are placeholders only: unconnected, no command replay (US-014).
    let count = Self.store.tabCount(forHost: host.id)
    _tabs = State(initialValue: Array(1...count))
    _selected = State(initialValue: 1)
    _nextID = State(initialValue: count + 1)
  }

  private static let store = SSHSessionRestoreStore(url: SSHSessionRestoreStore.defaultURL)

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        tabBar
        Divider()
        ZStack {
          ForEach(tabs, id: \.self) { id in
            SSHSessionSheet(host: host, group: group, embedded: true, connectOnOpen: id == 1, onUsernameChange: { usernames[id] = $0 }, onLiveChange: { isLive in
              if isLive { live.insert(id) } else { live.remove(id) }
            }) { isRunning in
              if isRunning { running.insert(id) } else { running.remove(id) }
            }
            .opacity(id == selected ? 1 : 0)
            .allowsHitTesting(id == selected)
            .accessibilityHidden(id != selected)
          }
        }
      }
      .background(shortcuts)
      .onChange(of: tabs) { _, new in Self.store.save(hostID: host.id, tabCount: new.count) }
      .navigationTitle(AppLocalization.format("SSH: %1$@", String(describing: host.displayName)))
      .interactiveDismissDisabled(!live.isEmpty)  // Esc must not silently kill sessions
      .toolbar {
        ToolbarItem(placement: .principal) { EnvironmentBadge(environment: host.environment) }
      }
      .background(WindowCloseGuard {
        guard !live.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = AppLocalization.string("Close and disconnect?")
        alert.addButton(withTitle: AppLocalization.string("Keep Sessions"))
        alert.addButton(withTitle: AppLocalization.format(
          live.count == 1 ? "Disconnect %1$@ Session and Close" : "Disconnect %1$@ Sessions and Close",
          String(live.count)
        ))
        return alert.runModal() == .alertSecondButtonReturn
      })
      .confirmationDialog(
        AppLocalization.string("Close this session?"),
        isPresented: Binding(get: { pendingCloseTab != nil }, set: { if !$0 { pendingCloseTab = nil } })
      ) {
        Button(AppLocalization.string("Disconnect and Close Tab"), role: .destructive) {
          if let id = pendingCloseTab { removeTab(id) }
          pendingCloseTab = nil
        }
        Button(AppLocalization.string("Keep Session"), role: .cancel) { pendingCloseTab = nil }
      } message: {
        Text(AppLocalization.string("The running SSH session in this tab will end."))
      }
    }
  }

  /// Hidden buttons carrying the tab shortcuts (⌘T, ⌘W, ⌘⇧[, ⌘⇧]).
  private var shortcuts: some View {
    ZStack {
      Button(AppLocalization.string("New Tab")) { newTab() }.keyboardShortcut("t", modifiers: .command)
      Button(AppLocalization.string("Close Tab")) { closeTab(selected) }.keyboardShortcut("w", modifiers: .command)
      Button(AppLocalization.string("Previous Tab")) { switchTab(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
      Button(AppLocalization.string("Next Tab")) { switchTab(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
    }
    .opacity(0)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private var tabBar: some View {
    ScrollView(.horizontal) {
    HStack(spacing: 4) {
      ForEach(Array(tabs.enumerated()), id: \.element) { index, id in
        let isRunning = running.contains(id)
        HStack(spacing: 6) {
          Button { selected = id } label: {
            HStack(spacing: 6) {
              Image(systemName: isRunning ? "circle.fill" : "circle")
                .font(.caption2)
                .foregroundStyle(isRunning ? Color(nsColor: .systemGreen) : Color.secondary)
              Text("\(usernames[id] ?? NSUserName())@\(host.address)")
              Text(isRunning ? AppLocalization.string("Connected") : AppLocalization.string("Not connected"))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
                    .accessibilityLabel(AppLocalization.format(
                      "Session %1$@, %2$@",
                      String(index + 1),
                      AppLocalization.string(isRunning ? "connected" : "not connected")
                    ))
          .accessibilityAddTraits(id == selected ? .isSelected : [])
          Button(AppLocalization.string("Close session"), systemImage: "xmark") { closeTab(id) }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .help(AppLocalization.string("Close session (\u{2318}W)"))
            .accessibilityLabel(AppLocalization.format("Close session %1$@", String(describing: index + 1)))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(id == selected ? Color.accentColor.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
      }
      Button(AppLocalization.string("New session"), systemImage: "plus", action: newTab)
        .labelStyle(.iconOnly)
        .disabled(tabs.count >= Self.maxTabs)
        .help(AppLocalization.string("New SSH session tab (\u{2318}T)"))
        .accessibilityLabel(AppLocalization.string("New SSH session tab"))
      Spacer()
    }
    .padding(8)
    }
    .fixedSize(horizontal: false, vertical: true)
    .background(.bar)
  }

  private func newTab() {
    guard tabs.count < Self.maxTabs else { return }
    tabs.append(nextID)
    selected = nextID
    nextID += 1
  }

  private func switchTab(_ delta: Int) {
    guard let i = tabs.firstIndex(of: selected) else { return }
    selected = tabs[(i + delta + tabs.count) % tabs.count]
  }

  private func closeTab(_ id: Int) {
    if live.contains(id) { pendingCloseTab = id } else { removeTab(id) }
  }

  private func removeTab(_ id: Int) {
    guard tabs.count > 1 else { return dismiss() }  // last tab closes the window
    guard let i = tabs.firstIndex(of: id) else { return }
    tabs.remove(at: i)  // removal triggers onDisappear -> disconnect
    running.remove(id)
    live.remove(id)
    usernames.removeValue(forKey: id)
    if selected == id { selected = tabs[min(i, tabs.count - 1)] }
  }
}

#if DEBUG
// Tab 1 auto-connects only with saved settings; the fixture host has none.
#Preview("SSHSessionTabsSheet") {
  SSHSessionTabsSheet(host: PreviewFixtures.host).frame(width: 1000, height: 650)
}
#endif
