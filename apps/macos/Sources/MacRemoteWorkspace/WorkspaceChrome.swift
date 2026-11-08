import SwiftUI

/// Glass belongs to floating controls, rather than the document or terminal beneath them.
struct WorkspaceChrome: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(macOS 26, *), !reduceTransparency, contrast != .increased {
      content.glassEffect(.regular, in: .rect(cornerRadius: 16))
    } else {
      content.background(.background, in: .rect(cornerRadius: 16))
        .overlay {
          RoundedRectangle(cornerRadius: 16).strokeBorder(.secondary, lineWidth: 1)
        }
    }
  }
}
