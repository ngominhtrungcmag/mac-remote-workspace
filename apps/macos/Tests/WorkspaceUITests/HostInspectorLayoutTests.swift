import AppCore
import AppKit
import SwiftUI
import XCTest
@testable import MacRemoteWorkspace

final class HostInspectorLayoutTests: XCTestCase {
  @MainActor
  func testInspectorFitsNarrowWidthInBothAppearances() throws {
    let host = HostRecord(id: "preview", workspaceID: "workspace", groupID: nil,
                          displayName: "Development Server", address: "127.0.0.1",
                          environment: .development, version: 1)
    for scheme in [ColorScheme.light, .dark] {
      let inspector = HostDetailInspectorView(
        host: host, workspaces: [], groups: [], onConnectSSH: { _ in },
        onLaunchRDP: { _ in }, onBrowseSFTP: { _ in }, onShowMetrics: { _ in },
        onEdit: { _ in }, onMove: { _, _, _ in }, onDelete: { _ in })
        .environment(\.colorScheme, scheme)
        .frame(width: 300, height: 800)
      let view = NSHostingView(rootView: inspector)
      view.frame = NSRect(x: 0, y: 0, width: 300, height: 800)
      let window = NSWindow(contentRect: view.frame, styleMask: [.borderless],
                            backing: .buffered, defer: false)
      window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
      window.contentView = view
      window.orderFrontRegardless()
      defer { window.orderOut(nil) }
      RunLoop.main.run(until: Date().addingTimeInterval(0.3))
      view.layoutSubtreeIfNeeded()
      view.displayIfNeeded()
      XCTAssertEqual(view.fittingSize.width, 300, accuracy: 1)
      let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      try image.write(to: URL(fileURLWithPath: "/tmp/mrw-inspector-\(scheme == .dark ? "dark" : "light").png"))
    }
  }
}
