import AppCore
import SwiftUI

@MainActor
final class RdpSessionWindowRegistry: ObservableObject {
  static let shared = RdpSessionWindowRegistry()

  struct Entry {
    let host: HostRecord
    let session: NativeRdpSession
    let makeSession: () -> NativeRdpSession
  }

  @Published private(set) var entries: [String: Entry] = [:]

  func open(windowID: String, host: HostRecord, makeSession: @escaping () -> NativeRdpSession) {
    let session = makeSession()
    entries[windowID] = Entry(host: host, session: session, makeSession: makeSession)
    AppLifecycle.shared.register(session)
  }

  func entry(for windowID: String) -> Entry? { entries[windowID] }

  func reconnect(windowID: String) {
    guard let previous = entries[windowID] else { return }
    let session = previous.makeSession()
    entries[windowID] = Entry(host: previous.host, session: session, makeSession: previous.makeSession)
    AppLifecycle.shared.register(session)
  }

  func close(windowID: String, sessionID: UUID) {
    guard entries[windowID]?.session.id == sessionID else { return }
    entries.removeValue(forKey: windowID)
  }
}

struct RdpSessionWindowView: View {
  @ObservedObject private var registry = RdpSessionWindowRegistry.shared
  let windowID: String

  var body: some View {
    Group {
      if let entry = registry.entry(for: windowID) {
        RdpEmbeddedSessionView(
          host: entry.host,
          session: entry.session,
          onReconnect: { registry.reconnect(windowID: windowID) }
        )
        .id(entry.session.id)
        .onDisappear { registry.close(windowID: windowID, sessionID: entry.session.id) }
      } else {
        UnavailableSessionView(title: AppLocalization.string("Remote desktop session ended"), symbol: "display")
      }
    }
    .background(RdpDefaultFullscreen())
  }
}

#if DEBUG
#Preview("RdpSessionWindowView") {
  RdpSessionWindowView(windowID: "preview-disconnected").frame(width: 800, height: 600)
}
#endif
