import XCTest
@testable import MacRemoteWorkspace

final class ShellDestinationTests: XCTestCase {
  func testStoredSelectionRoundTripsAndRejectsInvalidValues() {
    let selections: [ShellDestination] = [.inventory(.all), .inventory(.workspace("abc-def")), .inventory(.group("xyz")), .security(.knownHosts), .security(.transfers)]
    for selection in selections {
      XCTAssertEqual(ShellDestination(storedID: selection.id), selection)
    }
    XCTAssertNil(ShellDestination(storedID: "security-hosts"))
    XCTAssertNil(ShellDestination(storedID: "unknown"))
  }
}
