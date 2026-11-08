import AppKit
import SwiftUI

struct NativeSettingsView: View {
  var body: some View {
    Group {
      if #available(macOS 15, *) {
        TabView {
          Tab(AppLocalization.string("General"), systemImage: "gearshape") { GeneralSettings() }
          Tab(AppLocalization.string("Terminal"), systemImage: "terminal") { TerminalSettings() }
          Tab(AppLocalization.string("Connections"), systemImage: "network") { ConnectionSettings() }
        }
      } else {
        TabView {
          GeneralSettings().tabItem { Label(AppLocalization.string("General"), systemImage: "gearshape") }
          TerminalSettings().tabItem { Label(AppLocalization.string("Terminal"), systemImage: "terminal") }
          ConnectionSettings().tabItem { Label(AppLocalization.string("Connections"), systemImage: "network") }
        }
      }
    }
    .frame(minWidth: 480, idealWidth: 560, minHeight: 380, idealHeight: 440)
  }
}
