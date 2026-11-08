import Foundation
import Metal
import XCTest

@testable import AppCore

final class RdpMetalRendererTests: XCTestCase {
  func testGeometryValidation() {
    // Valid geometry: 100x100 BGRA (4 bytes per pixel, row bytes = 400, total = 40,000)
    XCTAssertNoThrow(try RdpMetalRenderer.validateGeometry(
      width: 100,
      height: 100,
      bytesPerRow: 400,
      dataByteCount: 40000
    ))

    // Valid with row padding
    XCTAssertNoThrow(try RdpMetalRenderer.validateGeometry(
      width: 100,
      height: 100,
      bytesPerRow: 512,
      dataByteCount: 51200
    ))

    // Invalid width or height
    XCTAssertThrowsError(try RdpMetalRenderer.validateGeometry(
      width: 0,
      height: 100,
      bytesPerRow: 400,
      dataByteCount: 40000
    ))

    // Row bytes smaller than width * bytesPerPixel
    XCTAssertThrowsError(try RdpMetalRenderer.validateGeometry(
      width: 100,
      height: 100,
      bytesPerRow: 200,
      dataByteCount: 40000
    ))

    // Buffer smaller than required by rows
    XCTAssertThrowsError(try RdpMetalRenderer.validateGeometry(
      width: 100,
      height: 100,
      bytesPerRow: 400,
      dataByteCount: 30000
    ))

    XCTAssertThrowsError(try RdpMetalRenderer.validateGeometry(
      width: 1, height: 2, bytesPerRow: Int.max, dataByteCount: Int.max))
    XCTAssertThrowsError(try RdpMetalRenderer.validateGeometry(
      width: Int(RdpDisplayResolution.maximumDimension) + 1,
      height: 1, bytesPerRow: Int.max, dataByteCount: Int.max))
  }

  func testTextureUploadWhenDeviceAvailable() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("Metal default device not available in this test environment")
    }

    let renderer = RdpMetalRenderer(device: device)
    XCTAssertTrue(renderer.isHardwareAvailable)

    let width = 64
    let height = 64
    let bytesPerRow = width * 4
    let testData = Data(repeating: 0x7F, count: bytesPerRow * height)

    let frame = RdpFramebuffer(
      width: width,
      height: height,
      bytesPerRow: bytesPerRow,
      pixelFormat: .bgra8Unorm,
      data: testData
    )

    XCTAssertNoThrow(try renderer.uploadFrame(frame))
  }
}
