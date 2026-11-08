import XCTest
@testable import AppCore

final class AccessibilityTests: XCTestCase {

  // MARK: - Keyboard Navigation Shortcuts (FR-015 / TC-013)

  func testAllAppDestinationsHaveValidNonCollidingKeyboardShortcuts() {
    let destinations = AppDestination.allCases

    // Must have exactly 4 main navigation tabs
    XCTAssertEqual(destinations.count, 4)

    // Verify keyboard shortcuts are unique single characters
    var seenShortcuts = Set<Character>()
    for dest in destinations {
      let char = dest.keyboardShortcut
      XCTAssertTrue(char.isNumber, "Navigation shortcut should be numeric (1-4)")
      XCTAssertTrue(seenShortcuts.insert(char).inserted, "Duplicate navigation shortcut detected: \(char)")
    }
  }

  func testDestinationsHaveExplicitTitlesAndSymbols() {
    for dest in AppDestination.allCases {
      XCTAssertFalse(dest.title.trimmingCharacters(in: .whitespaces).isEmpty)
      XCTAssertFalse(dest.symbolName.trimmingCharacters(in: .whitespaces).isEmpty)

      // Ensure symbols are valid SF Symbols identifiers (alphanumeric with dots)
      XCTAssertTrue(dest.symbolName.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." })
    }
  }

  // MARK: - VoiceOver & Accessibility Descriptions (FR-015 / TC-013)

  func testEmptyStatesProvideMeaningfulAccessibilityDescriptions() {
    for dest in AppDestination.allCases {
      let emptyState = dest.emptyState
      XCTAssertFalse(emptyState.title.isEmpty, "Empty state title must not be empty for \(dest)")
      XCTAssertFalse(emptyState.message.isEmpty, "Empty state message must not be empty for \(dest)")
      // VoiceOver requires descriptive message, at least 10 characters
      XCTAssertGreaterThan(emptyState.message.count, 10)
    }
  }

  func testHostEnvironmentsHaveDistinctAccessibleTitles() {
    let envs = HostEnvironment.allCases
    XCTAssertEqual(envs.count, 3)

    var titles = Set<String>()
    for env in envs {
      XCTAssertFalse(env.title.isEmpty)
      XCTAssertTrue(titles.insert(env.title).inserted, "Duplicate environment title: \(env.title)")
    }
  }

  func testCredentialKindsHaveDescriptiveTitles() {
    let kinds = CredentialKind.allCases
    XCTAssertEqual(kinds.count, 3)
    for kind in kinds {
      XCTAssertFalse(kind.title.isEmpty)
    }
    XCTAssertEqual(CredentialKind.password.title, "SSH password")
    XCTAssertEqual(CredentialKind.keyPassphrase.title, "Key passphrase")
    XCTAssertEqual(CredentialKind.rdpPassword.title, "Windows / RDP password")
  }
}
