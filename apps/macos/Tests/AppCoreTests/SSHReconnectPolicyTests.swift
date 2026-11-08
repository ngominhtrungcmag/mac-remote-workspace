import Foundation
import XCTest
@testable import AppCore

final class SSHReconnectPolicyTests: XCTestCase {
  // MARK: Jitter (FR-027)

  func testJitterDisabledKeepsDeterministicDelay() {
    let b = SSHReconnectBackoff(base: 1, cap: 8)
    XCTAssertEqual([1, 2, 3, 4, 5, 6].map { b.delay(afterFailures: $0, sample: 0.99) }, [1, 2, 4, 8, 8, 8])
  }

  func testJitterStaysWithinBoundsAndNeverExceedsCap() {
    let b = SSHReconnectBackoff(base: 1, cap: 8, jitter: 0.5)
    for n in 1...40 {
      let full = b.delay(afterFailures: n, sample: 0)
      XCTAssertLessThanOrEqual(full, 8)
      for s in [0.0, 0.25, 0.5, 0.999, 5, -1] {
        let d = b.delay(afterFailures: n, sample: s)
        XCTAssertGreaterThanOrEqual(d, full * 0.5)
        XCTAssertLessThanOrEqual(d, full)
      }
    }
    XCTAssertEqual(b.delay(afterFailures: 3, sample: 0.5), 3)  // 4 * (1 - 0.5 * 0.5)
  }

  func testFullJitterRangeAndClamping() {
    XCTAssertEqual(SSHReconnectBackoff(jitter: 7).jitter, 1)
    XCTAssertEqual(SSHReconnectBackoff(jitter: -1).jitter, 0)
    let b = SSHReconnectBackoff(base: 2, cap: 30, jitter: 1)
    XCTAssertEqual(b.delay(afterFailures: 2, sample: 0), 4)
    XCTAssertEqual(b.delay(afterFailures: 2, sample: 1), 0)
  }

  func testRecordFailureUsesInjectedSampleAndDefaultRNGStaysInRange() {
    var b = SSHReconnectBackoff(base: 4, cap: 30, jitter: 0.5)
    let t0 = Date(timeIntervalSince1970: 0)
    b.recordFailure(now: t0, sample: 0.5)
    XCTAssertEqual(b.remaining(now: t0), 3)
    var r = SSHReconnectBackoff(base: 4, cap: 30, jitter: 0.5)
    for _ in 0..<50 {
      r.reset()
      r.recordFailure(now: t0)
      XCTAssertTrue((2...4).contains(r.remaining(now: t0)))
    }
  }

  // MARK: Storm guard (FR-027)

  func testRepeatedFailuresOfAnyKindKeepGrowingWaitUpToCap() {
    var b = SSHReconnectBackoff(base: 1, cap: 8, jitter: 0.5)
    let t0 = Date(timeIntervalSince1970: 0)
    var prevMin = 0.0
    for _ in 0..<10 {
      b.recordFailure(now: t0, sample: 0.999)  // worst-case jitter still forces a wait
      let wait = b.remaining(now: t0)
      XCTAssertGreaterThan(wait, 0)
      XCTAssertGreaterThanOrEqual(wait, prevMin)
      XCTAssertLessThanOrEqual(wait, 8)
      prevMin = wait
    }
    XCTAssertGreaterThanOrEqual(b.remaining(now: t0), 4)  // at cap, floor is cap * (1 - jitter)
  }

  // MARK: No command replay (FR-008)

  func testPlaceholderAndRestoreStoreHoldNoCommands() throws {
    let data = try JSONEncoder().encode(SSHSessionPlaceholder(hostID: "h1", tabCount: 2))
    let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
    XCTAssertEqual(Set(keys), ["hostID", "tabCount"])

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = SSHSessionRestoreStore(url: url)
    store.save(hostID: "h1", tabCount: 3)
    let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]]
    XCTAssertEqual(obj?.map { Set($0.keys) }, [["hostID", "tabCount"]])
  }

  func testReconnectStartsFreshSessionWithNoInputHistory() throws {
    let config = NativeSSHConfiguration(
      host: "localhost", port: 22, username: "u",
      knownHostsFileURL: URL(fileURLWithPath: "/dev/null"),
      authentication: .identityFile(URL(fileURLWithPath: "/dev/null")))
    let first = NativeSSHSession(configuration: config)
    first.close()
    let second = NativeSSHSession(configuration: config)  // what reconnect creates
    XCTAssertNotEqual(first.id, second.id)
    XCTAssertEqual(second.state, .idle)
    // Nothing is queued before start: input cannot be buffered and replayed into a new shell.
    XCTAssertThrowsError(try second.write(string: "rm -rf /tmp/x\n")) { error in
      XCTAssertEqual(error as? NativeSSHError, .sessionNotRunning)
    }
  }
}
