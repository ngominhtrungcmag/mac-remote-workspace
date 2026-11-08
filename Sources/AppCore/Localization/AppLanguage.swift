import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
  case system = "system"
  case vietnamese = "vi"
  case english = "en"

  public static let preferenceKey = "appLanguage"

  public var id: String { rawValue }

  public var locale: Locale? {
    switch self {
    case .system: nil
    case .vietnamese: Locale(identifier: "vi")
    case .english: Locale(identifier: "en")
    }
  }

  public static var current: AppLanguage {
    UserDefaults.standard.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .system
  }
}
