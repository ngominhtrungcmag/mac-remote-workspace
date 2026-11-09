import Darwin
import Foundation
import XCTest
@testable import AppCore

/// S1-04 / FR-010 / TC-010 / SEC-T05: SFTP upload idle timeout & remote progress tests.
final class SFTPTransferTimeoutTests: XCTestCase {
  private final class ProgressEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []

    func append(_ value: Int64) {
      lock.lock()
      defer { lock.unlock() }
      values.append(value)
    }

    var snapshot: [Int64] {
      lock.lock()
      defer { lock.unlock() }
      return values
    }
  }

  private var tempDir: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("mrw-sftp-timeout-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: tempDir,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
  }

  override func tearDownWithError() throws {
    if let dir = tempDir {
      try? FileManager.default.removeItem(at: dir)
    }
    try super.tearDownWithError()
  }

  // MARK: - Parser & Bounded Streaming Unit Tests

  func testUploadDiagnosticStreamParsesFragmentedAcksAndDiscardsDebugNoise() {
    let stream = SFTPUploadDiagnosticStream()
    let collector = SFTPOutputCollector(limit: 4096)
    var observed: [Int64] = []

    let payload = """
    debug1: OpenSSH_10.5p1, LibreSSL 3.3.6\r
    debug3: Started with: /usr/bin/ssh -v -v -v secret-canary-path\r
    Authenticated to 127.0.0.1 ([127.0.0.1]:22) using "publickey".\r
    debug3: SSH2_FXP_STATUS 0
    debug3: In write loop, ack for 6 261120 bytes at 0\r
    debug3: SSH2_FXP_STATUS 0
    debug3: In write loop, ack for 7 261120 bytes at 261120\r
    debug3: SSH2_FXP_STATUS 0
    debug3: In write loop, ack for 8 261120 bytes at 0\r
    debug3: SSH2_FXP_STATUS 0
    debug3: In write loop, ack for 9 4096 bytes at 522240\r
    dest open "/restricted/file": Permission denied\r
      #0 client-session (t4 [session:subsystem:sftp] r0)\r
    Transferred: sent 1055368, received 4640 bytes, in 0.0 seconds\r
    Bytes per second: sent 71250877.6, received 313259.5\r\n
    """
    let bytes = Array(payload.utf8)
    // Feed in tiny 7-byte chunks to exercise arbitrary pipe boundary fragmentation
    var index = 0
    while index < bytes.count {
      let end = min(index + 7, bytes.count)
      stream.consume(Data(bytes[index..<end]), into: collector) { observed.append($0) }
      index = end
    }
    stream.finish(into: collector) { observed.append($0) }

    // Every successful reply counts, even when the server reorders offsets.
    XCTAssertEqual(observed, [261120, 522240, 783360, 787456])
    XCTAssertEqual(stream.acknowledgedBytes, 787456)

    let retained = String(data: collector.data, encoding: .utf8) ?? ""
    XCTAssertTrue(retained.isEmpty)
    XCTAssertFalse(retained.contains("secret-canary-path"))
    XCTAssertFalse(retained.contains("debug"))
    XCTAssertFalse(retained.contains("Authenticated to"))
  }

  func testUploadDiagnosticStreamRejectsMalformedAndOverflowingAckLines() {
    let stream = SFTPUploadDiagnosticStream()
    let collector = SFTPOutputCollector(limit: 4096)
    var observed: [Int64] = []

    let malformed = """
    debug3: SSH2_FXP_STATUS 0
    debug3: In write loop, ack for abc 100 bytes at 0
    debug3: SSH2_FXP_STATUS 0
    debug3: In write loop, ack for 1 0 bytes at 0
    debug3: SSH2_FXP_STATUS 0
    debug3: In write loop, ack for 1 -50 bytes at 100
    debug3: SSH2_FXP_STATUS 0
    debug3: In write loop, ack for 1 100 bytes at -10
    debug3: SSH2_FXP_STATUS 0
    debug3: In write loop, ack for 1 100 bytes at \(Int64.max)
    debug2: In write loop, ack for 1 100 bytes at 0
    not-debug: In write loop, ack for 1 100 bytes at 0\n
    """
    stream.consume(Data(malformed.utf8), into: collector) { observed.append($0) }
    stream.finish(into: collector) { observed.append($0) }

    XCTAssertTrue(observed.isEmpty)
    XCTAssertEqual(stream.acknowledgedBytes, 0)
    let retained = String(data: collector.data, encoding: .utf8) ?? ""
    XCTAssertTrue(retained.isEmpty)
  }

  func testFailedOrUnpairedAcknowledgementsNeverReportProgressOrRetainDiagnostics() {
    let stream = SFTPUploadDiagnosticStream()
    let collector = SFTPOutputCollector(limit: 4096)
    var observed: [Int64] = []
    stream.consume(Data("""
    debug3: In write loop, ack for 1 100 bytes at 0
    debug3: SSH2_FXP_STATUS 4
    debug3: In write loop, ack for 2 100 bytes at 0
    debug3: SSH2_FXP_STATUS 0
    secret-canary-unprefixed-diagnostic
    debug3: In write loop, ack for 3 100 bytes at 0
    debug3: SSH2_FXP_STATUS 0
    debug3: In write loop, ack for 4 100 bytes at 0

    """.utf8), into: collector) { observed.append($0) }
    XCTAssertEqual(observed, [100])
    XCTAssertTrue(collector.data.isEmpty)
  }

  func testUploadDiagnosticStreamBoundsOversizedLinesWithoutOverflowingCollector() {
    let stream = SFTPUploadDiagnosticStream()
    let collector = SFTPOutputCollector(limit: 1024)
    var observed: [Int64] = []

    // 20 KiB single line without newline followed by a valid ack line
    var oversized = Data(repeating: 0x41, count: 20_000)
    oversized.append(0x0A)
    let validAck = Data("debug3: SSH2_FXP_STATUS 0\ndebug3: In write loop, ack for 4 32768 bytes at 0\n".utf8)

    stream.consume(oversized, into: collector) { observed.append($0) }
    stream.consume(validAck, into: collector) { observed.append($0) }
    stream.finish(into: collector) { observed.append($0) }

    XCTAssertEqual(observed, [32768])
    XCTAssertFalse(collector.didExceedLimit)
    XCTAssertTrue(collector.data.isEmpty)
  }

  func testPipeDeliversFragmentedAckWhileWriterRemainsOpen() throws {
    let pipe = Pipe()
    defer {
      try? pipe.fileHandleForReading.close()
      try? pipe.fileHandleForWriting.close()
    }
    let reader = try SFTPNonblockingPipe(pipe.fileHandleForReading)
    XCTAssertNil(try reader.read())
    let ack = Data("debug3: SSH2_FXP_STATUS 0\ndebug3: In write loop, ack for 1 100 bytes at 0\n".utf8)
    try pipe.fileHandleForWriting.write(contentsOf: ack)
    XCTAssertEqual(try reader.read(), ack)
    XCTAssertFalse(reader.reachedEOF)
    try pipe.fileHandleForWriting.close()
    XCTAssertNil(try reader.read())
    XCTAssertTrue(reader.reachedEOF)
  }

  func testIdleClockOnlyAdvancesForIncreasingAcknowledgements() {
    var idle = SFTPIdleTracker(now: 0)
    XCTAssertTrue(idle.observe(size: 100, now: 400_000_000))
    XCTAssertFalse(idle.hasTimedOut(now: 800_000_000, seconds: 0.5))
    XCTAssertFalse(idle.observe(size: 100, now: 850_000_000))
    XCTAssertTrue(idle.hasTimedOut(now: 900_000_000, seconds: 0.5))
  }

  func testTeardownTerminatesSSHShapedChildAndReleasesInheritedPipe() throws {
    let childFile = tempDir.appendingPathComponent("child-pid")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", """
    import os, signal, sys, time
    child = os.fork()
    if child == 0:
        while True: time.sleep(1)
    def stop(signum, frame):
        os.waitpid(child, 0)
        sys.exit(0)
    signal.signal(signal.SIGTERM, stop)
    with open(sys.argv[1], 'w') as f: f.write(str(child))
    while True: time.sleep(1)
    """, childFile.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
      if process.isRunning { _ = SFTPProcessTeardown.stop(process) }
      try? pipe.fileHandleForReading.close()
    }
    XCTAssertEqual(getpgid(process.processIdentifier), process.processIdentifier)
    var child: Int32?
    for _ in 0..<200 {
      if let text = try? String(contentsOf: childFile, encoding: .utf8), let pid = Int32(text) {
        child = pid
        break
      }
      usleep(5_000)
    }
    let childPID = try XCTUnwrap(child)
    let start = Date()
    XCTAssertTrue(SFTPProcessTeardown.stop(process))
    XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    XCTAssertEqual(kill(childPID, 0), -1, "Child must be reaped, not orphaned")
    XCTAssertEqual(errno, ESRCH)
    let reader = try SFTPNonblockingPipe(pipe.fileHandleForReading)
    XCTAssertNil(try reader.read())
    XCTAssertTrue(reader.reachedEOF)
  }

  func testTeardownEscalatesWhenSubprocessIgnoresSIGTERM() throws {
    let readyFile = tempDir.appendingPathComponent("ready")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", """
    import signal, sys, time
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    open(sys.argv[1], 'w').close()
    while True: time.sleep(1)
    """, readyFile.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer { if process.isRunning { _ = SFTPProcessTeardown.stop(process) } }
    XCTAssertEqual(getpgid(process.processIdentifier), process.processIdentifier)
    for _ in 0..<200 {
      if FileManager.default.fileExists(atPath: readyFile.path) { break }
      usleep(5_000)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: readyFile.path))
    let start = Date()
    XCTAssertTrue(SFTPProcessTeardown.stop(process))
    XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    XCTAssertEqual(kill(-process.processIdentifier, 0), -1)
    XCTAssertEqual(errno, ESRCH)
  }

  private func assertNoSFTPProcess(using knownHosts: URL, file: StaticString = #filePath, line: UInt = #line) throws {
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    probe.arguments = ["-f", knownHosts.path]
    probe.standardOutput = FileHandle.nullDevice
    probe.standardError = FileHandle.nullDevice
    try probe.run()
    probe.waitUntilExit()
    XCTAssertEqual(probe.terminationStatus, 1, "SFTP or SSH subprocess survived transfer teardown", file: file, line: line)
  }

  // MARK: - Live Fixture & Proxy Tests (Stall, Advancing Transfer, Cancel, Cleanup)

  private struct FixtureEnv {
    let host: String
    let port: Int
    let user: String
    let root: String
    let agentSock: String
  }

  private func requireFixtureEnv() throws -> FixtureEnv {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["MRW_NATIVE_SSH_HOST"],
          let port = env["MRW_NATIVE_SSH_PORT"].flatMap(Int.init),
          let user = env["MRW_NATIVE_SSH_USER"],
          let root = env["MRW_NATIVE_FIXTURE_ROOT"],
          let sock = env["MRW_NATIVE_AGENT_SOCK"] else {
      throw XCTSkip("MRW_NATIVE_SSH fixture environment not configured.")
    }
    return FixtureEnv(host: host, port: port, user: user, root: root, agentSock: sock)
  }

  private func makeKnownHosts(forPort port: Int, from rootKnownHosts: URL) throws -> URL {
    let raw = try String(contentsOf: rootKnownHosts, encoding: .utf8)
    let rewritten = raw
      .components(separatedBy: .newlines)
      .compactMap { line -> String? in
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        let parts = trimmed.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 3 else { return nil }
        return "[127.0.0.1]:\(port) \(parts[1]) \(parts[2])"
      }
      .joined(separator: "\n") + "\n"
    let url = tempDir.appendingPathComponent("known_hosts_\(port)_\(UUID().uuidString.prefix(6))")
    try rewritten.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  private func writeRandomFile(_ url: URL, bytes count: Int) throws {
    var data = Data(count: count)
    _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
    try data.write(to: url, options: .atomic)
  }

  /// Launches a disposable local TCP proxy in front of the fixture sshd that either:
  /// - throttles client->server throughput after the SSH handshake (`throttleBytesPerStep` every `stepDelayMs`), or
  /// - freezes client->server traffic after forwarding `stallAfterClientBytes` bytes (while optionally allowing later cleanup connections through).
  private func startTCPProxy(
    targetHost: String,
    targetPort: Int,
    stallFirstConnectionAfterBytes: Int? = nil,
    throttleBytesPerStep: Int = 16384,
    stepDelaySec: Double = 0.0
  ) throws -> (port: Int, stop: () -> Void) {
    let portFile = tempDir.appendingPathComponent("proxy_port_\(UUID().uuidString).txt")
    let script = """
    import socket, sys, threading, time

    target_host = sys.argv[1]
    target_port = int(sys.argv[2])
    port_file = sys.argv[3]
    stall_after = int(sys.argv[4])
    chunk_size = int(sys.argv[5])
    step_delay = float(sys.argv[6])

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(16)
    with open(port_file, "w") as f:
        f.write(str(srv.getsockname()[1]))

    conn_Lock = threading.Lock()
    conn_index = [0]

    def pipe_c2s(src, dst, idx):
        sent = 0
        try:
            while True:
                data = src.recv(chunk_size)
                if not data:
                    try: dst.shutdown(socket.SHUT_WR)
                    except Exception: pass
                    return
                if idx == 1 and stall_after > 0 and sent + len(data) >= stall_after:
                    remain = max(0, stall_after - sent)
                    if remain > 0:
                        dst.sendall(data[:remain])
                    # Stall connection #1 indefinitely until client closes or process terminates
                    while True:
                        time.sleep(0.2)
                        probe = src.recv(1024)
                        if not probe:
                            return
                dst.sendall(data)
                sent += len(data)
                if idx == 1 and step_delay > 0 and sent > 16384:
                    time.sleep(step_delay)
        except Exception:
            pass

    def pipe_s2c(src, dst):
        try:
            while True:
                data = src.recv(65536)
                if not data:
                    try: dst.shutdown(socket.SHUT_WR)
                    except Exception: pass
                    return
                dst.sendall(data)
        except Exception:
            pass

    while True:
        client, _ = srv.accept()
        with conn_Lock:
            conn_index[0] += 1
            idx = conn_index[0]
        up = socket.create_connection((target_host, target_port))
        threading.Thread(target=pipe_c2s, args=(client, up, idx), daemon=True).start()
        threading.Thread(target=pipe_s2c, args=(up, client), daemon=True).start()
    """
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    proc.arguments = [
      "-c", script,
      targetHost,
      String(targetPort),
      portFile.path,
      String(stallFirstConnectionAfterBytes ?? 0),
      String(throttleBytesPerStep),
      String(stepDelaySec),
    ]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    try proc.run()

    for _ in 0..<100 {
      if let text = try? String(contentsOf: portFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
         let port = Int(text), port > 0 {
        return (port, {
          if proc.isRunning {
            proc.terminate()
            _ = kill(proc.processIdentifier, SIGKILL)
            proc.waitUntilExit()
          }
        })
      }
      usleep(20_000)
    }
    proc.terminate()
    throw XCTSkip("Failed to start local TCP proxy for SFTP timeout test.")
  }

  func testAdvancingUploadExceedingIdleWindowCompletesAndReportsRemoteProgressIfFixtureAvailable() throws {
    let fixture = try requireFixtureEnv()
    let directClient = try NativeSFTPClient(
      configuration: NativeSSHConfiguration(
        host: fixture.host,
        port: fixture.port,
        username: fixture.user,
        knownHostsFileURL: URL(fileURLWithPath: fixture.root).appendingPathComponent("known_hosts"),
        authentication: .agent(socketURL: URL(fileURLWithPath: fixture.agentSock))
      )
    )
    let remoteDir = "\(fixture.root)/s104-advance-\(UUID().uuidString.prefix(8))"
    try directClient.createDirectory(at: remoteDir)
    defer { try? FileManager.default.removeItem(atPath: remoteDir) }

    // 1.5 MiB upload throttled so total wall time (~1.8s) is well above the 0.6s idle timeout,
    // while server write ACKs arrive every ~0.2s and reset SFTPIdleTracker.
    let proxy = try startTCPProxy(
      targetHost: fixture.host,
      targetPort: fixture.port,
      stallFirstConnectionAfterBytes: nil,
      throttleBytesPerStep: 65536,
      stepDelaySec: 0.07
    )
    defer { proxy.stop() }

    let proxyKnownHosts = try makeKnownHosts(
      forPort: proxy.port,
      from: URL(fileURLWithPath: fixture.root).appendingPathComponent("known_hosts")
    )
    let throttledClient = try NativeSFTPClient(
      configuration: NativeSSHConfiguration(
        host: "127.0.0.1",
        port: proxy.port,
        username: fixture.user,
        knownHostsFileURL: proxyKnownHosts,
        authentication: .agent(socketURL: URL(fileURLWithPath: fixture.agentSock))
      ),
      uploadIdleTimeoutSeconds: 0.6
    )

    let localSource = tempDir.appendingPathComponent("advancing.bin")
    let payloadSize = 1536 * 1024
    try writeRandomFile(localSource, bytes: payloadSize)
    let remoteTarget = "\(remoteDir)/advancing.bin"

    let progressEvents = ProgressEvents()
    let start = DispatchTime.now().uptimeNanoseconds

    try throttledClient.uploadFile(
      from: localSource,
      to: remoteTarget,
      overwrite: true,
      onProgress: { transferred, _ in
        progressEvents.append(transferred)
      }
    )

    let elapsedSec = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    XCTAssertGreaterThan(elapsedSec, 0.9, "Total transfer time should exceed the 0.6s per-idle window")
    XCTAssertTrue(progressEvents.snapshot.contains(where: { $0 > 0 && $0 < Int64(payloadSize) }), "Should report intermediate remote ACK progress")
    XCTAssertEqual(progressEvents.snapshot.last, Int64(payloadSize))
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: remoteTarget)), try Data(contentsOf: localSource))
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: remoteDir).filter { $0.contains(".mrw-part-") }
    XCTAssertTrue(leftovers.isEmpty, "No staging file may remain after successful upload")
    try assertNoSFTPProcess(using: proxyKnownHosts)
  }

  func testStalledUploadTimesOutCleansStagingAndPreservesExistingDestinationIfFixtureAvailable() throws {
    try checkInterruptedUpload(cancel: false)
  }

  func testCancelledUploadCleansStagingAndPreservesExistingDestinationIfFixtureAvailable() throws {
    try checkInterruptedUpload(cancel: true)
  }

  private func checkInterruptedUpload(cancel: Bool) throws {
    let fixture = try requireFixtureEnv()
    let directClient = try NativeSFTPClient(
      configuration: NativeSSHConfiguration(
        host: fixture.host,
        port: fixture.port,
        username: fixture.user,
        knownHostsFileURL: URL(fileURLWithPath: fixture.root).appendingPathComponent("known_hosts"),
        authentication: .agent(socketURL: URL(fileURLWithPath: fixture.agentSock))
      )
    )
    let remoteDir = "\(fixture.root)/s104-stall-\(UUID().uuidString.prefix(8))"
    try directClient.createDirectory(at: remoteDir)
    defer { try? FileManager.default.removeItem(atPath: remoteDir) }

    // Pre-populate an existing destination file to verify a stalled overwrite=true upload never corrupts it.
    let remoteTarget = "\(remoteDir)/target.bin"
    let originalData = Data("preserve-existing-destination-\(UUID().uuidString)".utf8)
    try originalData.write(to: URL(fileURLWithPath: remoteTarget), options: .atomic)

    // Stall connection #1 after ~350 KiB (so open + first write happens, creating the remote .mrw-part-* file,
    // then the connection freezes; connection #2 for `-rm` cleanup proceeds normally).
    let proxy = try startTCPProxy(
      targetHost: fixture.host,
      targetPort: fixture.port,
      stallFirstConnectionAfterBytes: 350_000,
      throttleBytesPerStep: 65536,
      stepDelaySec: 0.0
    )
    defer { proxy.stop() }

    let proxyKnownHosts = try makeKnownHosts(
      forPort: proxy.port,
      from: URL(fileURLWithPath: fixture.root).appendingPathComponent("known_hosts")
    )
    let stalledClient = try NativeSFTPClient(
      configuration: NativeSSHConfiguration(
        host: "127.0.0.1",
        port: proxy.port,
        username: fixture.user,
        knownHostsFileURL: proxyKnownHosts,
        authentication: .agent(socketURL: URL(fileURLWithPath: fixture.agentSock))
      ),
      uploadIdleTimeoutSeconds: 0.45
    )

    let localSource = tempDir.appendingPathComponent("stalled.bin")
    try writeRandomFile(localSource, bytes: 4 * 1024 * 1024)

    let start = DispatchTime.now().uptimeNanoseconds
    XCTAssertThrowsError(
      try stalledClient.uploadFile(from: localSource, to: remoteTarget, overwrite: true,
        isCancelled: { cancel && DispatchTime.now().uptimeNanoseconds - start > 300_000_000 })
    ) { error in
      if cancel {
        XCTAssertEqual(error as? SFTPError, .cancelled)
      } else {
        guard case SFTPError.remoteError(let details) = error else {
          return XCTFail("Expected timeout, got \(error)")
        }
        XCTAssertTrue(details.contains("timed out"))
      }
    }
    let elapsedSec = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    XCTAssertLessThan(elapsedSec, 5.0, "Stalled upload must fail within bounded idle timeout")

    // Existing destination must be untouched and staging `.mrw-part-*` file must be cleaned up.
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: remoteTarget)), originalData)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: remoteDir).filter { $0.contains(".mrw-part-") }
    XCTAssertTrue(leftovers.isEmpty, "Stalled upload must remove its remote .mrw-part-* staging file")
    try assertNoSFTPProcess(using: proxyKnownHosts)
  }
}
