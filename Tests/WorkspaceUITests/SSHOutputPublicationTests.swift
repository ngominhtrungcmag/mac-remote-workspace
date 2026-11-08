import AppCore
import Combine
import XCTest
@testable import MacRemoteWorkspace

final class SSHOutputPublicationTests: XCTestCase {
  @MainActor
  func testOutputIsBoundedAndDoesNotPublishChanges() {
    let host = HostRecord(id: "test", workspaceID: "workspace", displayName: "Host", address: "example.com", environment: .development, version: 1, protocols: ["ssh"])
    let model = SSHSessionViewModel(host: host)
    var changes = 0
    let subscription = model.objectWillChange.sink { changes += 1 }
    model.appendOutput(String(repeating: "a", count: 100_000))
    model.appendOutput("Permission denied")
    XCTAssertEqual(changes, 0)
    XCTAssertEqual(model.terminalOutput.count, 100_000)
    XCTAssertTrue(model.terminalOutput.hasSuffix("Permission denied"))
    withExtendedLifetime(subscription) {}
  }
}
