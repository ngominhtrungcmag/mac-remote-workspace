import AppCore
import AppKit
import SwiftTerm
import SwiftUI

/// VT100/xterm emulator for an SSH PTY (SwiftTerm).
/// Remote-initiated side effects are denied: OSC 52 clipboard writes and OSC 8 link opens are ignored.
struct SSHTerminalView: NSViewRepresentable {
  let viewModel: SSHSessionViewModel
  /// True while the session is running; focus moves to the terminal on the transition.
  var isActive = false
  @Environment(\.colorScheme) private var colorScheme
  @AppStorage("terminalFontSize") private var fontSize = 13.0
  @AppStorage("terminalCursorStyle") private var cursorStyle: TerminalCursorStyle = .blinkBlock
  @AppStorage("terminalOptionAsMeta") private var optionAsMeta = true

  func makeCoordinator() -> Coordinator { Coordinator(viewModel: viewModel) }

  func makeNSView(context: Context) -> TerminalView {
    let view = TerminalView(frame: .zero)
    view.terminalDelegate = context.coordinator
    view.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    view.setAccessibilityLabel(AppLocalization.format("SSH terminal for %1$@", String(describing: viewModel.host.displayName)))
    viewModel.terminalFeed = { [weak view] bytes in view?.feed(byteArray: bytes[...]) }
    viewModel.terminalReset = { [weak view] in view?.getTerminal().resetToInitialState() }
    return view
  }

  func updateNSView(_ nsView: TerminalView, context: Context) {
    // Follow system light/dark (colorScheme read above triggers this update on change).
    nsView.nativeBackgroundColor = .textBackgroundColor
    nsView.nativeForegroundColor = .textColor
    nsView.optionAsMetaKey = optionAsMeta
    if context.coordinator.cursorStyle != cursorStyle {
      context.coordinator.cursorStyle = cursorStyle
      nsView.getTerminal().setCursorStyle(cursorStyle.swiftTerm)
    }
    if nsView.font.pointSize != fontSize {
      nsView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }
    if isActive && !context.coordinator.didFocus {
      context.coordinator.didFocus = true
      DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
    } else if !isActive {
      context.coordinator.didFocus = false
    }
    _ = colorScheme
  }

  static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
    let vm = coordinator.viewModel
    Task { @MainActor in
      vm.terminalFeed = nil
      vm.terminalReset = nil
    }
  }

  @MainActor
  final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
    let viewModel: SSHSessionViewModel
    var didFocus = false
    var cursorStyle: TerminalCursorStyle?
    init(viewModel: SSHSessionViewModel) { self.viewModel = viewModel }

    func send(source: TerminalView, data: ArraySlice<UInt8>) { viewModel.sendRaw(data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
      guard newCols > 0, newRows > 0, newCols <= Int(UInt16.max), newRows <= Int(UInt16.max) else { return }
      viewModel.resize(rows: UInt16(newRows), columns: UInt16(newCols))
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    /// Reached only on user Cmd-click: open validated http/https after showing the full URL.
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
      guard let url = TerminalSecurityPolicy.validatedLinkURL(link) else { return }
      let alert = NSAlert()
      alert.messageText = AppLocalization.string("Open link from remote terminal?")
      alert.informativeText = url.absoluteString
      alert.addButton(withTitle: AppLocalization.string("Cancel"))
      alert.addButton(withTitle: AppLocalization.string("Open"))
      if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(url) }
    }
    func clipboardCopy(source: TerminalView, content: Data) {
      guard TerminalSecurityPolicy.allowsRemoteClipboardWrite else { return }  // OSC 52 denied
    }
  }
}

enum TerminalCursorStyle: String, CaseIterable, Identifiable {
  case blinkBlock = "Block (blinking)", steadyBlock = "Block"
  case blinkBar = "Bar (blinking)", steadyBar = "Bar"
  case blinkUnderline = "Underline (blinking)", steadyUnderline = "Underline"
  var id: String { rawValue }
  var localizedTitle: String { AppLocalization.string(rawValue) }

  var swiftTerm: CursorStyle {
    switch self {
    case .blinkBlock: .blinkBlock
    case .steadyBlock: .steadyBlock
    case .blinkBar: .blinkBar
    case .steadyBar: .steadyBar
    case .blinkUnderline: .blinkUnderline
    case .steadyUnderline: .steadyUnderline
    }
  }
}
