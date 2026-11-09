import Foundation

/// Nonsecret RDP preferences, captured once for a session and its reconnects (FR-021).
public struct RdpConnectionOptions: Codable, Sendable, Equatable {
  public enum DisplayMode: String, Codable, Sendable, CaseIterable {
    case window, hd720, fullHD, qhd, uhd4K

    public var fixedResolution: RdpDisplayResolution? {
      switch self {
      case .window: return nil
      case .hd720: return .init(width: 1280, height: 720)
      case .fullHD: return .init(width: 1920, height: 1080)
      case .qhd: return .init(width: 2560, height: 1440)
      case .uhd4K: return .init(width: 3840, height: 2160)
      }
    }
  }

  public enum NetworkProfile: String, Codable, Sendable, CaseIterable {
    case automatic, reducedBandwidth, lan
  }

  public var displayMode: DisplayMode
  public var retina: Bool
  public var networkProfile: NetworkProfile

  public init(displayMode: DisplayMode = .window, retina: Bool = true, networkProfile: NetworkProfile = .automatic) {
    self.displayMode = displayMode
    self.retina = retina
    self.networkProfile = networkProfile
  }

  public func initialResolution(_ requested: RdpDisplayResolution) -> RdpDisplayResolution {
    displayMode.fixedResolution ?? requested
  }

  public func resolution(pointWidth: Double, pointHeight: Double, backingScaleFactor: Double) -> RdpDisplayResolution {
    displayMode.fixedResolution ?? .from(pointWidth: pointWidth, pointHeight: pointHeight,
      backingScaleFactor: retina ? backingScaleFactor : 1)
  }
}
