import XCTest
import CFreeRDP
@testable import AppCore

final class RdpConnectionOptionsTests: XCTestCase {
  func testDefaultsAndRetinaPolicy() throws {
    let options = RdpConnectionOptions()
    XCTAssertEqual(options.displayMode, .window)
    XCTAssertTrue(options.retina)
    XCTAssertEqual(options.networkProfile, .automatic)
    XCTAssertEqual(options.resolution(pointWidth: 900, pointHeight: 600, backingScaleFactor: 2),
      .init(width: 1800, height: 1200, scaleFactor: 200))
    XCTAssertEqual(RdpConnectionOptions(retina: false).resolution(pointWidth: 900, pointHeight: 600, backingScaleFactor: 2),
      .init(width: 900, height: 600))
    XCTAssertEqual(try JSONDecoder().decode(RdpConnectionOptions.self, from: JSONEncoder().encode(options)), options)
    XCTAssertThrowsError(try JSONDecoder().decode(RdpConnectionOptions.self,
      from: Data(#"{"displayMode":"invalid","retina":true,"networkProfile":"automatic"}"#.utf8)))
  }

  func testLegacyBackingScaleThresholdsAndInvalidDimensionsStayBounded() {
    for (backing, multiplier, scale) in [(1.0, 1.0, UInt32(100)), (1.49, 1, 100), (1.5, 2, 200), (1.75, 2, 200), (3, 2, 200)] {
      XCTAssertEqual(RdpConnectionOptions().resolution(pointWidth: 800, pointHeight: 600, backingScaleFactor: backing),
        .init(width: UInt32(800 * multiplier), height: UInt32(600 * multiplier), scaleFactor: scale))
    }
    XCTAssertEqual(RdpDisplayResolution.from(pointWidth: .nan, pointHeight: .infinity, backingScaleFactor: 2),
      .init(width: 200, height: 200, scaleFactor: 200))
    XCTAssertEqual(RdpDisplayResolution.from(pointWidth: 1e30, pointHeight: -100, backingScaleFactor: 2),
      .init(width: 8192, height: 200, scaleFactor: 200))
  }

  func testFixedPolicyOverridesInitialAndEveryResize() {
    for mode in RdpConnectionOptions.DisplayMode.allCases where mode != .window {
      let options = RdpConnectionOptions(displayMode: mode)
      let expected = mode.fixedResolution!
      XCTAssertEqual(options.initialResolution(.init(width: 800, height: 600)), expected)
      XCTAssertEqual(options.resolution(pointWidth: 500, pointHeight: 300, backingScaleFactor: 1), expected)
      XCTAssertEqual(options.resolution(pointWidth: 3000, pointHeight: 2000, backingScaleFactor: 2), expected)
      XCTAssertEqual(expected.scaleFactor, 100)
      let config = RdpSessionConfiguration(host: "fixture.invalid", username: "u", credentialRefID: nil, options: options)
      XCTAssertEqual(config.initialResolution, expected)
      XCTAssertEqual(config.options, options)
    }
    let custom = RdpDisplayResolution(width: 1000, height: 700, scaleFactor: 200)
    XCTAssertEqual(RdpSessionConfiguration(host: "fixture.invalid", username: "u", credentialRefID: nil,
      initialResolution: custom).initialResolution, custom)
  }

  func testNetworkPresetsChangeRealSettingsAndAutomaticLeavesDefaults() throws {
    let settings = try XCTUnwrap(freerdp_settings_new(0))
    defer { freerdp_settings_free(settings) }
    let boolKeys = [FreeRDP_NetworkAutoDetect, FreeRDP_DisableWallpaper, FreeRDP_DisableFullWindowDrag,
      FreeRDP_DisableMenuAnims, FreeRDP_DisableThemes, FreeRDP_AllowFontSmoothing, FreeRDP_AllowDesktopComposition,
      FreeRDP_NlaSecurity, FreeRDP_IgnoreCertificate, FreeRDP_AutoAcceptCertificate]
    let before = boolKeys.map { freerdp_settings_get_bool(settings, $0) }
    let connection = freerdp_settings_get_uint32(settings, FreeRDP_ConnectionType)
    let flags = freerdp_settings_get_uint32(settings, FreeRDP_PerformanceFlags)
    XCTAssertTrue(FreeRdpClient.configureNetwork(settings, profile: .automatic))
    XCTAssertEqual(boolKeys.map { freerdp_settings_get_bool(settings, $0) }, before)
    XCTAssertEqual(freerdp_settings_get_uint32(settings, FreeRDP_ConnectionType), connection)
    XCTAssertEqual(freerdp_settings_get_uint32(settings, FreeRDP_PerformanceFlags), flags)
    for profile in [RdpConnectionOptions.NetworkProfile.reducedBandwidth, .lan] {
      XCTAssertTrue(FreeRdpClient.configureNetwork(settings, profile: profile))
      XCTAssertEqual(freerdp_settings_get_uint32(settings, FreeRDP_ConnectionType),
        UInt32(profile == .lan ? CONNECTION_TYPE_LAN : CONNECTION_TYPE_BROADBAND_LOW))
      XCTAssertFalse(freerdp_settings_get_bool(settings, FreeRDP_NetworkAutoDetect))
      let performance = freerdp_settings_get_uint32(settings, FreeRDP_PerformanceFlags)
      XCTAssertEqual(performance & UInt32(PERF_DISABLE_WALLPAPER), profile == .lan ? 0 : UInt32(PERF_DISABLE_WALLPAPER))
      XCTAssertEqual(performance & UInt32(PERF_ENABLE_FONT_SMOOTHING), profile == .lan ? UInt32(PERF_ENABLE_FONT_SMOOTHING) : 0)
      for key in [FreeRDP_NlaSecurity, FreeRDP_IgnoreCertificate, FreeRDP_AutoAcceptCertificate] {
        XCTAssertEqual(freerdp_settings_get_bool(settings, key), before[boolKeys.firstIndex(of: key)!])
      }
    }
  }
}
