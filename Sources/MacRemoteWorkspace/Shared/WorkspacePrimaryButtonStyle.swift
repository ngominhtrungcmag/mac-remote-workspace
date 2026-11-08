import SwiftUI

/// Keep native button behavior and accessibility while adapting to the available OS.
struct WorkspacePrimaryButtonStyle: PrimitiveButtonStyle {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  @ViewBuilder
  func makeBody(configuration: Configuration) -> some View {
    if #available(macOS 26, *), !reduceTransparency, contrast != .increased {
      Button(configuration).buttonStyle(.glassProminent)
    } else {
      Button(configuration).buttonStyle(.borderedProminent)
    }
  }
}
