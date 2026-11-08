import Combine
import Foundation
import XCTest
@testable import AppCore

final class NativeSFTPTests: XCTestCase {
  private var tempDir: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("mrw-sftp-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  override func tearDownWithError() throws {
    if let dir = tempDir {
      try? FileManager.default.removeItem(at: dir)
    }
    try super.tearDownWithError()
  }

  func testProxyJumpIsRejectedInsteadOfConnectingDirectly() throws {
    let knownHosts = tempDir.appendingPathComponent("known_hosts")
    let agent = tempDir.appendingPathComponent("agent.sock")
    try Data().write(to: knownHosts)
    try Data().write(to: agent)
    let config = NativeSSHConfiguration(
      host: "target.example", username: "user", knownHostsFileURL: knownHosts,
      authentication: .agent(socketURL: agent),
      proxyJump: NativeSSHProxyJumpEndpoint(host: "jump.example", username: "user"))
    XCTAssertThrowsError(try NativeSFTPClient(configuration: config)) { error in
      guard case SFTPError.connectionFailed = error else { return XCTFail("Unexpected error: \(error)") }
    }
  }

  func testIdleTimeoutResetsOnlyWhenDownloadGrows() {
    var tracker = SFTPIdleTracker(now: 0)
    XCTAssertFalse(tracker.hasTimedOut(now: 9_000_000_000, seconds: 10))
    XCTAssertTrue(tracker.observe(size: 10, now: 9_000_000_000))
    XCTAssertFalse(tracker.observe(size: 10, now: 15_000_000_000))
    XCTAssertFalse(tracker.hasTimedOut(now: 18_000_000_000, seconds: 10))
    XCTAssertTrue(tracker.hasTimedOut(now: 19_000_000_000, seconds: 10))
  }

  // MARK: - Path Sanitization Tests (TC-008 / FR-009)

  func testSanitizeRemotePathNormalizesAndRejectsControlCharacters() throws {
    XCTAssertEqual(try NativeSFTPClient.sanitizeRemotePath("/"), "/")
    XCTAssertEqual(try NativeSFTPClient.sanitizeRemotePath("/var/log/"), "/var/log")
    XCTAssertEqual(try NativeSFTPClient.sanitizeRemotePath("/home/user/file.txt"), "/home/user/file.txt")
    XCTAssertEqual(try NativeSFTPClient.sanitizeRemotePath("  /etc/ssh  "), "  /etc/ssh  ")
    XCTAssertEqual(try NativeSFTPClient.sanitizeRemotePath("   "), "   ")

    // Empty or whitespace
    XCTAssertThrowsError(try NativeSFTPClient.sanitizeRemotePath("")) { err in
      guard case SFTPError.invalidPath = err else { return XCTFail("Expected invalidPath, got \(err)") }
    }

    // NUL byte and newline injection
    XCTAssertThrowsError(try NativeSFTPClient.sanitizeRemotePath("/path/with\0null")) { err in
      guard case SFTPError.invalidPath = err else { return XCTFail("Expected invalidPath, got \(err)") }
    }
    XCTAssertThrowsError(try NativeSFTPClient.sanitizeRemotePath("/path/with\nnewline")) { err in
      guard case SFTPError.invalidPath = err else { return XCTFail("Expected invalidPath, got \(err)") }
    }
    XCTAssertThrowsError(try NativeSFTPClient.sanitizeRemotePath("/path/with\rcarriage")) { err in
      guard case SFTPError.invalidPath = err else { return XCTFail("Expected invalidPath, got \(err)") }
    }
  }

  // MARK: - Output Parser Tests (FR-009)

  func testParseListingOutputExtractsMetadataAndSortsDirectoriesFirst() {
    let rawOutput = """
    sftp> cd "/tmp"
    sftp> ls -la
    drwxrwxrwt   30 root     wheel         960 Oct 30 19:40 .
    drwxr-xr-x    6 root     wheel         192 Oct 28 14:40 ..
    -rw-r--r--    1 user  staff        1024 Oct 30 19:45 test file.txt
    drwxr-xr-x    2 user  staff          64 Oct 30 19:46 folder1
    lrwxr-xr-x    1 user  staff          12 Oct 30 19:47 symlink_entry -> /var/folders
    -rwxr-xr-x@   1 user  staff       12345 Oct 30  2024 script.sh
    """

    let entries = NativeSFTPClient.parseListingOutput(rawOutput, inDirectory: "/tmp")
    XCTAssertEqual(entries.count, 4)

    // First entry must be the directory: folder1
    XCTAssertEqual(entries[0].name, "folder1")
    XCTAssertTrue(entries[0].isDirectory)
    XCTAssertFalse(entries[0].isSymlink)
    XCTAssertEqual(entries[0].path, "/tmp/folder1")
    XCTAssertEqual(entries[0].size, 64)

    // Next entries are sorted alphabetically: script.sh, symlink_entry, test file.txt
    XCTAssertEqual(entries[1].name, "script.sh")
    XCTAssertFalse(entries[1].isDirectory)
    XCTAssertEqual(entries[1].size, 12345)

    XCTAssertEqual(entries[2].name, "symlink_entry")
    XCTAssertTrue(entries[2].isSymlink)
    XCTAssertEqual(entries[2].symlinkTarget, "/var/folders")

    XCTAssertEqual(entries[3].name, "test file.txt")
    XCTAssertFalse(entries[3].isDirectory)
    XCTAssertEqual(entries[3].size, 1024)
  }

  func testAmbiguousSymlinkListingIsSkipped() {
    let line = "lrwxrwxrwx 1 user staff 1 Oct 30 19:45 a -> b -> c"
    XCTAssertTrue(NativeSFTPClient.parseListingOutput(line, inDirectory: "/tmp").isEmpty)
  }

  func testListingPreservesFilenameWhitespace() {
    let line = "-rw-r--r-- 1 user staff 3 Oct 30 19:45   name  "
    let entries = NativeSFTPClient.parseListingOutput(line, inDirectory: "/tmp")
    XCTAssertEqual(entries.first?.name, "  name  ")
    XCTAssertEqual(entries.first?.path, "/tmp/  name  ")
  }

  func testOutputCollectorBoundsMemoryAndRecordsOverflow() {
    let collector = SFTPOutputCollector(limit: 4)
    collector.append(Data([1, 2]))
    collector.append(Data([3, 4]))
    XCTAssertEqual(collector.data.count, 4)
    XCTAssertFalse(collector.didExceedLimit)
    collector.append(Data([5]))
    collector.append(Data([6, 7]))
    XCTAssertTrue(collector.didExceedLimit)
    XCTAssertEqual(collector.data, Data([1, 2, 3, 4]))
  }

  // MARK: - Safe Transfer Collision Tests (TC-010 / FR-010)

  func testSafeDownloadCollisionCheckPreventsSilentOverwrite() throws {
    let dummyFile = tempDir.appendingPathComponent("existing.txt")
    try "original content".write(to: dummyFile, atomically: true, encoding: .utf8)

    let dummyKnownHosts = tempDir.appendingPathComponent("known_hosts")
    try "".write(to: dummyKnownHosts, atomically: true, encoding: .utf8)

    let dummyAgentSock = tempDir.appendingPathComponent("agent.sock")
    FileManager.default.createFile(atPath: dummyAgentSock.path, contents: Data())

    let config = NativeSSHConfiguration(
      host: "127.0.0.1",
      port: 22,
      username: "user",
      knownHostsFileURL: dummyKnownHosts,
      authentication: .agent(socketURL: dummyAgentSock)
    )

    let client = try NativeSFTPClient(configuration: config)

    // downloadFile with overwrite = false must throw collision error before spawning any process
    XCTAssertThrowsError(
      try client.downloadFile(
        from: "/remote/path.txt",
        to: tempDir,
        filename: "existing.txt",
        overwrite: false
      )
    ) { err in
      guard case SFTPError.collision = err else {
        return XCTFail("Expected collision error, got \(err)")
      }
    }

    // Verify existing file content remains untouched
    let preserved = try String(contentsOf: dummyFile, encoding: .utf8)
    XCTAssertEqual(preserved, "original content")
  }

  func testDownloadCommitRejectsDestinationCreatedAfterPreflight() throws {
    let stage = tempDir.appendingPathComponent("stage")
    let target = tempDir.appendingPathComponent("target")
    try "download".write(to: stage, atomically: true, encoding: .utf8)
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    try "original".write(to: target, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try NativeSFTPClient.commitDownloadedFile(stage, to: target, overwrite: false)) { error in
      XCTAssertEqual(error as? SFTPError, .collision(target.path))
    }
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original")
    XCTAssertEqual(try String(contentsOf: stage, encoding: .utf8), "download")
  }

  func testDownloadCommitPreservesDanglingSymlinkAndMovesWhenAbsent() throws {
    let stage = tempDir.appendingPathComponent("stage")
    let target = tempDir.appendingPathComponent("target")
    try "download".write(to: stage, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: "missing")
    XCTAssertThrowsError(try NativeSFTPClient.commitDownloadedFile(stage, to: target, overwrite: false)) { error in
      XCTAssertEqual(error as? SFTPError, .collision(target.path))
    }
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target.path), "missing")
    try FileManager.default.removeItem(at: target)
    try NativeSFTPClient.commitDownloadedFile(stage, to: target, overwrite: false)
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "download")
    XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
  }

  func testDownloadRejectsPathTraversalFilenameBeforeConnecting() throws {
    let knownHosts = tempDir.appendingPathComponent("known_hosts")
    let agent = tempDir.appendingPathComponent("agent.sock")
    try Data().write(to: knownHosts)
    try Data().write(to: agent)
    let client = try NativeSFTPClient(configuration: NativeSSHConfiguration(
      host: "127.0.0.1", username: "user", knownHostsFileURL: knownHosts,
      authentication: .agent(socketURL: agent)))
    for name in ["../outside", "/absolute", ".", "..", "a/b", "bad\0name"] {
      XCTAssertThrowsError(try client.downloadFile(from: "/remote/file", to: tempDir, filename: name, overwrite: false)) { error in
        guard case SFTPError.invalidPath = error else { return XCTFail("Expected invalid path, got \(error)") }
      }
    }
  }

  func testSafeUploadNonexistentLocalFileThrowsFileNotFound() throws {
    let dummyKnownHosts = tempDir.appendingPathComponent("known_hosts")
    try "".write(to: dummyKnownHosts, atomically: true, encoding: .utf8)

    let dummyAgentSock = tempDir.appendingPathComponent("agent.sock")
    FileManager.default.createFile(atPath: dummyAgentSock.path, contents: Data())

    let config = NativeSSHConfiguration(
      host: "127.0.0.1",
      port: 22,
      username: "user",
      knownHostsFileURL: dummyKnownHosts,
      authentication: .agent(socketURL: dummyAgentSock)
    )

    let client = try NativeSFTPClient(configuration: config)
    let missingURL = tempDir.appendingPathComponent("missing.txt")

    XCTAssertThrowsError(
      try client.uploadFile(from: missingURL, to: "/remote/file.txt", overwrite: false)
    ) { err in
      guard case SFTPError.fileNotFound = err else {
        return XCTFail("Expected fileNotFound, got \(err)")
      }
    }
  }

  func testCancelledUploadStopsBeforeConnecting() throws {
    let knownHosts = tempDir.appendingPathComponent("known_hosts")
    let agent = tempDir.appendingPathComponent("agent.sock")
    let local = tempDir.appendingPathComponent("upload")
    try Data().write(to: knownHosts)
    try Data().write(to: agent)
    try Data().write(to: local)
    let client = try NativeSFTPClient(configuration: NativeSSHConfiguration(
      host: "127.0.0.1", username: "user", knownHostsFileURL: knownHosts,
      authentication: .agent(socketURL: agent)))
    XCTAssertThrowsError(try client.uploadFile(from: local, to: "/remote/file", overwrite: false,
      isCancelled: { true })) { error in
      XCTAssertEqual(error as? SFTPError, .cancelled)
    }
  }

  func testUploadPropagatesDirectoryListingFailure() throws {
    let knownHosts = tempDir.appendingPathComponent("known_hosts")
    let agent = tempDir.appendingPathComponent("agent.sock")
    let local = tempDir.appendingPathComponent("upload")
    try Data().write(to: knownHosts)
    try Data().write(to: agent)
    try Data().write(to: local)
    let client = try NativeSFTPClient(configuration: NativeSSHConfiguration(
      host: "127.0.0.1", port: 1, username: "user", knownHostsFileURL: knownHosts,
      authentication: .agent(socketURL: agent)))
    XCTAssertThrowsError(try client.uploadFile(from: local, to: "/remote/file", overwrite: false))
  }

  // MARK: - Transfer Queue Lifecycle & Cancellation (FR-010)

  @MainActor
  func testTransferQueueCancellationAndClearFinished() {
    let queue = SFTPTransferQueue()

    let item1 = SFTPTransferItem(
      id: UUID(),
      kind: .upload,
      sourceDescription: "file1.txt",
      destinationDescription: "/remote/file1.txt",
      totalBytes: 1000,
      transferredBytes: 500,
      status: .running(progress: 0.5)
    )

    let item2 = SFTPTransferItem(
      id: UUID(),
      kind: .download,
      sourceDescription: "/remote/file2.txt",
      destinationDescription: "/local/file2.txt",
      totalBytes: 2000,
      transferredBytes: 2000,
      status: .completed
    )

    queue.insertActiveItemForTesting(item1)
    queue.insertItemForTesting(item2)

    XCTAssertTrue(queue.hasActiveTransfers)

    queue.cancelTransfer(id: item1.id)
    XCTAssertTrue(queue.hasActiveTransfers)
    XCTAssertEqual(queue.items.first(where: { $0.id == item2.id })?.status, .completed)
    XCTAssertEqual(queue.items.first(where: { $0.id == item1.id })?.status, .running(progress: 0.5))
    queue.updateProgress(id: item1.id, transferred: 900, total: 1000)
    XCTAssertEqual(queue.items.first(where: { $0.id == item1.id })?.transferredBytes, 500)
    queue.clearFinished()
    XCTAssertEqual(queue.items.map(\.id), [item1.id])
    queue.finishTransfer(id: item1.id, result: .failure(SFTPError.cancelled))
    queue.updateProgress(id: item1.id, transferred: 1000, total: 1000)
    XCTAssertEqual(queue.items.first?.status, .cancelled)
    XCTAssertNotNil(queue.items.first?.finishedAt)
    XCTAssertFalse(queue.hasActiveTransfers)

    queue.clearFinished()
    XCTAssertTrue(queue.items.isEmpty)
  }

  @MainActor
  func testTransferQueueReportsActualOutcomeAfterCancellation() {
    let queue = SFTPTransferQueue()
    let success = SFTPTransferItem(kind: .upload, sourceDescription: "a", destinationDescription: "b",
      totalBytes: 10, transferredBytes: 0, status: .running(progress: 0))
    let failure = SFTPTransferItem(kind: .upload, sourceDescription: "c", destinationDescription: "d",
      totalBytes: 10, transferredBytes: 0, status: .running(progress: 0))
    queue.insertActiveItemForTesting(success)
    queue.insertActiveItemForTesting(failure)
    queue.cancelTransfer(id: success.id)
    queue.cancelTransfer(id: failure.id)
    queue.finishTransfer(id: success.id, result: .success(()))
    queue.finishTransfer(id: failure.id, result: .failure(SFTPError.remoteError("failed")))
    queue.updateProgress(id: success.id, transferred: 1, total: 10)
    XCTAssertEqual(queue.items.first(where: { $0.id == success.id })?.status, .completed)
    guard case .failed = queue.items.first(where: { $0.id == failure.id })?.status else {
      return XCTFail("Expected actual failure")
    }
  }

  @MainActor
  func testTransferProgressUsesKnownDownloadSizeAndKeepsUploadsIndeterminate() {
    let queue = SFTPTransferQueue()
    let upload = SFTPTransferItem(kind: .upload, sourceDescription: "a", destinationDescription: "b",
      totalBytes: 100, transferredBytes: 0, status: .running(progress: nil))
    let download = SFTPTransferItem(kind: .download, sourceDescription: "b", destinationDescription: "a",
      totalBytes: 100, transferredBytes: 0, status: .running(progress: nil))
    queue.insertActiveItemForTesting(upload)
    queue.insertActiveItemForTesting(download)
    queue.updateProgress(id: upload.id, transferred: 0, total: 0)
    queue.updateProgress(id: download.id, transferred: 30, total: 0)
    XCTAssertEqual(queue.items.first { $0.id == upload.id }?.status, .running(progress: nil))
    XCTAssertEqual(queue.items.first { $0.id == download.id }?.status, .running(progress: 0.3))
  }

  @MainActor
  func testQueuedTransferCanCancelAndClearImmediately() throws {
    let knownHosts = tempDir.appendingPathComponent("known_hosts")
    let agent = tempDir.appendingPathComponent("agent.sock")
    try Data().write(to: knownHosts)
    try Data().write(to: agent)
    let client = try NativeSFTPClient(configuration: NativeSSHConfiguration(
      host: "127.0.0.1", username: "user", knownHostsFileURL: knownHosts,
      authentication: .agent(socketURL: agent)))
    let queue = SFTPTransferQueue()
    let missing = tempDir.appendingPathComponent("missing")
    _ = queue.enqueueUpload(client: client, localURL: missing, remotePath: "/one", overwrite: false)
    _ = queue.enqueueUpload(client: client, localURL: missing, remotePath: "/two", overwrite: false)
    let pending = queue.enqueueUpload(client: client, localURL: missing, remotePath: "/three", overwrite: false)
    XCTAssertEqual(queue.items.first(where: { $0.id == pending })?.status, .queued)
    queue.cancelTransfer(id: pending)
    XCTAssertEqual(queue.items.first(where: { $0.id == pending })?.status, .cancelled)
    queue.clearFinished()
    XCTAssertFalse(queue.items.contains(where: { $0.id == pending }))
  }

  @MainActor
  func testPendingTransfersStartInFIFOOrder() async throws {
    let knownHosts = tempDir.appendingPathComponent("known_hosts")
    let agent = tempDir.appendingPathComponent("agent.sock")
    try Data().write(to: knownHosts)
    try Data().write(to: agent)
    let client = try NativeSFTPClient(configuration: NativeSSHConfiguration(
      host: "127.0.0.1", username: "user", knownHostsFileURL: knownHosts,
      authentication: .agent(socketURL: agent)))
    let queue = SFTPTransferQueue()
    var starts: [UUID] = []
    let subscription = queue.$items.sink { items in
      for item in items {
        if case .running = item.status, !starts.contains(item.id) { starts.append(item.id) }
      }
    }
    let ids = (0..<6).map { index in
      queue.enqueueUpload(client: client, localURL: tempDir.appendingPathComponent("missing"),
        remotePath: "/file\(index)", overwrite: false)
    }
    for _ in 0..<200 where queue.hasActiveTransfers {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    withExtendedLifetime(subscription) {}
    XCTAssertFalse(queue.hasActiveTransfers)
    XCTAssertEqual(starts, ids)
  }

  // MARK: - Live Fixture Integration Tests (FR-009, FR-010, TC-008, TC-010)

  func testSFTPClientRoundTripWithDisposableFixtureIfAvailable() throws {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["MRW_NATIVE_SSH_HOST"],
          let sshPort = env["MRW_NATIVE_SSH_PORT"].flatMap(Int.init),
          let username = env["MRW_NATIVE_SSH_USER"],
          let root = env["MRW_NATIVE_FIXTURE_ROOT"],
          let agentSock = env["MRW_NATIVE_AGENT_SOCK"] else {
      throw XCTSkip("MRW_NATIVE_SSH fixture environment not configured; skipping SFTP fixture test.")
    }

    let rootURL = URL(fileURLWithPath: root, isDirectory: true)
    let config = NativeSSHConfiguration(
      host: host,
      port: sshPort,
      username: username,
      knownHostsFileURL: rootURL.appendingPathComponent("known_hosts"),
      authentication: .agent(socketURL: URL(fileURLWithPath: agentSock))
    )

    let client = try NativeSFTPClient(configuration: config)

    let testDirName = "sftp-test-\(UUID().uuidString.prefix(8))"
    let remoteTestDir = "\(root)/\(testDirName)"

    // 1. Create remote directory
    try client.createDirectory(at: remoteTestDir)

    let spacedName = "  spaced name  "
    let spacedURL = URL(fileURLWithPath: remoteTestDir).appendingPathComponent(spacedName)
    try "spaced".write(to: spacedURL, atomically: true, encoding: .utf8)
    let spacedEntry = try XCTUnwrap(client.listDirectory(at: remoteTestDir).first { $0.name == spacedName })
    XCTAssertEqual(spacedEntry.path, spacedURL.path)
    try client.deleteFile(at: spacedEntry.path)

    // 2. List parent directory and verify new folder exists
    let parentEntries = try client.listDirectory(at: root)
    XCTAssertTrue(parentEntries.contains { $0.name == testDirName && $0.isDirectory })

    // 3. Upload a file
    let localFile = tempDir.appendingPathComponent("test-upload.txt")
    let payload = "SFTP safe upload payload - \(UUID().uuidString)"
    try payload.write(to: localFile, atomically: true, encoding: .utf8)

    let remoteFilePath = "\(remoteTestDir)/uploaded.txt"
    try client.uploadFile(from: localFile, to: remoteFilePath, overwrite: false)

    let racedPath = "\(remoteTestDir)/raced.txt"
    XCTAssertThrowsError(try client.uploadFile(from: localFile, to: racedPath, overwrite: false,
      onProgress: { transferred, _ in
        if transferred == 0 { try? "other writer".write(toFile: racedPath, atomically: true, encoding: .utf8) }
      }))
    XCTAssertEqual(try String(contentsOfFile: racedPath, encoding: .utf8), "other writer")
    try client.deleteFile(at: racedPath)

    // 4. List remote test directory
    let dirEntries = try client.listDirectory(at: remoteTestDir)
    XCTAssertEqual(dirEntries.count, 1)
    XCTAssertEqual(dirEntries.first?.name, "uploaded.txt")
    XCTAssertEqual(dirEntries.first?.size, Int64(payload.utf8.count))

    // 5. Download the file back
    let downloadDest = tempDir.appendingPathComponent("downloads", isDirectory: true)
    try FileManager.default.createDirectory(at: downloadDest, withIntermediateDirectories: true)
    let downloadedURL = try client.downloadFile(
      from: remoteFilePath,
      to: downloadDest,
      filename: "downloaded.txt",
      overwrite: false
    )

    let downloadedContent = try String(contentsOf: downloadedURL, encoding: .utf8)
    XCTAssertEqual(downloadedContent, payload)

    // Literal metacharacters must never select other remote files.
    let siblingRemote = "\(remoteTestDir)/abc"
    try payload.write(toFile: siblingRemote, atomically: true, encoding: .utf8)
    for (index, name) in ["a*", "a?", "a[b]", "a\\b"].enumerated() {
      let literalRemote = "\(remoteTestDir)/\(name)"
      try payload.write(toFile: literalRemote, atomically: true, encoding: .utf8)
      let downloaded = try client.downloadFile(from: literalRemote, to: downloadDest, filename: "literal-\(index)", overwrite: false)
      XCTAssertEqual(try String(contentsOf: downloaded, encoding: .utf8), payload)
      try client.deleteFile(at: literalRemote)
      XCTAssertTrue(FileManager.default.fileExists(atPath: siblingRemote))
    }
    try client.deleteFile(at: siblingRemote)

    let newlineURL = URL(fileURLWithPath: "\(remoteTestDir)/line\nbreak")
    try payload.write(to: newlineURL, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try client.listDirectory(at: remoteTestDir))
    try FileManager.default.removeItem(at: newlineURL)

    // 6. Delete file and directory
    try client.deleteFile(at: remoteFilePath)
    try client.deleteDirectory(at: remoteTestDir)

    let entriesAfterClean = try client.listDirectory(at: root)
    XCTAssertFalse(entriesAfterClean.contains { $0.name == testDirName })
  }

  // MARK: - Delete / Rename (FR-011 / US-013)

  func testDeleteAndRenameCommandBuildingQuotesPaths() {
    XCTAssertEqual(NativeSFTPClient.deleteFileCommand("/a b/\"x\".txt"), "rm \"/a b/\\\"x\\\".txt\"")
    XCTAssertEqual(NativeSFTPClient.deleteDirectoryCommand("/tmp/d"), "rmdir \"/tmp/d\"")
    XCTAssertEqual(NativeSFTPClient.renameCommand(from: "/a", to: "/b c"), "rename \"/a\" \"/b c\"")
  }

  func testRemoteErrorMapping() {
    XCTAssertEqual(NativeSFTPClient.mapRemoteError(stderr: "Couldn't remove: Permission denied", path: "/p", fallback: "f"), .permissionDenied("/p"))
    XCTAssertEqual(NativeSFTPClient.mapRemoteError(stderr: "Couldn't stat: No such file or directory", path: "/p", fallback: "f"), .fileNotFound("/p"))
    XCTAssertEqual(NativeSFTPClient.mapRemoteError(stderr: "  \n", path: "/p", fallback: "fallback"), .remoteError("fallback"))
    XCTAssertEqual(NativeSFTPClient.mapRemoteError(stderr: "Failure", path: "/p", fallback: "f"), .remoteError("Failure"))
  }

  func testRenameTargetValidation() throws {
    XCTAssertEqual(try NativeSFTPClient.renameTarget(for: "/home/u/old.txt", newName: " new.txt "), "/home/u/new.txt")
    XCTAssertEqual(try NativeSFTPClient.renameTarget(for: "/old", newName: "new"), "/new")
    for bad in ["", "  ", ".", "..", "a/b", "x\ny"] {
      XCTAssertThrowsError(try NativeSFTPClient.renameTarget(for: "/home/u/old", newName: bad), bad) { err in
        guard case SFTPError.invalidPath = err else { return XCTFail("Expected invalidPath, got \(err)") }
      }
    }
  }

  func testDeleteConfirmationMessageNamesExactTarget() {
    let dir = SFTPFileEntry(name: "d", path: "/srv/prod/d", isDirectory: true, isSymlink: false, size: 0, permissions: "drwxr-xr-x", modificationDateString: "", symlinkTarget: nil)
    let msg = NativeSFTPClient.deleteConfirmationMessage(for: dir)
    XCTAssertTrue(msg.contains("'/srv/prod/d'"))
    XCTAssertTrue(msg.contains("directory"))
  }

  func testDeleteRenameRejectInvalidPathsBeforeSpawning() throws {
    let client = try makeDummyClient()
    XCTAssertThrowsError(try client.deleteFile(at: "")) { XCTAssertEqual($0 as? SFTPError, .invalidPath("")) }
    XCTAssertThrowsError(try client.deleteDirectory(at: "/a\nb")) { guard case SFTPError.invalidPath = $0 else { return XCTFail() } }
    XCTAssertThrowsError(try client.rename(from: "/a", to: "")) { XCTAssertEqual($0 as? SFTPError, .invalidPath("")) }
    XCTAssertThrowsError(try client.deleteFile(at: "/x", isCancelled: { true })) { XCTAssertEqual($0 as? SFTPError, .cancelled) }
  }

  private func makeDummyClient() throws -> NativeSFTPClient {
    let knownHosts = tempDir.appendingPathComponent("known_hosts")
    try "".write(to: knownHosts, atomically: true, encoding: .utf8)
    let sock = tempDir.appendingPathComponent("agent.sock")
    FileManager.default.createFile(atPath: sock.path, contents: Data())
    return try NativeSFTPClient(configuration: NativeSSHConfiguration(
      host: "127.0.0.1", port: 22, username: "user", knownHostsFileURL: knownHosts,
      authentication: .agent(socketURL: sock)))
  }

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

  func testRenameDeleteLiveWithCollisionAndErrorMappingIfFixtureAvailable() throws {
    let (client, root) = try makeFixtureClient()
    let dir = "\(root)/fr011-\(UUID().uuidString.prefix(8))"
    try client.createDirectory(at: dir)

    for name in ["a.txt", "b.txt"] {
      let local = tempDir.appendingPathComponent(name)
      try name.write(to: local, atomically: true, encoding: .utf8)
      try client.uploadFile(from: local, to: "\(dir)/\(name)", overwrite: false)
    }

    // Collision: rename onto existing file is refused and both survive.
    XCTAssertThrowsError(try client.rename(from: "\(dir)/a.txt", to: "\(dir)/b.txt")) { err in
      XCTAssertEqual(err as? SFTPError, .collision("\(dir)/b.txt"))
    }
    XCTAssertEqual(try client.listDirectory(at: dir).map(\.name).sorted(), ["a.txt", "b.txt"])

    // Successful rename.
    try client.rename(from: "\(dir)/a.txt", to: "\(dir)/c.txt")
    XCTAssertEqual(try client.listDirectory(at: dir).map(\.name).sorted(), ["b.txt", "c.txt"])

    // Rename of a missing source maps to fileNotFound.
    XCTAssertThrowsError(try client.rename(from: "\(dir)/missing.txt", to: "\(dir)/z.txt")) { err in
      XCTAssertEqual(err as? SFTPError, .fileNotFound("\(dir)/missing.txt"))
    }

    // Delete: missing file maps to fileNotFound; non-empty dir refuses rmdir; then clean delete.
    XCTAssertThrowsError(try client.deleteFile(at: "\(dir)/missing.txt")) { err in
      XCTAssertEqual(err as? SFTPError, .fileNotFound("\(dir)/missing.txt"))
    }
    XCTAssertThrowsError(try client.deleteDirectory(at: dir))
    XCTAssertEqual(try client.listDirectory(at: dir).count, 2)

    try client.deleteFile(at: "\(dir)/b.txt")
    try client.deleteFile(at: "\(dir)/c.txt")
    try client.deleteDirectory(at: dir)
    XCTAssertFalse(try client.listDirectory(at: root).contains { $0.name == (dir as NSString).lastPathComponent })
  }

  // MARK: - App quit with running transfers (FR-028 / TC-016)

  @MainActor
  func testCancelAllAndWaitDrainsQueueAndNeverReportsSuccess() async throws {
    let client = try makeDummyClient()
    let queue = SFTPTransferQueue()
    for i in 0..<4 {  // more than maxConcurrency so some stay queued
      _ = queue.enqueueDownload(client: client, remotePath: "/r\(i)", localDirectoryURL: tempDir, filename: "f\(i)", overwrite: false)
    }
    await queue.cancelAllAndWait(timeoutSeconds: 20)
    XCTAssertFalse(queue.hasActiveTransfers)
    XCTAssertTrue(queue.items.allSatisfy { if case .completed = $0.status { return false }; return true })
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: tempDir.path).filter { $0.contains(".mrw-part-") }
    XCTAssertTrue(leftovers.isEmpty)
  }

  @MainActor
  func testQuitCancelsLiveUploadAndLeavesNoPartFileIfFixtureAvailable() async throws {
    let (client, root) = try makeFixtureClient()
    let big = tempDir.appendingPathComponent("big.bin")
    FileManager.default.createFile(atPath: big.path, contents: nil)
    let handle = try FileHandle(forWritingTo: big)
    try handle.truncate(atOffset: 4 * 1024 * 1024 * 1024)  // sparse 4 GiB so loopback cannot finish before cancel
    try handle.close()
    let dir = "\(root)/tc016-\(UUID().uuidString.prefix(8))"
    try client.createDirectory(at: dir)
    defer { try? client.deleteDirectory(at: dir) }

    let queue = SFTPTransferQueue()
    let id = queue.enqueueUpload(client: client, localURL: big, remotePath: "\(dir)/big.bin", overwrite: false)
    try await Task.sleep(nanoseconds: 700_000_000)
    await queue.cancelAllAndWait(timeoutSeconds: 30)

    XCTAssertEqual(queue.items.first { $0.id == id }?.status, .cancelled)
    XCTAssertFalse(queue.hasActiveTransfers)
    XCTAssertEqual(try client.listDirectory(at: dir).map(\.name), [], "no target or .mrw-part file may remain")
  }

  // MARK: - Keychain Askpass Configuration Validation

  func testSFTPClientAcceptsKeychainAskpassConfiguration() throws {
    let dummyKnownHosts = tempDir.appendingPathComponent("known_hosts")
    FileManager.default.createFile(atPath: dummyKnownHosts.path, contents: nil)

    let config = NativeSSHConfiguration(
      host: "example.com",
      port: 22,
      username: "deploy",
      knownHostsFileURL: dummyKnownHosts,
      authentication: .keychainAskpass(service: "com.macremoteworkspace.credentials", account: "test-acc", identityFile: nil)
    )

    XCTAssertNoThrow(try NativeSFTPClient(configuration: config))
  }

  func testSFTPClientRejectsInvalidConfigurationWithEmptyUsername() throws {
    let dummyKnownHosts = tempDir.appendingPathComponent("known_hosts")
    FileManager.default.createFile(atPath: dummyKnownHosts.path, contents: nil)

    let config = NativeSSHConfiguration(
      host: "example.com",
      port: 22,
      username: "",
      knownHostsFileURL: dummyKnownHosts,
      authentication: .keychainAskpass(service: "com.macremoteworkspace.credentials", account: "test-acc", identityFile: nil)
    )

    XCTAssertThrowsError(try NativeSFTPClient(configuration: config))
  }
}
