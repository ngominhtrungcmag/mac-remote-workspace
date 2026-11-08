import Darwin
import Foundation
import XCTest
@testable import AppCore

/// TC-007 / FR-007 / US-009: PTY resize and parallel SSH shell isolation.
/// Unit tests run everywhere; fixture tests need the disposable loopback fixture
/// (`apps/macos/run-ssh-fixture.sh`) and XCTSkip otherwise.
final class SSHPTYParallelSessionTests: XCTestCase {

  // MARK: - Unit tests (no fixture)

  func testTerminalSizeClampsZeroToOneAndKeepsMaximum() {
    let zero = NativeSSHTerminalSize(rows: 0, columns: 0)
    XCTAssertEqual(zero.rows, 1)
    XCTAssertEqual(zero.columns, 1)
    let huge = NativeSSHTerminalSize(rows: .max, columns: .max)
    XCTAssertEqual(huge.rows, UInt16.max)
    XCTAssertEqual(huge.columns, UInt16.max)
    // Negative values are unrepresentable: the API takes UInt16.
  }

  func testResizeOnNotStartedSessionThrowsSessionNotRunningForAnySize() {
    let session = Self.unstartedSession()
    for (rows, cols) in [(24, 80), (0, 0), (0, 80), (24, 0), (Int(UInt16.max), Int(UInt16.max))] {
      XCTAssertThrowsError(try session.resize(rows: UInt16(rows), columns: UInt16(cols))) {
        XCTAssertEqual($0 as? NativeSSHError, .sessionNotRunning, "\(rows)x\(cols)")
      }
    }
    XCTAssertEqual(session.state, .idle)
  }

  func testResizeAfterCloseOfNotStartedSessionThrowsSessionNotRunning() {
    let session = Self.unstartedSession()
    session.close()
    XCTAssertThrowsError(try session.resize(rows: 30, columns: 90)) {
      XCTAssertEqual($0 as? NativeSSHError, .sessionNotRunning)
    }
  }

  // MARK: - Fixture tests

  func testParallelSessionsAreIsolatedAndResizeIndependently() throws {
    let fixture = try Fixture.require()
    let baseline = Self.sshChildPIDs()
    let runs = try (0..<4).map { try Run(index: $0, fixture: fixture) }
    runs.forEach { run in addTeardownBlock { run.session.close() } }

    // 1. Distinct sentinel per session, issued concurrently; no cross-talk.
    DispatchQueue.concurrentPerform(iterations: runs.count) { i in
      do { try runs[i].send("printf 'OUT:%s:%s\\n' 'TAG\(i)' 'ok'\n") } catch { XCTFail("send \(i): \(error)") }
    }
    for run in runs {
      XCTAssertTrue(waitUntil { run.output.contains("OUT:TAG\(run.index):ok") }, "session \(run.index) sentinel")
    }
    for run in runs {
      for other in runs where other.index != run.index {
        XCTAssertFalse(run.output.contains("OUT:TAG\(other.index):"), "session \(run.index) saw session \(other.index) output")
      }
    }

    // 2. Each session resized to its own size reports exactly that size.
    for run in runs { try run.session.resize(rows: run.rows, columns: run.cols) }
    for run in runs { try run.send("echo SZ1: $(stty size)\n") }
    for run in runs {
      XCTAssertTrue(waitUntil { run.output.contains("SZ1: \(run.rows) \(run.cols)") }, "session \(run.index) size \(run.rows)x\(run.cols); got \(run.output.debugDescription)")
      for other in runs where other.index != run.index {
        XCTAssertFalse(run.output.contains("SZ1: \(other.rows) \(other.cols)"), "size cross-talk \(run.index)<-\(other.index)")
      }
    }

    // 3. 20 rapid resizes per session (concurrently across sessions): final size wins.
    DispatchQueue.concurrentPerform(iterations: runs.count) { i in
      let run = runs[i]
      for step in 0..<20 {
        let last = step == 19
        do {
          try run.session.resize(
            rows: last ? run.rows + 7 : UInt16(10 + step),
            columns: last ? run.cols + 9 : UInt16(50 + step))
        } catch { XCTFail("resize \(i)/\(step): \(error)") }
      }
    }
    for run in runs { try run.send("echo SZ2: $(stty size)\n") }
    for run in runs {
      XCTAssertTrue(waitUntil { run.output.contains("SZ2: \(run.rows + 7) \(run.cols + 9)") }, "session \(run.index) final size after rapid resizes")
    }

    // 4. UTF-8 multi-byte output round-trips per session. Bytes are emitted via octal
    // escapes so the literal text never appears in the echoed command line.
    for run in runs { try run.send("printf 'U\(run.index):\(Self.octalEscaped(run.utf8Text))\\n'\n") }
    for run in runs {
      let expected = Data("U\(run.index):\(run.utf8Text)".utf8)
      XCTAssertTrue(waitUntil { run.collector.snapshot().range(of: expected) != nil }, "session \(run.index) UTF-8 round trip")
      XCTAssertFalse(run.output.contains("\u{FFFD}"), "session \(run.index) produced invalid UTF-8")
    }

    // 5. Closing one session leaves the others functional.
    runs[0].session.close()
    XCTAssertEqual(runs[0].session.state, .disconnected(exitCode: nil))
    XCTAssertThrowsError(try runs[0].session.resize(rows: 30, columns: 90)) {
      XCTAssertEqual($0 as? NativeSSHError, .sessionNotRunning)
    }
    for run in runs.dropFirst() {
      try run.session.resize(rows: 33, columns: 99)
      try run.send("echo SZ3: $(stty size); printf '%s_%s\\n' 'ALIVE' '\(run.index)'\n")
    }
    for run in runs.dropFirst() {
      XCTAssertTrue(waitUntil { run.output.contains("SZ3: 33 99") && run.output.contains("ALIVE_\(run.index)") }, "session \(run.index) alive after sibling close")
      XCTAssertEqual(run.session.state, .running)
    }

    // 6. After closing all, no ssh child of this process remains.
    runs.forEach { $0.session.close() }
    XCTAssertTrue(waitUntil { Self.sshChildPIDs().subtracting(baseline).isEmpty }, "leaked ssh children: \(Self.sshChildPIDs().subtracting(baseline))")
  }

  // MARK: - Helpers

  private static func unstartedSession() -> NativeSSHSession {
    let devNull = URL(fileURLWithPath: "/dev/null")
    return NativeSSHSession(configuration: NativeSSHConfiguration(
      host: "127.0.0.1", port: 22, username: "user",
      knownHostsFileURL: devNull, authentication: .identityFile(devNull)))
  }

  private static func octalEscaped(_ text: String) -> String {
    text.utf8.map { byte -> String in
      guard byte >= 0x80 else { return String(UnicodeScalar(byte)) }
      let octal = String(byte, radix: 8)
      return "\\" + String(repeating: "0", count: 3 - octal.count) + octal
    }.joined()
  }

  /// PIDs of `/usr/bin/ssh` processes whose parent is this test process.
  private static func sshChildPIDs() -> Set<Int32> {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-ww", "-axo", "pid=,ppid=,command="]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let me = getpid()
    var pids = Set<Int32>()
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
      let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
      guard f.count == 3, let pid = Int32(f[0]), Int32(f[1]) == me, f[2].hasPrefix("/usr/bin/ssh") else { continue }
      pids.insert(pid)
    }
    return pids
  }

  private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      Thread.sleep(forTimeInterval: 0.05)
    }
    return condition()
  }

  private struct Fixture {
    let host: String, port: Int, user: String, knownHosts: URL, agentSocket: URL

    static func require() throws -> Fixture {
      let env = ProcessInfo.processInfo.environment
      guard let host = env["MRW_NATIVE_SSH_HOST"],
            let port = env["MRW_NATIVE_SSH_PORT"].flatMap(Int.init),
            let user = env["MRW_NATIVE_SSH_USER"],
            let root = env["MRW_NATIVE_FIXTURE_ROOT"] else {
        throw XCTSkip("MRW_NATIVE_SSH fixture environment not configured; skipping PTY parallel session tests.")
      }
      return Fixture(
        host: host, port: port, user: user,
        knownHosts: URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("known_hosts"),
        agentSocket: URL(fileURLWithPath: env["MRW_NATIVE_AGENT_SOCK"] ?? ""))
    }
  }

  private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
  }

  private final class Run: @unchecked Sendable {
    let index: Int
    let session: NativeSSHSession
    let collector = Collector()
    let rows: UInt16, cols: UInt16
    let utf8Text: String
    var output: String { String(decoding: collector.snapshot(), as: UTF8.self) }

    init(index: Int, fixture: Fixture) throws {
      self.index = index
      rows = UInt16(30 + index * 5)
      cols = UInt16(100 + index * 20)
      utf8Text = "Xin chào — 漢字 🙂 #\(index)"
      session = NativeSSHSession(configuration: NativeSSHConfiguration(
        host: fixture.host, port: fixture.port, username: fixture.user,
        knownHostsFileURL: fixture.knownHosts,
        authentication: .agent(socketURL: fixture.agentSocket),
        initialTerminalSize: NativeSSHTerminalSize(rows: 24, columns: 80)))
      let collector = self.collector
      session.onOutput = { collector.append($0) }
      try session.start()
    }

    func send(_ command: String) throws { try session.write(string: command) }
  }
}
