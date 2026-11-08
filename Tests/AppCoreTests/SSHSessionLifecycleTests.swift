import Foundation
import XCTest
@testable import AppCore

final class SSHSessionLifecycleTests: XCTestCase {
  func testBackoffGrowsExponentiallyAndCaps() {
    var b = SSHReconnectBackoff(base: 1, cap: 8)
    let t0 = Date(timeIntervalSince1970: 1000)
    var waits: [TimeInterval] = []
    for _ in 0..<6 {
      b.recordFailure(now: t0)
      waits.append(b.remaining(now: t0))
    }
    XCTAssertEqual(waits, [1, 2, 4, 8, 8, 8])
  }

  func testBackoffBlocksThenAllowsAndResetCancels() {
    var b = SSHReconnectBackoff(base: 2, cap: 30)
    let t0 = Date(timeIntervalSince1970: 0)
    XCTAssertEqual(b.remaining(now: t0), 0)
    b.recordFailure(now: t0)
    XCTAssertGreaterThan(b.remaining(now: t0.addingTimeInterval(1)), 0)
    XCTAssertEqual(b.remaining(now: t0.addingTimeInterval(2)), 0)
    b.recordFailure(now: t0)
    b.reset()
    XCTAssertEqual(b.consecutiveFailures, 0)
    XCTAssertEqual(b.remaining(now: t0), 0)
  }

  func testBackoffHugeFailureCountDoesNotOverflow() {
    var b = SSHReconnectBackoff(base: 1, cap: 30)
    for _ in 0..<5000 { b.recordFailure(now: Date(timeIntervalSince1970: 0)) }
    XCTAssertEqual(b.remaining(now: Date(timeIntervalSince1970: 0)), 30)
  }

  private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("mrw-restore-\(UUID().uuidString)/layout.json")
  }

  func testRestoreStoreRoundTripsTabCountOnly() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = SSHSessionRestoreStore(url: url)
    XCTAssertEqual(store.tabCount(forHost: "h1"), 1)
    store.save(hostID: "h1", tabCount: 3)
    XCTAssertEqual(SSHSessionRestoreStore(url: url).tabCount(forHost: "h1"), 3)
    let raw = String(decoding: try Data(contentsOf: url), as: UTF8.self)
    XCTAssertFalse(raw.lowercased().contains("password"))
    let obj = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]]
    XCTAssertEqual(Set(obj?.first?.keys.map { $0 } ?? []), ["hostID", "tabCount"])
    store.save(hostID: "h1", tabCount: 1)
    XCTAssertEqual(store.load(), [])
  }

  func testRestoreStoreCorruptFileAndOutOfRangeAreSafe() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: url)
    let store = SSHSessionRestoreStore(url: url)
    XCTAssertEqual(store.tabCount(forHost: "h"), 1)
    try Data(#"[{"hostID":"h","tabCount":999},{"hostID":"","tabCount":2}]"#.utf8).write(to: url)
    XCTAssertEqual(store.load(), [SSHSessionPlaceholder(hostID: "h", tabCount: SSHSessionRestoreStore.maxTabs)])
  }
}

