import XCTest
@testable import AppCore

final class RdpClipboardFilesTests: XCTestCase {
  func testDescriptorRoundTripWithUnicodeAndFolders() throws {
    let entries = [RdpClipboardFile(name: "Tài liệu", size: 0, isDirectory: true),
                   RdpClipboardFile(name: "Tài liệu\\hello.txt", size: 123, isDirectory: false)]
    let data = try RdpClipboardFiles.encode(entries)
    XCTAssertEqual(data.count, 4 + 2 * 592)
    XCTAssertEqual(try RdpClipboardFiles.decode(data), entries)
    XCTAssertEqual(Array(data[4..<8]), [4, 0, 0, 128])
  }

  func testRejectsTraversalAbsolutePathsAndCollisions() {
    for name in ["../secret", "a\\..\\secret", "/etc/passwd", "C:\\secret", "a//b", "a\u{0}b", "a.", "CON", "a\\NUL.txt"] {
      XCTAssertThrowsError(try RdpClipboardFiles.encode([.init(name: name, size: 0, isDirectory: false)]), name)
    }
    XCTAssertThrowsError(try RdpClipboardFiles.encode([
      .init(name: "A.txt", size: 0, isDirectory: false), .init(name: "a.txt", size: 0, isDirectory: false)]))
    XCTAssertThrowsError(try RdpClipboardFiles.encode([
      .init(name: "a", size: 0, isDirectory: false), .init(name: "a\\b", size: 0, isDirectory: false)]))
  }

  func testRejectsMalformedAndOversizedDescriptors() throws {
    XCTAssertThrowsError(try RdpClipboardFiles.decode(Data([255, 255, 255, 255])))
    var valid = try RdpClipboardFiles.encode([.init(name: "x", size: 1, isDirectory: false)])
    XCTAssertThrowsError(try RdpClipboardFiles.decode(valid.dropLast()))
    valid[4] = 4 // missing FD_FILESIZE
    XCTAssertThrowsError(try RdpClipboardFiles.decode(valid))
    XCTAssertThrowsError(try RdpClipboardFiles.encode([.init(name: "x", size: RdpClipboardFiles.maxTotalBytes + 1, isDirectory: false)]))
  }

  func testSourceOnlyServesSelectedRegularFilesAndBoundedRanges() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sample.txt")
    try Data("hello".utf8).write(to: file)
    let source = try RdpClipboardFileSource(urls: [file])
    XCTAssertEqual(try source.read(index: 0, offset: 1, count: 3), Data("ell".utf8))
    XCTAssertThrowsError(try source.read(index: 1, offset: 0, count: 1))
    XCTAssertThrowsError(try source.read(index: 0, offset: 6, count: 1))
    XCTAssertThrowsError(try source.read(index: 0, offset: 0, count: RdpClipboardFiles.chunkBytes + 1))
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    XCTAssertThrowsError(try RdpClipboardFileSource(urls: [link]))
  }

  func testSourceRecursesDirectoriesAndRejectsChangedContentsAndNestedLinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("nested/data")
    try Data([1, 2, 3]).write(to: file)
    let source = try RdpClipboardFileSource(urls: [root])
    XCTAssertEqual(source.entries.count, 3)
    XCTAssertEqual(try source.read(index: 2, offset: 0, count: 3), Data([1, 2, 3]))
    try FileHandle(forWritingTo: file).truncate(atOffset: 1)
    XCTAssertThrowsError(try source.read(index: 2, offset: 0, count: 3))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("nested/link"), withDestinationURL: file)
    XCTAssertThrowsError(try RdpClipboardFileSource(urls: [root]))
  }

  func testStagingPublishesOnlyCompleteFilesAndCleansOnCancel() throws {
    let entries = [RdpClipboardFile(name: "dir", size: 0, isDirectory: true),
                   RdpClipboardFile(name: "dir\\x", size: 3, isDirectory: false)]
    let staging = try RdpClipboardFileReceiver(entries: entries)
    let root = staging.root
    XCTAssertNil(staging.completedURLs)
    XCTAssertThrowsError(try staging.append(Data([1, 2, 3, 4])))
    try staging.append(Data([1, 2]))
    XCTAssertNil(staging.completedURLs)
    try staging.append(Data([3]))
    let urls = try XCTUnwrap(staging.completedURLs)
    XCTAssertEqual(urls.map(\.lastPathComponent), ["dir"])
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("dir/x")), Data([1, 2, 3]))
    staging.cancel()
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }
}
