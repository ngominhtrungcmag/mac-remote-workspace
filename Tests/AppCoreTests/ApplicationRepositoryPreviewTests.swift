import Foundation
import XCTest
@testable import AppCore

final class ApplicationRepositoryPreviewTests: XCTestCase {
  func testPreviewPathsAreIsolated() {
    let preview = ["XCODE_RUNNING_FOR_PREVIEWS": "1"]
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MacRemoteWorkspacePreviews", isDirectory: true)
    XCTAssertEqual(SQLiteHostRepository.applicationSupportDirectory(environment: [:]), FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
    XCTAssertEqual(SQLiteHostRepository.applicationSupportDirectory(environment: preview), temporary)
    XCTAssertEqual(NativeSSHHostTrustService.knownHostsURL(environment: [:]), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/known_hosts"))
    XCTAssertEqual(NativeSSHHostTrustService.knownHostsURL(environment: preview), temporary.appendingPathComponent("known_hosts"))
  }
}
