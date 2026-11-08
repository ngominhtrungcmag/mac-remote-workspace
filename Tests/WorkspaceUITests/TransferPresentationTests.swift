import AppCore
import XCTest
@testable import MacRemoteWorkspace

final class TransferPresentationTests: XCTestCase {
  func testActiveAndRevealActionsFollowTransferStatusAndDirection() {
    func item(_ kind: SFTPTransferKind, _ status: SFTPTransferStatus) -> SFTPTransferItem {
      SFTPTransferItem(kind: kind, sourceDescription: "source", destinationDescription: "/tmp/file", totalBytes: 1, status: status)
    }
    XCTAssertTrue(item(.download, .queued).isActiveTransfer)
    XCTAssertTrue(item(.upload, .running(progress: 0.5)).isActiveTransfer)
    XCTAssertFalse(item(.download, .completed).isActiveTransfer)
    XCTAssertTrue(item(.download, .completed).canRevealInFinder)
    XCTAssertFalse(item(.upload, .completed).canRevealInFinder)
    XCTAssertFalse(item(.download, .failed("error")).canRevealInFinder)
  }
}
