import Foundation
import Security
import XCTest
@testable import AppCore

final class AppCoreLocalizationTests: XCTestCase {
  private let english = Locale(identifier: "en_US")
  private let vietnamese = Locale(identifier: "vi_VN")

  func testExplicitLocaleSelectionAndEnglishFallback() {
    XCTAssertEqual(
      AppCoreLocalization.string("The macOS Keychain is unavailable in this environment.", locale: english),
      "The macOS Keychain is unavailable in this environment."
    )
    XCTAssertEqual(
      AppCoreLocalization.string("The macOS Keychain is unavailable in this environment.", locale: vietnamese),
      "Keychain macOS không khả dụng trong môi trường này."
    )
    XCTAssertEqual(
      AppCoreLocalization.string("The macOS Keychain is unavailable in this environment.", locale: Locale(identifier: "fr_FR")),
      "The macOS Keychain is unavailable in this environment."
    )
  }

  func testLanguagePreferenceDefaultsToSystemAndFallsBackForUnknownValues() {
    withLanguagePreference {
      UserDefaults.standard.removeObject(forKey: AppLanguage.preferenceKey)
      XCTAssertEqual(AppLanguage.current, .system)
      XCTAssertTrue([
        "The macOS Keychain is unavailable in this environment.",
        "Keychain macOS không khả dụng trong môi trường này.",
      ].contains(AppCoreLocalization.string("The macOS Keychain is unavailable in this environment.")))

      UserDefaults.standard.set("unsupported", forKey: AppLanguage.preferenceKey)
      XCTAssertEqual(AppLanguage.current, .system)
      XCTAssertTrue([
        "The macOS Keychain is unavailable in this environment.",
        "Keychain macOS không khả dụng trong môi trường này.",
      ].contains(AppCoreLocalization.string("The macOS Keychain is unavailable in this environment.")))
    }
  }

  func testPersistedLanguagePreferenceDrivesAppCoreLocalization() {
    withLanguagePreference {
      let key = "The macOS Keychain is unavailable in this environment."
      for (language, expected) in [
        (AppLanguage.english, key),
        (AppLanguage.vietnamese, "Keychain macOS không khả dụng trong môi trường này."),
      ] {
        UserDefaults.standard.set(language.rawValue, forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(UserDefaults.standard.string(forKey: AppLanguage.preferenceKey), language.rawValue)
        XCTAssertEqual(AppLanguage.current, language)
        XCTAssertEqual(AppCoreLocalization.string(key), expected)
      }
    }
  }

  func testEveryUserFacingAppCoreErrorCaseHasVietnameseText() {
    let errors: [AppCoreLocalizedError] = [
      CredentialStoreError.unavailable(-25291),
      CredentialStoreError.deniedOrLocked(errSecUserCanceled),
      CredentialStoreError.deniedOrLocked(errSecInteractionNotAllowed),
      CredentialStoreError.deniedOrLocked(-25293),
      CredentialStoreError.notFound,
      CredentialStoreError.duplicate,
      CredentialStoreError.invalidReference,
      CredentialStoreError.invalidSecret,
      CredentialStoreError.unexpected(-25291),

      SFTPError.invalidPath("/srv/%1$@"),
      SFTPError.permissionDenied("/srv/private"),
      SFTPError.fileNotFound("/srv/missing"),
      SFTPError.collision("/srv/existing"),
      SFTPError.remoteError("server diagnostic"),
      SFTPError.connectionFailed("transport diagnostic"),
      SFTPError.cancelled,
      SFTPError.askpassUnavailable,

      RdpCertificateTrustError.invalidHost("rdp.example"),
      RdpCertificateTrustError.invalidPort(3389),
      RdpCertificateTrustError.invalidFingerprint(String(repeating: "a", count: 64)),
      RdpCertificateTrustError.challengeExpired,
      RdpCertificateTrustError.challengeNonceMismatch,
      RdpCertificateTrustError.mismatchBlocked(details: "fingerprint mismatch"),
      RdpCertificateTrustError.persistenceFailed("system diagnostic"),

      InventoryImportExportError.unsupportedSchemaVersion(99),
      InventoryImportExportError.invalidJSON,
      InventoryImportExportError.duplicateIdentifier("workspace"),
      InventoryImportExportError.invalidCSV("File is empty."),
      InventoryImportExportError.secretsDetectedInExport,
      InventoryImportExportError.emptyDocument,

      SerialError.invalidConfig("port must be a /dev/cu.* device"),
      SerialError.invalidConfig("unsupported baud rate 1234"),
      SerialError.invalidConfig("data bits must be 5-8"),
      SerialError.invalidConfig("stop bits must be 1 or 2"),
      SerialError.notFound("/dev/cu.test"),
      SerialError.busy("/dev/cu.test"),
      SerialError.permissionDenied("/dev/cu.test"),
      SerialError.system("/dev/cu.test", 13),
      SerialError.closed,

      RdpMetalError.metalDeviceUnavailable,
      RdpMetalError.invalidFramebufferGeometry("invalid bounds"),
      RdpMetalError.textureAllocationFailed,
      RdpMetalError.commandQueueUnavailable,
      RdpMetalError.renderPipelineUnavailable,

      RdpLauncherError.invalidEndpoint("Invalid IPv6 address."),
      RdpLauncherError.clientNotFound,
      RdpLauncherError.launchFailed("system diagnostic"),

      RemoteHostMetricsError.unsupportedOperatingSystem("FreeBSD"),
      RemoteHostMetricsError.malformedOutput("missing OS"),
      RemoteHostMetricsError.commandFailed("remote diagnostic"),
      RemoteHostMetricsError.cancelled,

      OrganizationNameValidationError.emptyName,
      OrganizationNameValidationError.nameTooLong,
      OrganizationNameValidationError.invalidName,
      CredentialRefValidationError.emptyLabel,
      CredentialRefValidationError.labelTooLong,
      CredentialRefValidationError.invalidLabel,
      HostValidationError.emptyDisplayName,
      HostValidationError.displayNameTooLong,
      HostValidationError.invalidDisplayName,
      HostValidationError.invalidAddress,

      SQLiteRepositoryError.sqlite(code: 1, message: "database diagnostic"),
      SQLiteRepositoryError.unsupportedSchemaVersion(99),
      SQLiteRepositoryError.missingMigration("0006.sql"),
      SQLiteRepositoryError.foreignKeyViolation,
      SQLiteRepositoryError.localPermissionDenied,
      SQLiteRepositoryError.invalidStoredEnvironment,
      SQLiteRepositoryError.workspaceNotFound,
      SQLiteRepositoryError.workspaceRequired,
      SQLiteRepositoryError.workspaceChanged,
      SQLiteRepositoryError.workspaceInUse,
      SQLiteRepositoryError.groupNotFound,
      SQLiteRepositoryError.groupChanged,
      SQLiteRepositoryError.groupNameAlreadyExists,
      SQLiteRepositoryError.groupWorkspaceMismatch,
      SQLiteRepositoryError.hostNotFound,
      SQLiteRepositoryError.hostChanged,
      SQLiteRepositoryError.hostInUse,
      SQLiteRepositoryError.commandSnippetNotFound,
      SQLiteRepositoryError.commandSnippetChanged,
      SQLiteRepositoryError.commandSnippetOwnerNotFound,
      SQLiteRepositoryError.invalidStoredCommandSnippet,
      SQLiteRepositoryError.credentialRefNotFound,
      SQLiteRepositoryError.credentialRefChanged,
      SQLiteRepositoryError.credentialRefInUse,
      SQLiteRepositoryError.invalidStoredCredentialRef,
      SQLiteRepositoryError.closed,

      SSHHostTrustError.invalidHost("ssh.example"),
      SSHHostTrustError.invalidPort(22),
      SSHHostTrustError.probeFailed("ssh-keyscan diagnostic"),
      SSHHostTrustError.hostKeyNotFound(host: "ssh.example", port: 22),
      SSHHostTrustError.parsingFailed("ssh-keygen diagnostic"),
      SSHHostTrustError.knownHostsUnparseable("known_hosts diagnostic"),
      SSHHostTrustError.knownHostsFileUnwritable("/tmp/known_hosts"),
      SSHHostTrustError.subprocessTimedOut("/usr/bin/ssh-keyscan"),
      SSHHostTrustError.staleChallenge,
      SSHHostTrustError.challengeMismatch(details: "challenge diagnostic"),
      SSHHostTrustError.mismatchBlocked(details: "fingerprint mismatch"),

      RdpSessionError.unavailable,
      RdpSessionError.invalidEndpoint("Host or port is invalid."),
      RdpSessionError.dnsResolutionFailed("rdp.example"),
      RdpSessionError.tcpConnectionFailed("connection refused"),
      RdpSessionError.tlsHandshakeFailed("TLS diagnostic"),
      RdpSessionError.certificateMismatch(details: "fingerprint mismatch"),
      RdpSessionError.credentialUnavailable("Keychain diagnostic"),
      RdpSessionError.protocolViolation("protocol diagnostic"),
      RdpSessionError.helperProcessFailed("helper diagnostic"),

      NativeSSHError.invalidHost("ssh.example"),
      NativeSSHError.invalidPort(22),
      NativeSSHError.invalidUsername("user"),
      NativeSSHError.missingKnownHostsFile("/tmp/known_hosts"),
      NativeSSHError.missingIdentityFile("/tmp/id_ed25519"),
      NativeSSHError.missingAgentSocket("/tmp/agent.sock"),
      NativeSSHError.hostVerificationFailed(details: "host-key diagnostic"),
      NativeSSHError.authenticationFailed(details: "ProxyJump requires SSH agent authentication."),
      NativeSSHError.connectionFailed(details: "transport diagnostic"),
      NativeSSHError.systemCallFailed("write", 5),
      NativeSSHError.sessionAlreadyRunning,
      NativeSSHError.sessionNotRunning,
      NativeSSHError.ptyClosed,
      NativeSSHError.operationTimedOut,
      NativeSSHError.invalidTunnelHost,
      NativeSSHError.tunnelLimitReached,
      NativeSSHError.invalidAskpassReference,
      NativeSSHError.askpassUnavailable,

      RdpCredentialError.missingCredentialReference,
      RdpCredentialError.invalidCredentialReference("credential-id"),
      RdpCredentialError.credentialNotFoundInKeychain,
      RdpCredentialError.emptyPassword,
      RdpCredentialError.emptyUsername,
      RdpCredentialError.keychainAccessFailed("Keychain diagnostic"),

      CommandSnippetValidationError.emptyTitle,
      CommandSnippetValidationError.titleTooLong,
      CommandSnippetValidationError.invalidTitle,
      CommandSnippetValidationError.emptyCommand,
      CommandSnippetValidationError.commandTooLong,
      CommandSnippetValidationError.invalidCommand,
      CommandSnippetValidationError.possibleSecret,
      CommandSnippetValidationError.invalidScope,
      CommandSnippetSendError.scopeDoesNotMatchTarget,
      CommandSnippetSendError.noPendingReview,
      CommandSnippetSendError.reviewIsStale,
      CommandSnippetSendError.targetChanged,
      CommandSnippetSendError.sessionNotActive,
      CommandSnippetSendError.invalidSnippet,
    ]

    for error in errors {
      let english = error.displayDescription(locale: english) ?? ""
      let vietnamese = error.displayDescription(locale: vietnamese) ?? ""
      XCTAssertFalse(english.isEmpty, "Missing English description for \(type(of: error))")
      XCTAssertFalse(vietnamese.isEmpty, "Missing Vietnamese description for \(type(of: error))")
      XCTAssertNotEqual(english, vietnamese, "Untranslated \(type(of: error)): \(english)")
    }
  }

  func testQuickConnectValidationErrorsHaveCatalogEntriesAndLocalizedText() throws {
    let englishCatalog = try catalog(for: "en")
    let vietnameseCatalog = try catalog(for: "vi")
    let cases: [(QuickConnectValidationError, String, String)] = [
      (.emptyInput, "Enter a host address or connection URL.", "Nhập địa chỉ máy chủ hoặc URL kết nối."),
      (.inputTooLong, "The connection target is too long.", "Đích kết nối quá dài."),
      (.containsControlCharacters, "The connection target cannot contain control characters or whitespace.", "Đích kết nối không được chứa ký tự điều khiển hoặc khoảng trắng."),
      (.missingProtocol, "Choose SSH or RDP, or enter an ssh:// or rdp:// URL.", "Chọn SSH hoặc RDP, hoặc nhập URL ssh:// hay rdp://."),
      (.unsupportedProtocol, "Only ssh:// and rdp:// URLs are supported.", "Chỉ hỗ trợ URL ssh:// và rdp://."),
      (.passwordInTargetNotAllowed, "Do not include a password in the connection URL.", "Không đưa mật khẩu vào URL kết nối."),
      (.queryOrFragmentNotAllowed, "Connection URLs cannot include query parameters or fragments.", "URL kết nối không được chứa tham số truy vấn hoặc phần fragment."),
      (.pathOrCommandNotAllowed, "Connection targets cannot include paths, commands, or options.", "Đích kết nối không được chứa đường dẫn, lệnh hoặc tùy chọn."),
      (.invalidSyntax, "Enter a valid target such as ssh://user@host:22 or rdp://host:3389.", "Nhập đích hợp lệ, chẳng hạn ssh://user@host:22 hoặc rdp://host:3389."),
      (.invalidUsername, "Enter a valid SSH username without leading '-' or special characters.", "Nhập tên người dùng SSH hợp lệ, không bắt đầu bằng '-' hoặc chứa ký tự đặc biệt."),
      (.usernameNotSupportedForRDP, "Do not include a username in an rdp:// URL; enter credentials in the RDP connection step.", "Không đưa tên người dùng vào URL rdp://; hãy nhập thông tin xác thực ở bước kết nối RDP."),
      (.invalidHost, "Enter a valid DNS hostname, IPv4 address, or bracketed IPv6 address.", "Nhập tên máy chủ DNS, địa chỉ IPv4 hoặc địa chỉ IPv6 trong dấu ngoặc vuông hợp lệ."),
      (.invalidPort, "Port must be between 1 and 65535.", "Cổng phải nằm trong khoảng 1 đến 65535."),
    ]

    for (error, expectedEnglish, expectedVietnamese) in cases {
      XCTAssertEqual(englishCatalog[expectedEnglish], expectedEnglish, "\(error)")
      XCTAssertEqual(vietnameseCatalog[expectedEnglish], expectedVietnamese, "\(error)")
      XCTAssertEqual(error.displayDescription(locale: english), expectedEnglish, "\(error)")
      XCTAssertEqual(error.displayDescription(locale: vietnamese), expectedVietnamese, "\(error)")
    }
  }

  func testFormattedErrorsPreserveDynamicDiagnosticText() {
    let error = NativeSSHError.authenticationFailed(details: "ProxyJump requires SSH agent authentication.")
    XCTAssertEqual(
      error.displayDescription(locale: vietnamese),
      "Xác thực SSH thất bại: ProxyJump requires SSH agent authentication."
    )
    XCTAssertTrue(
      SFTPError.invalidPath("/srv/%1$@").displayDescription(locale: vietnamese)?.contains("/srv/%1$@") == true
    )
    XCTAssertEqual(
      RdpLauncherError.invalidEndpoint("Invalid port in endpoint: 'not-a-port'.").displayDescription(locale: vietnamese),
      "Điểm cuối RDP không hợp lệ: Cổng trong điểm cuối không hợp lệ: 'not-a-port'."
    )
    XCTAssertTrue(
      SerialError.invalidConfig("unsupported baud rate 1234").displayDescription(locale: vietnamese)?
        .contains("Tốc độ baud của cổng nối tiếp không được hỗ trợ: 1234") == true
    )
    XCTAssertEqual(
      RdpSessionError.protocolViolation("protocol diagnostic %1$@").displayDescription(locale: vietnamese),
      "Vi phạm giao thức RDP: protocol diagnostic %1$@"
    )
  }

  func testRdpClipboardFileErrorsStayRawUntilPresented() {
    let error = RdpClipboardFileError.io
    XCTAssertEqual(error.localizedDescription, "Clipboard file transfer failed. Check file permissions and free disk space.")
    XCTAssertEqual(
      RdpSessionError.protocolViolation(error.localizedDescription).displayDescription(locale: vietnamese),
      "Vi phạm giao thức RDP: Truyền tệp qua bảng nhớ tạm thất bại. Hãy kiểm tra quyền của tệp và dung lượng trống."
    )
  }

  func testAppCoreDisplayLabelsUseExplicitLocaleWithoutChangingStableValues() {
    XCTAssertEqual(AppDestination.hosts.title, "Hosts")
    XCTAssertEqual(AppDestination.hosts.localizedTitle(locale: vietnamese), "Máy chủ")
    XCTAssertEqual(AppDestination.hosts.localizedEmptyStateTitle(locale: vietnamese), "Chưa có máy chủ nào được lưu")
    XCTAssertEqual(HostEnvironment.production.rawValue, "production")
    XCTAssertEqual(HostEnvironment.production.localizedTitle(locale: vietnamese), "Sản xuất")
    XCTAssertEqual(CredentialKind.rdpPassword.rawValue, "rdp_password")
    XCTAssertEqual(CredentialKind.rdpPassword.localizedTitle(locale: vietnamese), "Mật khẩu Windows / RDP")
    XCTAssertEqual(
      CommandSnippetExecutionTarget(
        hostID: "host", groupID: nil, displayName: "Máy chủ", address: "example.net", environment: .production
      ).displayLabel(locale: vietnamese),
      "Máy chủ (example.net) — Sản xuất"
    )
  }

  func testEnglishAndVietnameseCatalogsHaveMatchingKeysAndPlaceholders() throws {
    let english = try catalog(for: "en")
    let vietnamese = try catalog(for: "vi")
    XCTAssertEqual(Set(english.keys), Set(vietnamese.keys))

    for key in english.keys {
      let englishValue = try XCTUnwrap(english[key])
      let vietnameseValue = try XCTUnwrap(vietnamese[key])
      XCTAssertEqual(placeholders(in: englishValue), placeholders(in: vietnameseValue), key)
      XCTAssertEqual(placeholders(in: key), placeholders(in: englishValue), key)
    }
  }

  private func catalog(for language: String) throws -> [String: String] {
    let file = packageRoot.appendingPathComponent(
      "Sources/AppCore/Resources/\(language).lproj/Localizable.strings"
    )
    let data = try Data(contentsOf: file)
    let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
    return try XCTUnwrap(propertyList as? [String: String])
  }

  private func placeholders(in value: String) -> [String] {
    let expression = try! NSRegularExpression(pattern: #"%([0-9]+\$)?([@diu])"#)
    let range = NSRange(value.startIndex..., in: value)
    return expression.matches(in: value, range: range).compactMap { match in
      guard let typeRange = Range(match.range(at: 2), in: value) else { return nil }
      let position = Range(match.range(at: 1), in: value).map { String(value[$0]) } ?? ""
      return position + String(value[typeRange])
    }.sorted()
  }

  private var packageRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func withLanguagePreference(_ operation: () -> Void) {
    let defaults = UserDefaults.standard
    let previousValue = defaults.object(forKey: AppLanguage.preferenceKey)
    defer {
      if let previousValue {
        defaults.set(previousValue, forKey: AppLanguage.preferenceKey)
      } else {
        defaults.removeObject(forKey: AppLanguage.preferenceKey)
      }
    }
    operation()
  }
}
