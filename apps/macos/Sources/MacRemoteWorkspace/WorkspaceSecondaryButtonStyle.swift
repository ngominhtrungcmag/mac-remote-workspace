import SwiftUI

struct WorkspaceSecondaryButtonStyle: PrimitiveButtonStyle {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  @ViewBuilder
  func makeBody(configuration: Configuration) -> some View {
    if #available(macOS 26, *), !reduceTransparency, contrast != .increased {
      Button(configuration).buttonStyle(.glass)
    } else {
      Button(configuration).buttonStyle(.bordered)
    }
  }
}
