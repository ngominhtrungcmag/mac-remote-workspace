import Foundation

/// Represents a negotiated remote desktop display configuration for RDPEDISP (FR-021).
public struct RdpDisplayResolution: Sendable, Equatable {
  public let width: UInt32
  public let height: UInt32
  /// DesktopScaleFactor: 100 for standard display (1.0x), 200 for Retina display (2.0x).
  public let scaleFactor: UInt32

  public static let minimumDimension: UInt32 = 200
  public static let maximumDimension: UInt32 = 8192

  public init(width: UInt32, height: UInt32, scaleFactor: UInt32 = 100) {
    // Dimensions must be even for video codecs and clamped within safe bounds
    let clampedWidth = min(max(width, Self.minimumDimension), Self.maximumDimension)
    let clampedHeight = min(max(height, Self.minimumDimension), Self.maximumDimension)

    self.width = clampedWidth % 2 == 0 ? clampedWidth : clampedWidth + 1
    self.height = clampedHeight % 2 == 0 ? clampedHeight : clampedHeight + 1
    self.scaleFactor = scaleFactor == 200 ? 200 : 100
  }

  /// Calculates resolution from view point size and window backing scale factor.
  public static func from(pointWidth: Double, pointHeight: Double, backingScaleFactor: Double) -> RdpDisplayResolution {
    let backing = backingScaleFactor.isFinite && backingScaleFactor > 0 ? backingScaleFactor : 1
    let scale: UInt32 = backing >= 1.5 ? 200 : 100
    func pixels(_ points: Double) -> UInt32 {
      let value = points * (scale == 200 ? 2 : 1)
      guard value.isFinite else { return minimumDimension }
      return UInt32(min(Double(maximumDimension), max(1, value.rounded())))
    }
    let pixelWidth = pixels(pointWidth)
    let pixelHeight = pixels(pointHeight)
    return RdpDisplayResolution(width: pixelWidth, height: pixelHeight, scaleFactor: scale)
  }
}

public struct RdpDisplayRect: Sendable, Equatable {
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double
}

public struct RdpRemotePixel: Sendable, Equatable {
  public let x: UInt16
  public let y: UInt16
}

/// Shared aspect-fit geometry for the Metal viewport and remote pointer mapping.
public enum RdpDisplayGeometry {
  public static func aspectFit(
    remoteWidth: Int, remoteHeight: Int, viewWidth: Double, viewHeight: Double
  ) -> RdpDisplayRect? {
    guard remoteWidth > 0, remoteHeight > 0,
      viewWidth.isFinite, viewHeight.isFinite, viewWidth > 0, viewHeight > 0
    else { return nil }
    let scale = min(viewWidth / Double(remoteWidth), viewHeight / Double(remoteHeight))
    let width = Double(remoteWidth) * scale
    let height = Double(remoteHeight) * scale
    return RdpDisplayRect(x: (viewWidth - width) / 2, y: (viewHeight - height) / 2, width: width, height: height)
  }

  /// Maps AppKit points (bottom-left origin) to FreeRDP pixels (top-left origin).
  public static func remotePixel(
    atX x: Double, y: Double, remoteWidth: Int, remoteHeight: Int,
    viewWidth: Double, viewHeight: Double, clampToImage: Bool = false
  ) -> RdpRemotePixel? {
    guard remoteWidth > 0, remoteHeight > 0,
      remoteWidth <= Int(UInt16.max), remoteHeight <= Int(UInt16.max),
      let rect = aspectFit(
        remoteWidth: remoteWidth, remoteHeight: remoteHeight,
        viewWidth: viewWidth, viewHeight: viewHeight)
    else { return nil }

    let maxX = rect.x + rect.width
    let maxY = rect.y + rect.height
    guard clampToImage || (x >= rect.x && x <= maxX && y >= rect.y && y <= maxY) else { return nil }
    let imageX = min(max(x, rect.x), maxX) - rect.x
    let imageY = maxY - min(max(y, rect.y), maxY)
    return RdpRemotePixel(
      x: UInt16(min(remoteWidth - 1, Int(imageX / rect.width * Double(remoteWidth)))),
      y: UInt16(min(remoteHeight - 1, Int(imageY / rect.height * Double(remoteHeight))))
    )
  }
}

/// Dynamic resolution debouncer implementing the 150ms debounce requirement for RDPEDISP.
public final class RdpDisplayDebouncer: @unchecked Sendable {
  public static let debounceInterval: TimeInterval = 0.150 // 150ms

  private let lock = NSLock()
  private var pendingTask: Task<Void, Never>?
  private var lastRequestedResolution: RdpDisplayResolution?

  public init() {}

  deinit {
    cancel()
  }

  public func cancel() {
    lock.lock()
    pendingTask?.cancel()
    pendingTask = nil
    lock.unlock()
  }

  /// Schedules a display resolution update debounced by 150ms.
  public func scheduleUpdate(
    to resolution: RdpDisplayResolution,
    onSettled: @escaping @Sendable (RdpDisplayResolution) -> Void
  ) {
    lock.lock()
    defer { lock.unlock() }

    if lastRequestedResolution == resolution {
      return
    }
    lastRequestedResolution = resolution

    pendingTask?.cancel()
    pendingTask = Task { [resolution] in
      try? await Task.sleep(nanoseconds: UInt64(Self.debounceInterval * 1_000_000_000))
      guard !Task.isCancelled else { return }
      onSettled(resolution)
    }
  }
}
