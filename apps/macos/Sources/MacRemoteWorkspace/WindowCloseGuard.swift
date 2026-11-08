import AppKit
import SwiftUI

/// Keeps the hosting window's existing delegate while intercepting close requests.
struct WindowCloseGuard: NSViewRepresentable {
  let shouldClose: () -> Bool

  func makeCoordinator() -> Coordinator { Coordinator(shouldClose: shouldClose) }
  func makeNSView(context: Context) -> HostingView {
    let view = HostingView()
    view.coordinator = context.coordinator
    return view
  }
  func updateNSView(_ view: HostingView, context: Context) {
    context.coordinator.shouldClose = shouldClose
    context.coordinator.attach(to: view.window)
  }
  static func dismantleNSView(_ view: HostingView, coordinator: Coordinator) {
    coordinator.detach()
  }

  final class HostingView: NSView {
    var coordinator: Coordinator?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      coordinator?.attach(to: window)
    }
  }

  final class Coordinator: NSObject, NSWindowDelegate {
    var shouldClose: () -> Bool
    private weak var window: NSWindow?
    private weak var previous: NSWindowDelegate?

    init(shouldClose: @escaping () -> Bool) { self.shouldClose = shouldClose }

    @MainActor func attach(to newWindow: NSWindow?) {
      guard window !== newWindow else { return }
      detach()
      guard let newWindow else { return }
      window = newWindow
      previous = newWindow.delegate
      newWindow.delegate = self
    }

    @MainActor func detach() {
      if window?.delegate === self { window?.delegate = previous }
      window = nil
      previous = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
      shouldClose() && (previous?.windowShouldClose?(sender) ?? true)
    }

    override func responds(to selector: Selector!) -> Bool {
      super.responds(to: selector) || (previous?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
      if previous?.responds(to: selector) == true { return previous }
      return super.forwardingTarget(for: selector)
    }
  }
}
