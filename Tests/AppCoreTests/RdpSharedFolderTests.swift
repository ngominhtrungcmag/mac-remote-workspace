import CFreeRDP
import Foundation
import XCTest

@testable import AppCore

final class RdpSharedFolderTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    // realpath so expectations match the canonical form (/var -> /private/var).
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
    root = URL(fileURLWithPath: String(cString: try XCTUnwrap(realpath(tmp, nil))))
      .appendingPathComponent("rdp-shared-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  // MARK: validate

  func testValidateAcceptsExistingDirectory() throws {
    XCTAssertEqual(try RdpSharedFolder.validate(root.path).path, root.path)
    XCTAssertEqual(try RdpSharedFolder.validate(root.path + "/./").path, root.path)
  }

  func testValidateRejectsNonexistentFileRootRelativeAndControlCharacters() throws {
    let file = root.appendingPathComponent("file.txt")
    try Data("x".utf8).write(to: file)
    let cases: [(String, RdpSharedFolder.ValidationError)] = [
      (root.appendingPathComponent("missing").path, .notADirectory),
      (file.path, .notADirectory),
      ("/", .rootDirectory),
      (root.path + "/..//../../../../../../..", .rootDirectory),
      ("", .invalidPath),
      ("relative/dir", .invalidPath),
      (root.path + "/a\nb", .invalidPath),
    ]
    for (path, expected) in cases {
      XCTAssertThrowsError(try RdpSharedFolder.validate(path), path) {
        XCTAssertEqual($0 as? RdpSharedFolder.ValidationError, expected, path)
      }
    }
  }

  func testValidateResolvesSymlinkToDirectory() throws {
    let target = root.appendingPathComponent("target", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    XCTAssertEqual(try RdpSharedFolder.validate(link.path).path, target.path)

    let rootLink = root.appendingPathComponent("rootlink")
    try FileManager.default.createSymbolicLink(atPath: rootLink.path, withDestinationPath: "/")
    XCTAssertThrowsError(try RdpSharedFolder.validate(rootLink.path)) {
      XCTAssertEqual($0 as? RdpSharedFolder.ValidationError, .rootDirectory)
    }
  }

  func testDriveNameSanitization() {
    let cases: [(String, String)] = [
      ("Projects", "Projects"),
      ("My Folder (2)", "My Folder 2"),
      ("Tài liệu", "Tai lieu"),
      ("a\\b:c*d?e\"f<g>h|i", "abcdefghi"),
      ("under_score-dash", "under_score-dash"),
      ("文件", "Mac"),
      ("...", "Mac"),
      ("  spaced  ", "spaced"),
      (String(repeating: "x", count: 40), String(repeating: "x", count: 32)),
    ]
    for (component, expected) in cases {
      let url = URL(fileURLWithPath: "/Users/u").appendingPathComponent(component, isDirectory: true)
      XCTAssertEqual(RdpSharedFolder.driveName(for: url), expected, component)
    }
  }

  // MARK: FreeRDP settings

  func testWithoutFolderAllDeviceRedirectionStaysOff() throws {
    let settings = try XCTUnwrap(freerdp_settings_new(0))
    defer { freerdp_settings_free(settings) }
    XCTAssertTrue(FreeRdpClient.configureDeviceRedirection(settings, sharedFolder: nil))
    for key in Self.redirectionKeys + [FreeRDP_DeviceRedirection, FreeRDP_RedirectDrives] {
      XCTAssertFalse(freerdp_settings_get_bool(settings, key), "\(key)")
    }
    XCTAssertEqual(freerdp_settings_get_uint32(settings, FreeRDP_DeviceCount), 0)
    XCTAssertEqual(try loadedChannelNames(sharedFolder: nil), ["drdynvc", "cliprdr"])
  }

  func testWithFolderRedirectsExactlyOneDrive() throws {
    let folder = root.appendingPathComponent("Shared Ü", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let settings = try XCTUnwrap(freerdp_settings_new(0))
    defer { freerdp_settings_free(settings) }
    XCTAssertTrue(FreeRdpClient.configureDeviceRedirection(settings, sharedFolder: folder))
    XCTAssertTrue(freerdp_settings_get_bool(settings, FreeRDP_DeviceRedirection))
    XCTAssertTrue(freerdp_settings_get_bool(settings, FreeRDP_RedirectDrives))
    for key in Self.redirectionKeys {
      XCTAssertFalse(freerdp_settings_get_bool(settings, key), "\(key)")
    }
    XCTAssertEqual(freerdp_settings_get_uint32(settings, FreeRDP_DeviceCount), 1)
    let device = try XCTUnwrap(freerdp_settings_get_pointer_array(settings, FreeRDP_DeviceArray, 0))
    let drive = device.assumingMemoryBound(to: RDPDR_DRIVE.self).pointee
    XCTAssertEqual(drive.device.Type, RDPDR_DTYP_FILESYSTEM.rawValue)
    XCTAssertEqual(String(cString: try XCTUnwrap(drive.device.Name)), "Shared U")
    XCTAssertEqual(String(cString: try XCTUnwrap(drive.Path)), folder.path)
    XCTAssertEqual(try loadedChannelNames(sharedFolder: folder), ["drdynvc", "cliprdr", "rdpdr"])
  }

  /// Runs the real LoadChannels callback on a fresh context and returns the registered channel names.
  private func loadedChannelNames(sharedFolder: URL?) throws -> [String] {
    let instance = try XCTUnwrap(freerdp_new())
    XCTAssertTrue(freerdp_context_new(instance))
    defer { freerdp_context_free(instance); freerdp_free(instance) }
    let settings = try XCTUnwrap(instance.pointee.context?.pointee.settings)
    XCTAssertTrue(FreeRdpClient.configureDeviceRedirection(settings, sharedFolder: sharedFolder))
    FreeRdpClient.installChannelLoader(on: instance)
    XCTAssertTrue(try XCTUnwrap(instance.pointee.LoadChannels)(instance).boolValue)
    let count = freerdp_settings_get_uint32(settings, FreeRDP_ChannelCount)
    return (0..<count).compactMap { index in
      freerdp_settings_get_pointer_array(settings, FreeRDP_ChannelDefArray, Int(index))
        .map { $0.assumingMemoryBound(to: CHANNEL_DEF.self) }
        .map { def in withUnsafeBytes(of: def.pointee.name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) } }
    }
  }

  private static let redirectionKeys = [
    FreeRDP_AudioPlayback, FreeRDP_AudioCapture, FreeRDP_RedirectHomeDrive, FreeRDP_RedirectPrinters,
    FreeRDP_RedirectSmartCards, FreeRDP_RedirectSerialPorts, FreeRDP_RedirectParallelPorts,
  ]

  // MARK: Plumbing

  func testStartMessageRoundTripsWithAndWithoutSharedFolder() throws {
    let messages: [RdpHelperMessage] = [
      .start(host: "h", port: 3389, width: 800, height: 600, scaleFactor: 100),
      .start(host: "h", port: 3389, width: 800, height: 600, scaleFactor: 100,
        clipboardDirectory: "/tmp/c", sharedFolder: "/Users/u/Shared"),
    ]
    for message in messages {
      let wire = try message.encoded()
      XCTAssertEqual(try RdpHelperMessage.decode(body: wire.dropFirst(4)), message)
    }
    // A sender that predates sharedFolder still decodes, with no folder.
    let legacy = Data([0]) + Data(#"{"start":{"host":"h","port":3389,"width":8,"height":6,"scaleFactor":100}}"#.utf8)
    XCTAssertEqual(
      try RdpHelperMessage.decode(body: legacy),
      .start(host: "h", port: 3389, width: 8, height: 6, scaleFactor: 100, clipboardDirectory: nil, sharedFolder: nil))
  }

  func testSessionRejectsInvalidSharedFolderBeforeLaunchingHelper() async throws {
    let session = NativeRdpSession(
      configuration: RdpSessionConfiguration(
        host: "192.0.2.1", username: "u", credentialRefID: nil, sharedFolderPath: "/"),
      certificateVerifier: UnusedCertificateVerifier(),
      credentialResolver: UnusedCredentialResolver())
    do {
      try await session.connect()
      XCTFail("connect should fail")
    } catch {
      guard case .invalidEndpoint = error as? RdpSessionError else { return XCTFail("\(error)") }
    }
  }
}
