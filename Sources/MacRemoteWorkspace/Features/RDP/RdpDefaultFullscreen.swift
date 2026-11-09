import AppKit
import SwiftUI

struct RdpDefaultFullscreen: NSViewRepresentable {
  func makeNSView(context: Context) -> HostingView { HostingView() }
  func updateNSView(_ view: HostingView, context: Context) { view.scheduleEntry() }

  final class HostingView: NSView {
    private static let handledWindows = NSHashTable<NSWindow>.weakObjects()

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      NotificationCenter.default.removeObserver(self)
      if let window {
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey),
                                               name: NSWindow.didBecomeKeyNotification, object: window)
      }
      scheduleEntry()
    }

    func scheduleEntry() {
      DispatchQueue.main.async { [weak self] in self?.enterIfReady() }
    }

    @objc private func windowBecameKey() { enterIfReady() }

    func enterIfReady() {
      guard let window, window.isVisible, !Self.handledWindows.contains(window) else { return }
      Self.handledWindows.add(window)
      if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }
  }
}
