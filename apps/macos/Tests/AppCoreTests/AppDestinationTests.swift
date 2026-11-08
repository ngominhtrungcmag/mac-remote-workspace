import XCTest
@testable import AppCore

final class AppDestinationTests: XCTestCase {
    func testNavigationDestinationsHaveUniqueLabelsAndShortcuts() {
        let destinations = AppDestination.allCases

        XCTAssertEqual(Set(destinations.map(\.title)).count, destinations.count)
        XCTAssertEqual(Set(destinations.map(\.keyboardShortcut)).count, destinations.count)
        XCTAssertEqual(destinations.map(\.keyboardShortcut), ["1", "2", "3", "4"])
    }

    func testEmptyStatesAreExplicitAboutUnavailableFeatures() {
        for destination in AppDestination.allCases {
            XCTAssertFalse(destination.emptyState.title.isEmpty)
            XCTAssertFalse(destination.emptyState.message.isEmpty)
        }

        XCTAssertTrue(AppDestination.hosts.emptyState.message.contains("Add a host"))
        XCTAssertTrue(AppDestination.credentials.emptyState.message.contains("macOS Keychain"))
    }
}
