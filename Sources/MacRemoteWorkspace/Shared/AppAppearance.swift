import AppKit
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
  case system = "System", light = "Light", dark = "Dark"
  var id: String { rawValue }
  var localizedTitle: String { AppLocalization.string(rawValue) }

  @MainActor func apply() {
    NSApp.appearance = switch self {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
  }
}
