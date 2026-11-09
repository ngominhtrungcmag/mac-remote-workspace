import AppCore
import Combine
import XCTest
@testable import MacRemoteWorkspace

final class SSHWindowOpenRequestsTests: XCTestCase {
  @MainActor
  func testRestorationHasNoOpenAuthorization() {
    let requests = SSHWindowOpenRequests()
    XCTAssertFalse(requests.consume(hostID: "host"))
  }

  @MainActor
  func testExplicitOpenIsHostScopedAndOneShot() {
    let requests = SSHWindowOpenRequests()
    requests.request(hostID: "a")
    XCTAssertFalse(requests.consume(hostID: "b"))
    XCTAssertTrue(requests.consume(hostID: "a"))
    XCTAssertFalse(requests.consume(hostID: "a"))
    requests.request(hostID: "a")
    XCTAssertTrue(requests.consume(hostID: "a"))
    XCTAssertFalse(requests.consume(hostID: "a"))
    XCTAssertFalse(SSHWindowOpenRequests().consume(hostID: "a"))
  }

  @MainActor
  func testOpeningExistingWindowPreservesActiveSessionsAndAllowsReconnectAfterDisconnect() {
    let requests = SSHWindowOpenRequests()
    requests.request(hostID: "host")
    XCTAssertFalse(requests.consume(hostID: "host", hasActiveSession: true))
    XCTAssertFalse(requests.consume(hostID: "host"))
    requests.request(hostID: "host")
    XCTAssertTrue(requests.consume(hostID: "host", hasActiveSession: false))
    XCTAssertFalse(requests.consume(hostID: "host"))
  }

  @MainActor
  func testRequestIsAvailableDuringNotificationAndOnWindowSubscription() {
    let requests = SSHWindowOpenRequests()
    var consumed = false
    let subscription = requests.$revision.sink { revision in
      if revision > 0 { consumed = requests.consume(hostID: "host") }
    }
    requests.request(hostID: "host")
    XCTAssertTrue(consumed)
    subscription.cancel()

    requests.request(hostID: "new-window")
    let newWindowSubscription = requests.$revision.sink { _ in
      consumed = requests.consume(hostID: "new-window")
    }
    XCTAssertTrue(consumed)
    newWindowSubscription.cancel()
    XCTAssertFalse(requests.consume(hostID: "new-window"))
  }

  func testRestoredPlaceholderConnectsOnlyAfterExplicitOpenAndOnlyOncePerRequest() {
    var lifecycle = SSHSessionOpenLifecycle()
    XCTAssertFalse(lifecycle.consume(requestToken: 0, status: .idle))
    XCTAssertEqual(lifecycle.lastHandledToken, 0)
    XCTAssertTrue(lifecycle.consume(requestToken: 1, status: .idle))
    XCTAssertEqual(lifecycle.lastHandledToken, 1)
    XCTAssertFalse(lifecycle.consume(requestToken: 1, status: .idle))
    XCTAssertFalse(lifecycle.consume(requestToken: 0, status: .idle))
  }

  @MainActor
  func testReopenAfterDisconnectOrFailureAndAfterFirstTabClosed() {
    let requests = SSHWindowOpenRequests()
    var tab1Lifecycle = SSHSessionOpenLifecycle()
    var tab2Lifecycle = SSHSessionOpenLifecycle()
    var autoConnectTab: Int?
    var autoConnectToken = 0
    var tabs = [1, 2]

    // First explicit Open targets tab 1 and connects once.
    requests.request(hostID: "host")
    XCTAssertTrue(requests.consume(hostID: "host", hasActiveSession: false))
    autoConnectTab = tabs.first
    autoConnectToken += 1
    XCTAssertTrue(tab1Lifecycle.consume(requestToken: autoConnectTab == 1 ? autoConnectToken : 0, status: .idle))
    XCTAssertFalse(tab2Lifecycle.consume(requestToken: autoConnectTab == 2 ? autoConnectToken : 0, status: .idle))

    // Tab 1 disconnects (`hasActiveSession == false`); a new explicit Open reconnects tab 1 once.
    requests.request(hostID: "host")
    XCTAssertTrue(requests.consume(hostID: "host", hasActiveSession: false))
    autoConnectTab = tabs.first
    autoConnectToken += 1
    XCTAssertTrue(
      tab1Lifecycle.consume(requestToken: autoConnectTab == 1 ? autoConnectToken : 0, status: .disconnected(exitCode: 0))
    )
    XCTAssertFalse(
      tab1Lifecycle.consume(requestToken: autoConnectTab == 1 ? autoConnectToken : 0, status: .disconnected(exitCode: 0))
    )

    // Tab 1 fails (`hasActiveSession == false`); another explicit Open retries tab 1 once.
    requests.request(hostID: "host")
    XCTAssertTrue(requests.consume(hostID: "host", hasActiveSession: false))
    autoConnectTab = tabs.first
    autoConnectToken += 1
    XCTAssertTrue(
      tab1Lifecycle.consume(requestToken: autoConnectTab == 1 ? autoConnectToken : 0, status: .failed("Failed"))
    )

    // User closes tab 1 (`tabs` becomes `[2]`), tab 2 is disconnected, and user triggers Open again.
    tabs.removeFirst()
    if autoConnectTab == 1 { autoConnectTab = nil }
    requests.request(hostID: "host")
    XCTAssertTrue(requests.consume(hostID: "host", hasActiveSession: false))
    autoConnectTab = tabs.first
    autoConnectToken += 1
    XCTAssertEqual(autoConnectTab, 2)
    XCTAssertTrue(
      tab2Lifecycle.consume(requestToken: autoConnectTab == 2 ? autoConnectToken : 0, status: .disconnected(exitCode: 255))
    )
    XCTAssertFalse(
      tab2Lifecycle.consume(requestToken: autoConnectTab == 2 ? autoConnectToken : 0, status: .idle)
    )
  }

  @MainActor
  func testReopenDuringActiveOrTrustAttemptPreservesAttemptWithoutStaleReplay() {
    let key = SSHHostKeyRecord(
      rawLine: "example.test ssh-ed25519 test", keyType: "ssh-ed25519",
      keyBase64: "test", algorithm: "ED25519", fingerprintSHA256: "SHA256:test"
    )
    let activeStates: [SSHSessionViewModel.SessionStatus] = [
      .verifyingHost(host: "example.test", port: 22),
      .hostTrustRequired(challenge: SSHHostTrustChallenge(host: "example.test", port: 22, presentedKey: key)),
      .hostKeyMismatch(recordedKeys: [key], presentedKey: key),
      .connecting, .running
    ]
    for state in activeStates {
      let requests = SSHWindowOpenRequests()
      var lifecycle = SSHSessionOpenLifecycle()
      // A restored child has prepared its form, then the user starts connecting manually.
      XCTAssertFalse(lifecycle.consume(requestToken: 0, status: .idle))
      requests.request(hostID: "host")
      // Window-level guard blocks while any tab is verifying/trust-prompting/connecting/running.
      XCTAssertFalse(requests.consume(hostID: "host", hasActiveSession: true), "\(state)")
      XCTAssertFalse(requests.consume(hostID: "host"))
      // Even if a token reaches the sheet during an active state, it is consumed without connecting or replaying later.
      XCTAssertFalse(lifecycle.consume(requestToken: 1, status: state), "\(state)")
      XCTAssertFalse(lifecycle.consume(requestToken: 1, status: .idle))
      XCTAssertFalse(lifecycle.consume(requestToken: 1, status: .disconnected(exitCode: 0)))
      // Only a fresh explicit Open after the attempt ends can trigger a new connection.
      XCTAssertTrue(lifecycle.consume(requestToken: 2, status: .disconnected(exitCode: 0)))
    }
  }

}
