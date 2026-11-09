import AppKit
import SwiftUI
import XCTest
import AppCore
@testable import MacRemoteWorkspace

final class RdpConnectionPreferencesTests: XCTestCase {
  private func preferences() -> RdpConnectionPreferences {
    let name = "RdpConnectionPreferencesTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
    return RdpConnectionPreferences(defaults: defaults)
  }

  func testInheritanceOverridesResetAndDraftDoesNotPersist() throws {
    let preferences = preferences()
    let global = RdpConnectionOptions(displayMode: .qhd, networkProfile: .lan)
    XCTAssertEqual(preferences.globalOptions, RdpConnectionOptions())
    XCTAssertNil(preferences.override(hostID: "host-a"))
    try preferences.saveGlobal(global)
    XCTAssertEqual(preferences.resolved(hostID: "host-a"), global)
    var draft = preferences.resolved(hostID: "host-a")
    draft.displayMode = .hd720
    draft.retina = false
    XCTAssertEqual(preferences.resolved(hostID: "host-a"), global, "Editing/cancelling a value draft cannot save it")
    try preferences.saveOverride(draft, hostID: "host-a")
    XCTAssertEqual(preferences.resolved(hostID: "host-a"), draft)
    XCTAssertEqual(preferences.resolved(hostID: "host-b"), global)
    try preferences.saveGlobal(RdpConnectionOptions())
    XCTAssertEqual(preferences.resolved(hostID: "host-a"), draft)
    try preferences.saveOverride(nil, hostID: "host-a")
    XCTAssertNil(preferences.defaults.object(forKey: RdpConnectionPreferences.hostKey("host-a")))
    XCTAssertEqual(preferences.resolved(hostID: "host-a"), RdpConnectionOptions())
  }

  func testCorruptOrInvalidPreferencesFallBackWithoutStoringConnectionIdentity() throws {
    let preferences = preferences()
    for bad: Any in ["invalid", Data([0xff]), Data(#"{"displayMode":"future","retina":true,"networkProfile":"automatic"}"#.utf8),
      Data(#"{"displayMode":"window","retina":"yes","networkProfile":"automatic"}"#.utf8)] {
      preferences.defaults.set(bad, forKey: RdpConnectionPreferences.globalKey)
      preferences.defaults.set(bad, forKey: RdpConnectionPreferences.hostKey("opaque-id"))
      XCTAssertEqual(preferences.globalOptions, RdpConnectionOptions())
      XCTAssertNil(preferences.override(hostID: "opaque-id"))
      XCTAssertEqual(preferences.resolved(hostID: "opaque-id"), RdpConnectionOptions())
    }
    let global = RdpConnectionOptions(displayMode: .fullHD)
    try preferences.saveGlobal(global)
    XCTAssertEqual(preferences.resolved(hostID: "opaque-id"), global)
    let stored = try XCTUnwrap(preferences.defaults.data(forKey: RdpConnectionPreferences.globalKey))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any])
    XCTAssertEqual(Set(json.keys), ["displayMode", "retina", "networkProfile"])
  }

  @MainActor
  func testReconnectKeepsCapturedOptionsWhenDefaultsChange() throws {
    let preferences = preferences()
    let snapshot = RdpConnectionOptions(displayMode: .hd720, retina: false, networkProfile: .reducedBandwidth)
    try preferences.saveOverride(snapshot, hostID: "fixture")
    let resolved = preferences.resolved(hostID: "fixture")
    let makeSession = {
      NativeRdpSession(configuration: .init(host: "fixture.invalid", username: "fixture", credentialRefID: nil, options: resolved),
        certificateVerifier: NativeRdpCertificateTrustService(repository: InMemoryRdpHostTrustRepository()),
        credentialResolver: RdpCredentialResolver(credentialLookup: { _ in nil }))
    }
    let registry = RdpSessionWindowRegistry()
    let host = PreviewFixtures.host
    registry.open(windowID: "fixture", host: host, makeSession: makeSession)
    let original = try XCTUnwrap(registry.entry(for: "fixture"))
    try preferences.saveOverride(nil, hostID: "fixture")
    try preferences.saveGlobal(.init(displayMode: .uhd4K, networkProfile: .lan))
    registry.reconnect(windowID: "fixture")
    let reconnected = try XCTUnwrap(registry.entry(for: "fixture"))
    XCTAssertNotEqual(original.session.id, reconnected.session.id)
    XCTAssertEqual(reconnected.session.configuration.options, snapshot)
    XCTAssertEqual(reconnected.session.configuration.initialResolution, .init(width: 1280, height: 720))
    registry.close(windowID: "fixture", sessionID: reconnected.session.id)
  }

  @MainActor
  func testNativeViewResizeUsesFixedPixelsAndRetinaPolicy() async throws {
    for options in [RdpConnectionOptions(), .init(retina: false), .init(displayMode: .fullHD)] {
      let view = RdpMetalHostingView(renderer: RdpMetalRenderer(), options: options)
      var resolutions: [RdpDisplayResolution] = []
      view.onResize = { resolutions.append($0) }
      view.setFrameSize(NSSize(width: 900, height: 600))
      try await Task.sleep(for: .milliseconds(250))
      XCTAssertEqual(resolutions.last, options.resolution(pointWidth: 900, pointHeight: 600, backingScaleFactor: 2))
      view.setFrameSize(NSSize(width: 2000, height: 1500))
      try await Task.sleep(for: .milliseconds(250))
      XCTAssertEqual(resolutions.last, options.resolution(pointWidth: 2000, pointHeight: 1500, backingScaleFactor: 2))
      if options.displayMode != .window { XCTAssertEqual(resolutions.count, 1, "Fixed size stays unchanged across window/fullscreen sizing") }
    }
  }

  @MainActor
  func testNativeOptionsScreenshotsWhenRequested() throws {
    guard let directory = ProcessInfo.processInfo.environment["RDP_OPTIONS_SCREENSHOTS"] else { return }
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let global = Form {
      Section("Remote Desktop — Settings > Connections") {
        RdpConnectionOptionsView(options: .constant(RdpConnectionOptions()))
      }
    }.formStyle(.grouped).frame(width: 620, height: 420)
    let host = Form {
      Section("Remote Desktop (RDP) — Host Settings") {
        Toggle("Use default settings", isOn: .constant(false))
        RdpConnectionOptionsView(options: .constant(.init(displayMode: .fullHD, networkProfile: .reducedBandwidth)))
      }
    }.formStyle(.grouped).frame(width: 620, height: 460)
    try render(global, path: directory + "/settings.png")
    try render(host, path: directory + "/host-options.png")
  }

  @MainActor
  private func render(_ content: some View, path: String) throws {
    let view = NSHostingView(rootView: content)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = view
    view.frame = NSRect(origin: .zero, size: view.fittingSize)
    view.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: path))
    window.orderOut(nil)
  }
}
