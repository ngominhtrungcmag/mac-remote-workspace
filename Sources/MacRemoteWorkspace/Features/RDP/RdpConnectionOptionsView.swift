import AppCore
import SwiftUI

/// Shared controls for embedded RDP defaults and host overrides.
struct RdpConnectionOptionsView: View {
  @Binding var options: RdpConnectionOptions

  var body: some View {
    Text(AppLocalization.string("Embedded RDP settings"))
      .font(.caption.bold())
      .foregroundStyle(.secondary)
    Picker(AppLocalization.string("Desktop resolution"), selection: $options.displayMode) {
      Text(AppLocalization.string("Resize with window")).tag(RdpConnectionOptions.DisplayMode.window)
      Text("1280 × 720").tag(RdpConnectionOptions.DisplayMode.hd720)
      Text("1920 × 1080").tag(RdpConnectionOptions.DisplayMode.fullHD)
      Text("2560 × 1440").tag(RdpConnectionOptions.DisplayMode.qhd)
      Text("3840 × 2160").tag(RdpConnectionOptions.DisplayMode.uhd4K)
    }
    .help(AppLocalization.string("Fixed resolutions use exact pixels at 100% scaling."))
    Toggle(AppLocalization.string("Optimize for Retina displays"), isOn: $options.retina)
      .disabled(options.displayMode != .window)
      .help(AppLocalization.string("Retina applies only when resizing with the window. Fixed resolutions use 100% scaling."))
    Picker(AppLocalization.string("Network profile"), selection: $options.networkProfile) {
      Text(AppLocalization.string("Automatic (current defaults)")).tag(RdpConnectionOptions.NetworkProfile.automatic)
      Text(AppLocalization.string("Reduced bandwidth")).tag(RdpConnectionOptions.NetworkProfile.reducedBandwidth)
      Text(AppLocalization.string("LAN")).tag(RdpConnectionOptions.NetworkProfile.lan)
    }
    if options.displayMode != .window {
      Text(AppLocalization.string("Fixed resolutions use exact pixels at 100% scaling."))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    Text(AppLocalization.string("Higher pixel resolutions use more memory and bandwidth. Reduced bandwidth limits desktop visual effects; it does not set a bandwidth cap."))
      .font(.caption)
      .foregroundStyle(.secondary)
    Text(AppLocalization.string("Applies to new sessions. Reconnect keeps the session's original settings; close and open a new session to use changed settings."))
      .font(.caption)
      .foregroundStyle(.secondary)
  }
}
