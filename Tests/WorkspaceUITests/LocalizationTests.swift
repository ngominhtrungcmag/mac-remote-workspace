import Foundation
import AppKit
import SwiftUI
import XCTest
import AppCore
@testable import MacRemoteWorkspace

final class LocalizationTests: XCTestCase {
  func testVietnameseLocaleSelectsVietnameseText() {
    XCTAssertEqual(
      AppLocalization.string("inventory.scope.all_hosts", locale: Locale(identifier: "vi_VN")),
      "Tất cả máy chủ"
    )
  }

  func testEnglishLocaleUsesSourceText() {
    XCTAssertEqual(
      AppLocalization.string("inventory.scope.all_hosts", locale: Locale(identifier: "en_US")),
      "All Hosts"
    )
  }

  func testUnsupportedLocaleFallsBackToEnglish() {
    XCTAssertEqual(
      AppLocalization.string("inventory.scope.all_hosts", locale: Locale(identifier: "fr_FR")),
      "All Hosts"
    )
  }

  func testMissingVietnameseTranslationFallsBackToEnglish() {
    XCTAssertEqual(
      AppLocalization.string("localization.english_fallback", locale: Locale(identifier: "vi")),
      "English fallback"
    )
  }

  func testDefaultLanguageLookupReturnsABundledTranslation() {
    XCTAssertTrue(["All Hosts", "Tất cả máy chủ"].contains(
      AppLocalization.string("inventory.scope.all_hosts")
    ))
  }

  func testLanguagePickerLabelsAreLocalizedAndUseStableValues() {
    let english = Locale(identifier: "en_US")
    let vietnamese = Locale(identifier: "vi_VN")
    XCTAssertEqual(AppLanguage.system.localizedTitle(locale: english), "System default")
    XCTAssertEqual(AppLanguage.system.localizedTitle(locale: vietnamese), "Mặc định hệ thống")
    XCTAssertEqual(AppLanguage.vietnamese.localizedTitle(locale: english), "Tiếng Việt")
    XCTAssertEqual(AppLanguage.vietnamese.localizedTitle(locale: vietnamese), "Tiếng Việt")
    XCTAssertEqual(AppLanguage.english.localizedTitle(locale: english), "English")
    XCTAssertEqual(AppLanguage.english.localizedTitle(locale: vietnamese), "English")
    XCTAssertEqual(AppLanguage.system.rawValue, "system")
    XCTAssertEqual(AppLanguage.vietnamese.rawValue, "vi")
    XCTAssertEqual(AppLanguage.english.rawValue, "en")
  }

  func testPersistedLanguagePreferenceDrivesSwiftUIAndAppCoreLookups() {
    let defaults = UserDefaults.standard
    let previousValue = defaults.object(forKey: AppLanguage.preferenceKey)
    defer {
      if let previousValue {
        defaults.set(previousValue, forKey: AppLanguage.preferenceKey)
      } else {
        defaults.removeObject(forKey: AppLanguage.preferenceKey)
      }
    }

    defaults.set(AppLanguage.vietnamese.rawValue, forKey: AppLanguage.preferenceKey)
    XCTAssertEqual(AppLocalization.string("Language"), "Ngôn ngữ")
    XCTAssertEqual(
      AppCoreLocalization.string("The macOS Keychain is unavailable in this environment."),
      "Keychain macOS không khả dụng trong môi trường này."
    )

    defaults.set(AppLanguage.english.rawValue, forKey: AppLanguage.preferenceKey)
    XCTAssertEqual(AppLocalization.string("Language"), "Language")
    XCTAssertEqual(
      AppCoreLocalization.string("The macOS Keychain is unavailable in this environment."),
      "The macOS Keychain is unavailable in this environment."
    )
  }

  @MainActor
  func testGeneralSettingsLanguagePickerScreenshot() throws {
    let defaults = UserDefaults.standard
    let previousValue = defaults.object(forKey: AppLanguage.preferenceKey)
    defaults.set(AppLanguage.vietnamese.rawValue, forKey: AppLanguage.preferenceKey)
    defer {
      if let previousValue {
        defaults.set(previousValue, forKey: AppLanguage.preferenceKey)
      } else {
        defaults.removeObject(forKey: AppLanguage.preferenceKey)
      }
    }

    let view = NSHostingView(rootView: GeneralSettings()
      .environment(\.locale, Locale(identifier: "vi"))
      .frame(width: 560, height: 440))
    view.frame = NSRect(x: 0, y: 0, width: 560, height: 440)
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }

    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      .write(to: URL(fileURLWithPath: "/tmp/mrw-general-settings-vi.png"))
  }

  func testFormattingPreservesDynamicTextVerbatim() {
    XCTAssertEqual(
      AppLocalization.format("SFTP: %1$@", "server%1$@.example", locale: Locale(identifier: "vi")),
      "SFTP: server%1$@.example"
    )
  }

  func testRdpClipboardStatusesTranslateAtTheDisplayBoundary() {
    let vietnamese = Locale(identifier: "vi_VN")
    let statuses = [
      ("The server does not support clipboard file streaming.", "Máy chủ không hỗ trợ truyền tệp qua bảng nhớ tạm."),
      ("Files copied. Paste in Windows to transfer (copy only).", "Đã sao chép tệp. Dán vào Windows để truyền (chỉ sao chép)."),
      ("Sending clipboard files to Windows…", "Đang gửi tệp qua bảng nhớ tạm sang Windows…"),
      ("Clipboard files sent to Windows.", "Đã gửi tệp qua bảng nhớ tạm sang Windows."),
      ("Receiving clipboard files from Windows…", "Đang nhận tệp qua bảng nhớ tạm từ Windows…"),
      ("Preparing clipboard files from Windows…", "Đang chuẩn bị tệp qua bảng nhớ tạm từ Windows…"),
      ("Files ready. Paste in Finder before disconnecting.", "Tệp đã sẵn sàng. Hãy dán vào Finder trước khi ngắt kết nối."),
      ("Clipboard files contain unsupported names, links, or invalid data.", "Tệp trong bảng nhớ tạm có tên không được hỗ trợ, liên kết hoặc dữ liệu không hợp lệ."),
      ("Clipboard copy is limited to 256 entries and 1 GiB per selection.", "Mỗi lần sao chép qua bảng nhớ tạm giới hạn 256 mục và 1 GiB."),
      ("The clipboard or source file changed. Copy the files again.", "Bảng nhớ tạm hoặc tệp nguồn đã thay đổi. Hãy sao chép lại các tệp."),
      ("Clipboard file transfer failed. Check file permissions and free disk space.", "Truyền tệp qua bảng nhớ tạm thất bại. Hãy kiểm tra quyền của tệp và dung lượng trống."),
    ]
    for (raw, translated) in statuses {
      XCTAssertEqual(RdpClipboardStatusView.localizedMessage(raw, locale: vietnamese), translated, raw)
    }

    XCTAssertEqual(
      RdpClipboardStatusView.localizedMessage("Receiving clipboard file 3 of 10…", locale: vietnamese),
      "Đang nhận tệp 3 trên 10 qua bảng nhớ tạm…"
    )
    XCTAssertEqual(
      RdpClipboardStatusView.localizedMessage("Receiving clipboard file 3 of 10…", locale: Locale(identifier: "en_US")),
      "Receiving clipboard file 3 of 10…"
    )
    XCTAssertEqual(
      RdpClipboardStatusView.localizedMessage("Unrecognized helper text", locale: vietnamese),
      "Unrecognized helper text"
    )
    XCTAssertEqual(
      RdpClipboardStatusView.localizedMessage("Receiving clipboard file 11 of 10…", locale: vietnamese),
      "Receiving clipboard file 11 of 10…"
    )
  }

  func testEnglishAndVietnameseCatalogsHaveMatchingKeysAndPlaceholders() throws {
    let english = try catalog(for: "en")
    let vietnamese = try catalog(for: "vi")
    let fallbackFixture = "localization.english_fallback"
    XCTAssertEqual(Set(english.keys).subtracting([fallbackFixture]), Set(vietnamese.keys))
    let sourceKeys = try presentationKeys()
    XCTAssertTrue(sourceKeys.isSubset(of: Set(english.keys)), "English catalog is missing: \(sourceKeys.subtracting(english.keys).sorted())")
    XCTAssertTrue(sourceKeys.isSubset(of: Set(vietnamese.keys)), "Vietnamese catalog is missing: \(sourceKeys.subtracting(vietnamese.keys).sorted())")
    for (key, englishValue) in english {
      XCTAssertEqual(placeholders(in: key), placeholders(in: englishValue), key)
    }
    for key in vietnamese.keys {
      XCTAssertEqual(placeholders(in: english[key] ?? ""), placeholders(in: vietnamese[key] ?? ""), key)
    }
  }

  private func presentationKeys() throws -> Set<String> {
    let sourceDirectory = packageRoot.appendingPathComponent("Sources/MacRemoteWorkspace")
    var enumerationError: Error?
    let enumerator = try XCTUnwrap(FileManager.default.enumerator(
      at: sourceDirectory, includingPropertiesForKeys: nil, errorHandler: { _, error in
        enumerationError = error
        return false
      }
    ))
    let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    if let enumerationError { throw enumerationError }
    XCTAssertFalse(files.isEmpty, "No Swift presentation source files found")
    var keys = Set(try files.flatMap { file in
      localizedLiterals(in: try String(contentsOf: file, encoding: .utf8))
    })
    keys.formUnion(AppDestination.allCases.flatMap { [$0.title, $0.emptyState.title, $0.emptyState.message] })
    keys.formUnion(HostEnvironment.allCases.map(\.title))
    keys.formUnion(CredentialKind.allCases.map(\.title))
    keys.formUnion(AppAppearance.allCases.map(\.rawValue))
    keys.formUnion(TerminalCursorStyle.allCases.map(\.rawValue))
    keys.formUnion(RdpLaunchMode.allCases.map(\.rawValue))
    keys.formUnion(HostMetricsAuthMethod.allCases.map(\.rawValue))
    keys.formUnion(ImportExportTab.allCases.map(\.rawValue))
    keys.formUnion(InventoryImportExportSheet.ExportFormat.allCases.map(\.rawValue))
    keys.formUnion(ImportConflictPolicy.allCases.map(\.rawValue))
    keys.formUnion(["Language", "System default", "Tiếng Việt", "English"])
    keys.formUnion(["All", "Active", "Finished"])
    return keys
  }

  private func localizedLiterals(in source: String) -> [String] {
    let marker = try! NSRegularExpression(pattern: #"(?:AppLocalization\.(?:string|format)|quickConnectText|rdpSessionText)\("#)
    let sourceRange = NSRange(source.startIndex..., in: source)
    return marker.matches(in: source, range: sourceRange).flatMap { match -> [String] in
      guard let matchRange = Range(match.range, in: source) else { return [] }
      var cursor = matchRange.upperBound
      var depth = 1
      var inString = false
      var escaped = false
      var literal = ""
      var keys: [String] = []
      while cursor < source.endIndex && depth > 0 {
        let character = source[cursor]
        if inString {
          if escaped {
            literal.append("\\")
            literal.append(character)
            escaped = false
          } else if character == "\\" {
            escaped = true
          } else if character == "\"" {
            keys.append(decodeSwiftString(literal[...]))
            literal = ""
            inString = false
          } else {
            literal.append(character)
          }
        } else if character == "\"" {
          inString = true
        } else if character == "(" {
          depth += 1
        } else if character == ")" {
          depth -= 1
        }
        cursor = source.index(after: cursor)
      }
      return keys.filter { key in
        !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && key.unicodeScalars.contains(where: CharacterSet.letters.contains)
      }
    }
  }

  private func catalog(for language: String) throws -> [String: String] {
    let file = packageRoot
      .appendingPathComponent("Sources/MacRemoteWorkspace/Resources/\(language).lproj/Localizable.strings")
    let data = try Data(contentsOf: file)
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
    return try XCTUnwrap(plist as? [String: String])
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

  private func decodeSwiftString(_ value: Substring) -> String {
    let source = String(value)
    let unicode = try! NSRegularExpression(pattern: #"\\u\{([0-9A-Fa-f]+)\}"#)
    var decoded = source
    let matches = unicode.matches(in: decoded, range: NSRange(decoded.startIndex..., in: decoded)).reversed()
    for match in matches {
      guard let digitsRange = Range(match.range(at: 1), in: decoded),
        let fullRange = Range(match.range, in: decoded),
        let scalarValue = UInt32(decoded[digitsRange], radix: 16),
        let scalar = UnicodeScalar(scalarValue)
      else { continue }
      decoded.replaceSubrange(fullRange, with: String(scalar))
    }
    return decoded
      .replacingOccurrences(of: #"\n"#, with: "\n")
      .replacingOccurrences(of: #"\t"#, with: "\t")
      .replacingOccurrences(of: #"\""#, with: "\"")
      .replacingOccurrences(of: #"\\"#, with: #"\"#)
  }
}
