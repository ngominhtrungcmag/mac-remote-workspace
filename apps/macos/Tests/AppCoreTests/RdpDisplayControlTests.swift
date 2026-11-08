import Foundation
import XCTest

@testable import AppCore

final class RdpDisplayControlTests: XCTestCase {
  func testClampingAndEvenDimensionEnforcement() {
    // Clamping minimum
    let tooSmall = RdpDisplayResolution(width: 50, height: 100)
    XCTAssertEqual(tooSmall.width, RdpDisplayResolution.minimumDimension)
    XCTAssertEqual(tooSmall.height, RdpDisplayResolution.minimumDimension)

    // Odd numbers rounded to even
    let odd = RdpDisplayResolution(width: 1921, height: 1081)
    XCTAssertEqual(odd.width, 1922)
    XCTAssertEqual(odd.height, 1082)

    // Clamping maximum
    let tooLarge = RdpDisplayResolution(width: 10000, height: 9000)
    XCTAssertEqual(tooLarge.width, RdpDisplayResolution.maximumDimension)
    XCTAssertEqual(tooLarge.height, RdpDisplayResolution.maximumDimension)
  }

  func testScaleFactorMapping() {
    // Standard display scale
    let std = RdpDisplayResolution.from(pointWidth: 1024, pointHeight: 768, backingScaleFactor: 1.0)
    XCTAssertEqual(std.scaleFactor, 100)
    XCTAssertEqual(std.width, 1024)
    XCTAssertEqual(std.height, 768)

    // Retina 2.0x display scale
    let retina = RdpDisplayResolution.from(pointWidth: 1200, pointHeight: 800, backingScaleFactor: 2.0)
    XCTAssertEqual(retina.scaleFactor, 200)
    XCTAssertEqual(retina.width, 2400)
    XCTAssertEqual(retina.height, 1600)
  }

  func testAspectFitAndPointerMappingUseRemotePixels() throws {
    let rect = try XCTUnwrap(RdpDisplayGeometry.aspectFit(
      remoteWidth: 1920, remoteHeight: 1080, viewWidth: 1000, viewHeight: 1000))
    XCTAssertEqual(rect.x, 0, accuracy: 0.001)
    XCTAssertEqual(rect.y, 218.75, accuracy: 0.001)
    XCTAssertEqual(rect.width, 1000, accuracy: 0.001)
    XCTAssertEqual(rect.height, 562.5, accuracy: 0.001)

    let center = RdpDisplayGeometry.remotePixel(
      atX: 500, y: 500, remoteWidth: 1920, remoteHeight: 1080,
      viewWidth: 1000, viewHeight: 1000)
    XCTAssertEqual(center?.x, 960)
    XCTAssertEqual(center?.y, 540)
    XCTAssertNil(RdpDisplayGeometry.remotePixel(
      atX: 500, y: 100, remoteWidth: 1920, remoteHeight: 1080,
      viewWidth: 1000, viewHeight: 1000))
  }

  func testPointerMappingCanClampReleaseOutsideImage() {
    let release = RdpDisplayGeometry.remotePixel(
      atX: 1200, y: 900, remoteWidth: 1920, remoteHeight: 1080,
      viewWidth: 1000, viewHeight: 1000, clampToImage: true)
    XCTAssertEqual(release?.x, 1919)
    XCTAssertEqual(release?.y, 0)
  }

  func testDebouncerSchedulesSettledUpdate() async {
    let debouncer = RdpDisplayDebouncer()
    let expectation = expectation(description: "Debounced layout settles")

    let targetResolution = RdpDisplayResolution(width: 1920, height: 1080)

    // Rapid successive calls
    debouncer.scheduleUpdate(to: RdpDisplayResolution(width: 800, height: 600)) { _ in }
    debouncer.scheduleUpdate(to: RdpDisplayResolution(width: 1024, height: 768)) { _ in }
    debouncer.scheduleUpdate(to: targetResolution) { settled in
      XCTAssertEqual(settled, targetResolution)
      expectation.fulfill()
    }

    await fulfillment(of: [expectation], timeout: 1.0)
  }
}
