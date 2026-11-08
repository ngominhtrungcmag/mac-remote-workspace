import Foundation

public enum AppCoreLocalization {
  public static func string(_ key: String, locale: Locale? = nil) -> String {
    let preferredLanguage = locale.map(languageIdentifier(for:))
      ?? AppLanguage.current.locale.map(languageIdentifier(for:))
      ?? Bundle.module.preferredLocalizations.first
      ?? "en"
    let language = preferredLanguage.split(whereSeparator: { $0 == "-" || $0 == "_" })
      .first.map(String.init)?.lowercased() ?? "en"
    let selectedBundle = localizationBundle(for: language) ?? localizationBundle(for: "en") ?? .module

    if let value = translation(for: key, in: selectedBundle) {
      return value
    }
    if language != "en", let englishBundle = localizationBundle(for: "en"),
       let value = translation(for: key, in: englishBundle) {
      return value
    }
    return key
  }

  public static func format(_ key: String, _ arguments: String..., locale: Locale? = nil) -> String {
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
    guard let url = Bundle.module.url(forResource: language, withExtension: "lproj") else {
      return nil
    }
    return Bundle(url: url)
  }

  private static func translation(for key: String, in bundle: Bundle) -> String? {
    let value = bundle.localizedString(forKey: key, value: nil, table: nil)
    return value == key ? nil : value
  }
}

public protocol AppCoreLocalizedError: LocalizedError {
  func displayDescription(locale: Locale?) -> String?
}

public extension AppCoreLocalizedError {
  var errorDescription: String? { displayDescription(locale: nil) }
}

public extension AppDestination {
  func localizedTitle(locale: Locale? = nil) -> String {
    AppCoreLocalization.string(title, locale: locale)
  }

  func localizedEmptyStateTitle(locale: Locale? = nil) -> String {
    AppCoreLocalization.string(emptyState.title, locale: locale)
  }

  func localizedEmptyStateMessage(locale: Locale? = nil) -> String {
    AppCoreLocalization.string(emptyState.message, locale: locale)
  }
}

public extension HostEnvironment {
  func localizedTitle(locale: Locale? = nil) -> String {
    AppCoreLocalization.string(title, locale: locale)
  }
}

public extension CredentialKind {
  func localizedTitle(locale: Locale? = nil) -> String {
    AppCoreLocalization.string(title, locale: locale)
  }
}
