import XCTest
@testable import AppCore

final class RdpLauncherTests: XCTestCase {
  func testValidIpv4Endpoint() throws {
    let url = try RdpLauncher.makeRdpURI(endpoint: "127.0.0.1:3389")
    XCTAssertEqual(url.absoluteString, "rdp://full%20address=s%3A127.0.0.1%3A3389")
  }

  func testValidHostnameEndpoint() throws {
    let url = try RdpLauncher.makeRdpURI(endpoint: "win-server.corp.local:3389")
    XCTAssertEqual(url.absoluteString, "rdp://full%20address=s%3Awin-server.corp.local%3A3389")
  }

  func testValidLocalhostAndFQDNAndHyphenEndpoints() throws {
    let localhostUrl = try RdpLauncher.makeRdpURI(endpoint: "localhost:3389")
    XCTAssertEqual(localhostUrl.absoluteString, "rdp://full%20address=s%3Alocalhost%3A3389")

    let fqdnUrl = try RdpLauncher.makeRdpURI(endpoint: "desktop-01.eastus.cloudapp.azure.com:3389")
    XCTAssertEqual(fqdnUrl.absoluteString, "rdp://full%20address=s%3Adesktop-01.eastus.cloudapp.azure.com%3A3389")

    let hyphenUrl = try RdpLauncher.makeRdpURI(endpoint: "my-rdp-host:3389")
    XCTAssertEqual(hyphenUrl.absoluteString, "rdp://full%20address=s%3Amy-rdp-host%3A3389")
  }

  func testValidIpv6EndpointWithBrackets() throws {
    let url = try RdpLauncher.makeRdpURI(endpoint: "[::1]:3389")
    XCTAssertEqual(url.absoluteString, "rdp://full%20address=s%3A%5B%3A%3A1%5D%3A3389")
  }

  func testFormatEndpointHelper() throws {
    let ep1 = try RdpLauncher.formatEndpoint(address: "192.168.1.100")
    XCTAssertEqual(ep1, "192.168.1.100:3389")

    let ep2 = try RdpLauncher.formatEndpoint(address: "2001:db8::1", port: 3390)
    XCTAssertEqual(ep2, "[2001:db8::1]:3390")

    let ep3 = try RdpLauncher.formatEndpoint(address: "[fe80::1]", port: 3389)
    XCTAssertEqual(ep3, "[fe80::1]:3389")
  }

  func testRejectsMaliciousOrInvalidEndpoints() {
    let invalidEndpoints = [
      "host:0",
      "host:65536",
      "host:3389&password=s:secret",
      "host:3389/evil",
      "host\n:3389",
      "host:3389?username=admin",
      "host#frag:3389",
      "-bad:3389",
      ".bad:3389",
      "bad.:3389",
      " [::1]:3389",
      "[::1] :3389",
      "invalid ipv6:::3389",
      "[invalid:ipv6:here]:3389",
      "hostname_with_disallowed!char:3389",
      "host:notaport",
      "host",
      "",
      "999.999.999.999:extra:colons:3389",
      "host:3389\u{0000}",
      "host;rm -rf /:3389",
      "host`id`:3389",
      "host$(whoami):3389",
      "host|whoami:3389",
    ]

    for endpoint in invalidEndpoints {
      XCTAssertThrowsError(try RdpLauncher.makeRdpURI(endpoint: endpoint), "Accepted invalid endpoint: \(endpoint)")
    }
  }

  func testRejectsInvalidAddressesDirectly() {
    let invalidAddresses = [
      "",
      "  ",
      "-leading-dash",
      ".leading-dot",
      "trailing-dot.",
      "has space",
      "user:pass@host",
      "host/path",
      "host?query",
      "host#hash",
      "::invalid::ipv6",
      "999.999.999.999:extra:colons",
      "[::1]:extra",
      "127.0.0.1:80",
      "hostname:with:colon",
      "host;id",
      "host`id`",
      "host$(id)",
      "host|id",
      String(repeating: "a", count: 254),
      "a..b",
      "a.-b",
      "a-.b",
      "my_host",
      "999.999.999.999",
      "256.1.1.1",
      "1.2.3.4.5",
      String(repeating: "a", count: 64) + ".com",
    ]

    for addr in invalidAddresses {
      XCTAssertThrowsError(try RdpLauncher.validateAddress(addr), "Accepted invalid address: \(addr)")
    }
  }

  func testClientDetectionLogicWithFixtures() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: tempDir)
    }

    // When no client is present in search roots
    let emptyLauncher = RdpLauncher(searchRoots: [tempDir])
    XCTAssertFalse(emptyLauncher.isClientAvailable())

    // Create a mock "Windows App.app" with matching Info.plist
    let appBundle = tempDir.appendingPathComponent("Windows App.app/Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: appBundle, withIntermediateDirectories: true)
    let infoPlistURL = appBundle.appendingPathComponent("Info.plist")
    let plistData: [String: Any] = [
      "CFBundleIdentifier": RdpLauncher.bundleID,
      "CFBundleName": "Windows App"
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plistData, format: .xml, options: 0)
    try data.write(to: infoPlistURL)

    let foundLauncher = RdpLauncher(searchRoots: [tempDir])
    XCTAssertTrue(foundLauncher.isClientAvailable())

    // When bundle ID does not match
    let mismatchedPlistData: [String: Any] = [
      "CFBundleIdentifier": "com.other.app",
      "CFBundleName": "Other App"
    ]
    let mismatchedData = try PropertyListSerialization.data(fromPropertyList: mismatchedPlistData, format: .xml, options: 0)
    try mismatchedData.write(to: infoPlistURL)

    let mismatchedLauncher = RdpLauncher(searchRoots: [tempDir])
    XCTAssertFalse(mismatchedLauncher.isClientAvailable())
  }

  func testLaunchThrowsClientNotFoundWhenUnavailable() async {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let launcher = RdpLauncher(searchRoots: [tempDir])

    do {
      try await launcher.launch(endpoint: "127.0.0.1:3389")
      XCTFail("Expected launch to throw clientNotFound")
    } catch let error as RdpLauncherError {
      XCTAssertEqual(error, .clientNotFound)
    } catch {
      XCTFail("Unexpected error type: \(error)")
    }
  }

  func testLaunchValidatesEndpointBeforeCheckingClient() async {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let launcher = RdpLauncher(searchRoots: [tempDir])

    do {
      try await launcher.launch(endpoint: "invalid-endpoint-no-port")
      XCTFail("Expected launch to throw invalidEndpoint")
    } catch let error as RdpLauncherError {
      guard case .invalidEndpoint = error else {
        XCTFail("Expected .invalidEndpoint, got \(error)")
        return
      }
    } catch {
      XCTFail("Unexpected error type: \(error)")
    }
  }
}
