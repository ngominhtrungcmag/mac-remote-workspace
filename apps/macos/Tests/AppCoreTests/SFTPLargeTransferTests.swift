import CryptoKit
import Foundation
import XCTest
@testable import AppCore

/// TC-009 / SEC-T05 / FR-010 evidence: large-file byte verification and interrupted-transfer safety.
/// Fixture-gated like NativeSFTPTests; the loopback fixture's "remote" filesystem is the local disk
/// under MRW_NATIVE_FIXTURE_ROOT, so remote bytes can be inspected directly. The 1 GB test also needs
/// MRW_SFTP_LARGE=1.
final class SFTPLargeTransferTests: XCTestCase {
  private var tempDir: URL!
  private let mib = 1024 * 1024

  override func setUpWithError() throws {
    try super.setUpWithError()
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("mrw-sftp-large-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  override func tearDownWithError() throws {
    if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
    try super.tearDownWithError()
  }

  // MARK: - Helpers

  private func makeFixtureClient() throws -> (NativeSFTPClient, String) {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["MRW_NATIVE_SSH_HOST"],
          let port = env["MRW_NATIVE_SSH_PORT"].flatMap(Int.init),
          let user = env["MRW_NATIVE_SSH_USER"],
          let root = env["MRW_NATIVE_FIXTURE_ROOT"],
          let sock = env["MRW_NATIVE_AGENT_SOCK"] else {
      throw XCTSkip("MRW_NATIVE_SSH fixture environment not configured.")
    }
    let rootURL = URL(fileURLWithPath: root, isDirectory: true)
    return (try NativeSFTPClient(configuration: NativeSSHConfiguration(
      host: host, port: port, username: user,
      knownHostsFileURL: rootURL.appendingPathComponent("known_hosts"),
      authentication: .agent(socketURL: URL(fileURLWithPath: sock)))), root)
  }

  /// Fresh remote directory, removed at test teardown.
  private func makeRemoteDir(_ client: NativeSFTPClient, root: String) throws -> String {
    let dir = "\(root)/tc009-\(UUID().uuidString.prefix(8))"
    try client.createDirectory(at: dir)
    addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
    return dir
  }

  /// Writes `megabytes` MiB of fresh random bytes (one random buffer per MiB) and returns its SHA-256.
  @discardableResult
  private func writeRandomFile(_ url: URL, megabytes: Int) throws -> String {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    var buffer = [UInt8](repeating: 0, count: mib)
    for _ in 0..<megabytes {
      guard SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer) == errSecSuccess else {
        throw XCTSkip("SecRandomCopyBytes failed")
      }
      try handle.write(contentsOf: buffer)
    }
    return try sha256(url)
  }

  private func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 4 * mib), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func fileSize(_ path: String) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.intValue ?? -1
  }

  private func partFiles(in dir: String) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.contains(".mrw-part-") }
  }

  /// True once a staging file for `name` in `dir` holds bytes but is still smaller than `total`.
  private func stagingInFlight(dir: String, name: String, total: Int) -> Bool {
    let parts = ((try? partFiles(in: dir)) ?? []).filter { $0.hasPrefix(name) }
    guard let part = parts.first else { return false }
    let size = fileSize("\(dir)/\(part)")
    return size >= mib && size < total
  }

  private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
  }

  private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?
    private var succeeded = false
    func finish(_ error: Error?) { lock.lock(); stored = error; succeeded = (error == nil); lock.unlock() }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return stored }
    var didSucceed: Bool { lock.lock(); defer { lock.unlock() }; return succeeded }
  }

  /// Runs `work` on a background thread, sets its cancel flag as soon as `midTransfer()` is true,
  /// and returns what `work` threw. Fails the test if the transfer finished before the cancel point
  /// or reported success.
  private func cancelMidTransfer(
    midTransfer: () -> Bool,
    work: @escaping @Sendable (@escaping @Sendable () -> Bool) throws -> Void
  ) -> Error? {
    let cancel = Flag()
    let outcome = Outcome()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      do { try work { cancel.isSet }; outcome.finish(nil) } catch { outcome.finish(error) }
      done.signal()
    }
    let deadline = Date().addingTimeInterval(120)
    var cancelledMidTransfer = false
    var finished = false
    while Date() < deadline {
      if done.wait(timeout: .now() + 0.005) == .success { finished = true; break }
      if !cancel.isSet, midTransfer() { cancelledMidTransfer = true; cancel.set() }
    }
    if !finished { cancel.set() }
    if !finished { finished = done.wait(timeout: .now() + 60) == .success }
    XCTAssertTrue(finished, "transfer did not stop after cancel")
    XCTAssertTrue(cancelledMidTransfer, "transfer ended before staging bytes were observed; cancel was not mid-transfer")
    XCTAssertFalse(outcome.didSucceed, "cancelled transfer must never report success")
    return outcome.error
  }

  // MARK: - Round trips (TC-009)

  private func assertRoundTrip(megabytes: Int) throws {
    let (client, root) = try makeFixtureClient()
    let remoteDir = try makeRemoteDir(client, root: root)
    let source = tempDir.appendingPathComponent("src.bin")
    let expected = try writeRandomFile(source, megabytes: megabytes)
    let size = Int64(megabytes * mib)
    let remotePath = "\(remoteDir)/payload.bin"

    try client.uploadFile(from: source, to: remotePath, overwrite: false)
    let entries = try client.listDirectory(at: remoteDir)
    XCTAssertEqual(entries.map(\.name), ["payload.bin"], "no .mrw-part file may remain remotely")
    XCTAssertEqual(entries.first?.size, size)
    XCTAssertEqual(try partFiles(in: remoteDir), [])
    XCTAssertEqual(try sha256(URL(fileURLWithPath: remotePath)), expected, "remote bytes differ after upload")

    let downloads = tempDir.appendingPathComponent("downloads", isDirectory: true)
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let downloaded = try client.downloadFile(from: remotePath, to: downloads, filename: "back.bin", overwrite: false)
    XCTAssertEqual(fileSize(downloaded.path), Int(size))
    XCTAssertEqual(try sha256(downloaded), expected, "local bytes differ after download")
    XCTAssertEqual(try partFiles(in: downloads.path), [], "no .mrw-part file may remain locally")
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path), ["back.bin"])
  }

  func testTenMegabyteRoundTripPreservesSHA256IfFixtureAvailable() throws {
    try assertRoundTrip(megabytes: 10)
  }

  func testOneGigabyteRoundTripPreservesSHA256IfFixtureAndLargeEnabled() throws {
    guard ProcessInfo.processInfo.environment["MRW_SFTP_LARGE"] == "1" else {
      throw XCTSkip("MRW_SFTP_LARGE=1 not set; skipping 1 GB round trip.")
    }
    try assertRoundTrip(megabytes: 1024)
  }

  // MARK: - Interrupted download (SEC-T05)

  func testInterruptedDownloadLeavesNoFinalFileAndPreservesExistingDestinationIfFixtureAvailable() throws {
    let (client, root) = try makeFixtureClient()
    let remoteDir = try makeRemoteDir(client, root: root)
    let remotePath = "\(remoteDir)/big.bin"
    try writeRandomFile(URL(fileURLWithPath: remotePath), megabytes: 200)
    let total = 200 * mib

    for existing in [false, true] {
      let dest = tempDir.appendingPathComponent("dl-existing-\(existing)", isDirectory: true)
      try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
      let final = dest.appendingPathComponent("out.bin")
      var before: String?
      if existing {
        before = try writeRandomFile(final, megabytes: 1)
        // overwrite=false against an existing destination is refused up front and leaves it intact.
        XCTAssertThrowsError(try client.downloadFile(from: remotePath, to: dest, filename: "out.bin", overwrite: false)) {
          XCTAssertEqual($0 as? SFTPError, .collision(final.path))
        }
        XCTAssertEqual(try sha256(final), before)
      }

      let error = cancelMidTransfer(
        midTransfer: { self.stagingInFlight(dir: dest.path, name: "out.bin", total: total) },
        work: { cancel in
          _ = try client.downloadFile(from: remotePath, to: dest, filename: "out.bin", overwrite: existing, isCancelled: cancel)
        })

      XCTAssertEqual(error as? SFTPError, .cancelled)
      XCTAssertEqual(try partFiles(in: dest.path), [], "staging file must be removed")
      if let before {
        XCTAssertEqual(try sha256(final), before, "pre-existing destination must be byte-identical")
        XCTAssertEqual(fileSize(final.path), mib)
      } else {
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path), "no final file after interrupted download")
      }
    }
  }

  // MARK: - Interrupted upload (SEC-T05)

  func testInterruptedUploadNeverLeavesPartialRemoteFileIfFixtureAvailable() throws {
    let (client, root) = try makeFixtureClient()
    let remoteDir = try makeRemoteDir(client, root: root)
    let source = tempDir.appendingPathComponent("big-up.bin")
    try writeRandomFile(source, megabytes: 200)
    let total = 200 * mib

    // Fresh target: after cancel, neither the target nor a staging file exists.
    let fresh = "\(remoteDir)/fresh.bin"
    var error = cancelMidTransfer(
      midTransfer: { self.stagingInFlight(dir: remoteDir, name: "fresh.bin", total: total) },
      work: { cancel in try client.uploadFile(from: source, to: fresh, overwrite: false, isCancelled: cancel) })
    XCTAssertEqual(error as? SFTPError, .cancelled)
    XCTAssertEqual(try client.listDirectory(at: remoteDir).map(\.name), [], "no target or .mrw-part file may remain")
    XCTAssertFalse(FileManager.default.fileExists(atPath: fresh))

    // Existing target: overwrite=false is refused; an interrupted overwrite=true leaves the old bytes intact.
    let existing = "\(remoteDir)/existing.bin"
    let before = try writeRandomFile(URL(fileURLWithPath: existing), megabytes: 1)
    XCTAssertThrowsError(try client.uploadFile(from: source, to: existing, overwrite: false)) {
      XCTAssertEqual($0 as? SFTPError, .collision(existing))
    }
    XCTAssertEqual(try sha256(URL(fileURLWithPath: existing)), before)

    error = cancelMidTransfer(
      midTransfer: { self.stagingInFlight(dir: remoteDir, name: "existing.bin", total: total) },
      work: { cancel in try client.uploadFile(from: source, to: existing, overwrite: true, isCancelled: cancel) })
    XCTAssertEqual(error as? SFTPError, .cancelled)
    XCTAssertEqual(try partFiles(in: remoteDir), [], "staging file must be removed")
    XCTAssertEqual(try sha256(URL(fileURLWithPath: existing)), before, "pre-existing remote file must be byte-identical")
    XCTAssertEqual(try client.listDirectory(at: remoteDir).map(\.name), ["existing.bin"])
  }
}
