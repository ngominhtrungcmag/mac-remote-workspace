import AppCore
import XCTest
@testable import MacRemoteWorkspace

final class SFTPSelectionTests: XCTestCase {
  @MainActor
  func testSelectionOnlyIncludesEntriesInCurrentListing() {
    let first = SFTPFileEntry(name: "a", path: "/a", isDirectory: false, isSymlink: false, size: 0, permissions: "", modificationDateString: nil, symlinkTarget: nil)
    let second = SFTPFileEntry(name: "b", path: "/b", isDirectory: true, isSymlink: false, size: 0, permissions: "", modificationDateString: nil, symlinkTarget: nil)
    XCTAssertEqual(SFTPBrowserViewModel.entries([first, second], matching: [first.id, second.id, "/stale"]), [first, second])
    XCTAssertTrue(SFTPBrowserViewModel.entries([first], matching: [second.id]).isEmpty)
  }
}
