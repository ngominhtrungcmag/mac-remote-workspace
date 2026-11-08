import Foundation
import Metal
import QuartzCore

/// Supported pixel formats for RDP decoded framebuffers.
public enum RdpPixelFormat: Sendable, Equatable {
  case bgra8Unorm
  case rgba8Unorm

  public var metalFormat: MTLPixelFormat {
    switch self {
    case .bgra8Unorm:
      return .bgra8Unorm
    case .rgba8Unorm:
      return .rgba8Unorm
    }
  }

  public var bytesPerPixel: Int { 4 }
}

/// A decoded video/framebuffer buffer ready for upload to Metal texture.
public struct RdpFramebuffer: Sendable {
  public let width: Int
  public let height: Int
  public let bytesPerRow: Int
  public let pixelFormat: RdpPixelFormat
  public let data: Data

  public init(
    width: Int,
    height: Int,
    bytesPerRow: Int,
    pixelFormat: RdpPixelFormat = .bgra8Unorm,
    data: Data
  ) {
    self.width = width
    self.height = height
    self.bytesPerRow = bytesPerRow
    self.pixelFormat = pixelFormat
    self.data = data
  }
}

public struct RdpFrameSize: Sendable, Equatable {
  public let width: Int
  public let height: Int
}

/// Errors raised by the Metal rendering pipeline.
public enum RdpMetalError: Error, Equatable, AppCoreLocalizedError {
  case metalDeviceUnavailable
  case invalidFramebufferGeometry(String)
  case textureAllocationFailed
  case commandQueueUnavailable
  case renderPipelineUnavailable

  public func displayDescription(locale: Locale?) -> String? {
    switch self {
    case .metalDeviceUnavailable:
      return AppCoreLocalization.string("Metal graphics device is unavailable on this hardware.", locale: locale)
    case .invalidFramebufferGeometry(let reason):
      return AppCoreLocalization.format("Invalid RDP framebuffer geometry: %1$@", reason, locale: locale)
    case .textureAllocationFailed:
      return AppCoreLocalization.string("Failed to allocate Metal texture for RDP display.", locale: locale)
    case .commandQueueUnavailable:
      return AppCoreLocalization.string("Failed to create Metal command queue.", locale: locale)
    case .renderPipelineUnavailable:
      return AppCoreLocalization.string("Failed to create Metal render pipeline for the remote desktop.", locale: locale)
    }
  }
}

/// Hardware-accelerated Metal renderer blitting decoded RDP framebuffers
/// at 60 FPS V-Sync using CAMetalLayer (ADR-011, US-021).
public final class RdpMetalRenderer: @unchecked Sendable {
  public let device: MTLDevice?
  private let commandQueue: MTLCommandQueue?
  private let renderPipeline: MTLRenderPipelineState?
  private let lock = NSLock()
  private var currentTexture: MTLTexture?
  private var textureWidth: Int = 0
  private var textureHeight: Int = 0
  private var textureFormat: MTLPixelFormat?

  public var isHardwareAvailable: Bool {
    availabilityError == nil
  }

  public var availabilityError: RdpMetalError? {
    if device == nil { return .metalDeviceUnavailable }
    if commandQueue == nil { return .commandQueueUnavailable }
    if renderPipeline == nil { return .renderPipelineUnavailable }
    return nil
  }

  public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
    self.device = device
    self.commandQueue = device?.makeCommandQueue()
    self.renderPipeline = device.flatMap { Self.makeRenderPipeline(device: $0) }
  }

  public var currentFrameSize: RdpFrameSize? {
    lock.withLock {
      guard currentTexture != nil else { return nil }
      return RdpFrameSize(width: textureWidth, height: textureHeight)
    }
  }

  public func clear() {
    lock.withLock {
      currentTexture = nil
      textureWidth = 0
      textureHeight = 0
      textureFormat = nil
    }
  }

  // MARK: - Validation

  public static func validateGeometry(
    width: Int,
    height: Int,
    bytesPerRow: Int,
    dataByteCount: Int,
    pixelFormat: RdpPixelFormat = .bgra8Unorm
  ) throws {
    guard width > 0, height > 0 else {
      throw RdpMetalError.invalidFramebufferGeometry("Dimensions must be positive (got \(width)x\(height)).")
    }
    guard width <= Int(RdpDisplayResolution.maximumDimension), height <= Int(RdpDisplayResolution.maximumDimension),
      width <= Int.max / pixelFormat.bytesPerPixel, bytesPerRow <= Int.max / height
    else {
      throw RdpMetalError.invalidFramebufferGeometry("Dimensions or row size exceed the supported bounds.")
    }
    let minimumBytesPerRow = width * pixelFormat.bytesPerPixel
    guard bytesPerRow >= minimumBytesPerRow else {
      throw RdpMetalError.invalidFramebufferGeometry("bytesPerRow \(bytesPerRow) is smaller than row data \(minimumBytesPerRow).")
    }
    let minimumTotalBytes = bytesPerRow * height
    guard dataByteCount >= minimumTotalBytes else {
      throw RdpMetalError.invalidFramebufferGeometry("Buffer size \(dataByteCount) is less than required \(minimumTotalBytes).")
    }
  }

  // MARK: - Texture Management & Frame Upload

  /// Uploads a decoded framebuffer into a Metal texture.
  public func uploadFrame(_ frame: RdpFramebuffer) throws {
    try Self.validateGeometry(
      width: frame.width,
      height: frame.height,
      bytesPerRow: frame.bytesPerRow,
      dataByteCount: frame.data.count,
      pixelFormat: frame.pixelFormat
    )

    guard let device else {
      throw RdpMetalError.metalDeviceUnavailable
    }

    lock.lock()
    defer { lock.unlock() }

    // Recreate texture if dimensions or format changed
    if currentTexture == nil || textureWidth != frame.width || textureHeight != frame.height
      || textureFormat != frame.pixelFormat.metalFormat
    {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: frame.pixelFormat.metalFormat,
        width: frame.width,
        height: frame.height,
        mipmapped: false
      )
      descriptor.usage = [.shaderRead, .shaderWrite]
      guard let newTexture = device.makeTexture(descriptor: descriptor) else {
        throw RdpMetalError.textureAllocationFailed
      }
      currentTexture = newTexture
      textureWidth = frame.width
      textureHeight = frame.height
      textureFormat = frame.pixelFormat.metalFormat
    }

    guard let texture = currentTexture else {
      throw RdpMetalError.textureAllocationFailed
    }

    let region = MTLRegionMake2D(0, 0, frame.width, frame.height)
    frame.data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return }
      texture.replace(
        region: region,
        mipmapLevel: 0,
        withBytes: baseAddress,
        bytesPerRow: frame.bytesPerRow
      )
    }
  }

  // MARK: - Drawing

  /// Blits the latest uploaded texture to a CAMetalLayer at V-Sync.
  public func render(to layer: CAMetalLayer) -> Bool {
    guard let commandQueue, let renderPipeline else { return false }

    lock.lock()
    guard let sourceTexture = currentTexture else {
      lock.unlock()
      return false
    }
    lock.unlock()

    layer.device = device
    layer.pixelFormat = .bgra8Unorm
    layer.framebufferOnly = false
    layer.displaySyncEnabled = true // Lock to V-Sync (60 FPS)

    guard let drawable = layer.nextDrawable() else {
      return false
    }

    guard let viewport = RdpDisplayGeometry.aspectFit(
      remoteWidth: sourceTexture.width, remoteHeight: sourceTexture.height,
      viewWidth: Double(drawable.texture.width), viewHeight: Double(drawable.texture.height)),
      let commandBuffer = commandQueue.makeCommandBuffer()
    else {
      return false
    }

    let pass = MTLRenderPassDescriptor()
    let color = pass.colorAttachments[0]!
    color.texture = drawable.texture
    color.loadAction = .clear
    color.storeAction = .store
    color.clearColor = MTLClearColorMake(0, 0, 0, 1)
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
    encoder.setRenderPipelineState(renderPipeline)
    encoder.setFragmentTexture(sourceTexture, index: 0)
    encoder.setViewport(MTLViewport(
      originX: viewport.x, originY: viewport.y, width: viewport.width, height: viewport.height,
      znear: 0, zfar: 1))
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    encoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
    return true
  }

  private static func makeRenderPipeline(device: MTLDevice) -> MTLRenderPipelineState? {
    let source = """
      #include <metal_stdlib>
      using namespace metal;
      struct VertexOut { float4 position [[position]]; float2 texCoord; };
      vertex VertexOut vertex_main(uint id [[vertex_id]]) {
        constexpr float2 positions[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
        constexpr float2 coords[4] = { float2(0,1), float2(1,1), float2(0,0), float2(1,0) };
        VertexOut out; out.position = float4(positions[id], 0, 1); out.texCoord = coords[id]; return out;
      }
      fragment half4 fragment_main(VertexOut in [[stage_in]], texture2d<half> image [[texture(0)]]) {
        constexpr sampler samplerState(coord::normalized, address::clamp_to_edge, filter::linear);
        return image.sample(samplerState, in.texCoord);
      }
      """
    guard let library = try? device.makeLibrary(source: source, options: nil),
      let vertex = library.makeFunction(name: "vertex_main"),
      let fragment = library.makeFunction(name: "fragment_main")
    else { return nil }
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = vertex
    descriptor.fragmentFunction = fragment
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    return try? device.makeRenderPipelineState(descriptor: descriptor)
  }
}
