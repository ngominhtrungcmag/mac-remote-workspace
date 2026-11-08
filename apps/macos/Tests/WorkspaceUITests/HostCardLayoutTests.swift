import AppCore
import AppKit
import SwiftUI
import XCTest
@testable import MacRemoteWorkspace

final class HostCardLayoutTests: XCTestCase {
  @MainActor
  func testLongNamesExpandRatherThanTruncateAtNarrowWidth() {
    let short = cardHeight(name: "Development", address: "localhost")
    let long = cardHeight(
      name: "Customer production workspace with a very long descriptive host name",
      address: "production-database.internal.customer.example.com")
    XCTAssertGreaterThan(long, short)
  }

  @MainActor
  func testLightAndDarkAppearancesKeepCardWithinNarrowColumn() {
    for scheme in [ColorScheme.light, .dark] {
      let view = NSHostingView(rootView: card(name: "Production", address: "127.0.0.1")
        .environment(\.colorScheme, scheme)
        .frame(width: 250))
      XCTAssertEqual(view.fittingSize.width, 250, accuracy: 1)
      XCTAssertGreaterThan(view.fittingSize.height, 100)
    }
  }

  @MainActor
  private func cardHeight(name: String, address: String) -> CGFloat {
    NSHostingView(rootView: card(name: name, address: address).frame(width: 250)).fittingSize.height
  }

  @MainActor
  private func card(name: String, address: String) -> some View {
    HostCardView(
      host: HostRecord(id: "test", workspaceID: "workspace", groupID: nil,
                       displayName: name, address: address, environment: .production, version: 1),
      workspaceName: "Workspace", isSelected: true, onSelect: {}
    ) {
      Button("Connect SSH") {}
    }
  }
}
