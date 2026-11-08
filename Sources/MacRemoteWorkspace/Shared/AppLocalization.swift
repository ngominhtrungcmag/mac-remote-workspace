import Foundation
import AppCore

enum AppLocalization {
  #if SWIFT_PACKAGE
  private static let resources = Bundle.module
  #else
  private static let resources = Bundle.main
  #endif

  static func string(_ key: String, locale: Locale? = nil) -> String {
    let preferredLanguage = locale.map(languageIdentifier(for:))
      ?? AppLanguage.current.locale.map(languageIdentifier(for:))
      ?? resources.preferredLocalizations.first
      ?? "en"
    let language = preferredLanguage.split(whereSeparator: { $0 == "-" || $0 == "_" })
      .first.map(String.init)?.lowercased() ?? "en"
    let selectedBundle = localizationBundle(for: language) ?? localizationBundle(for: "en") ?? resources

    if let value = translation(for: key, in: selectedBundle) {
      return value
    }
    if language != "en", let englishBundle = localizationBundle(for: "en"),
       let value = translation(for: key, in: englishBundle) {
      return value
    }
    return key
  }

  static func format(_ key: String, _ arguments: String..., locale: Locale? = nil) -> String {
    String(
      format: string(key, locale: locale),
      locale: locale,
      arguments: arguments.map { $0 as NSString }
    )
  }

  private static func languageIdentifier(for locale: Locale) -> String {
    locale.language.languageCode?.identifier ?? locale.identifier
  }

  private static func localizationBundle(for language: String) -> Bundle? {
    guard let url = resources.url(forResource: language, withExtension: "lproj") else {
      return nil
    }
    return Bundle(url: url)
  }

  private static func translation(for key: String, in bundle: Bundle) -> String? {
    let value = bundle.localizedString(forKey: key, value: nil, table: nil)
    return value == key ? nil : value
  }
}

extension AppDestination {
  var localizedTitle: String { AppLocalization.string(title) }
  var localizedEmptyStateTitle: String { AppLocalization.string(emptyState.title) }
  var localizedEmptyStateMessage: String { AppLocalization.string(emptyState.message) }
}

extension HostEnvironment {
  var localizedTitle: String { AppLocalization.string(title) }
}

extension CredentialKind {
  var localizedTitle: String { AppLocalization.string(title) }
}

extension AppLanguage {
  var localizedTitle: String { localizedTitle(locale: nil) }

  func localizedTitle(locale: Locale?) -> String {
    let key = switch self {
    case .system: "System default"
    case .vietnamese: "Tiếng Việt"
    case .english: "English"
    }
    return AppLocalization.string(key, locale: locale)
  }
}
