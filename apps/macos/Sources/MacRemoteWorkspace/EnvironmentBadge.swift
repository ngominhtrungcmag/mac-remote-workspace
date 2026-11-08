import AppCore
import SwiftUI

/// Shared environment pill. Production is never conveyed by color alone (icon + text).
struct EnvironmentBadge: View {
  let environment: HostEnvironment
  @Environment(\.backgroundProminence) private var prominence

  var body: some View {
    let isProduction = environment == .production
    let onSelection = prominence == .increased
    HStack(spacing: 3) {
      if isProduction { Image(systemName: "exclamationmark.triangle.fill").imageScale(.small) }
      Text(environment.localizedTitle)
    }
    .font(.caption.weight(.semibold))
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(
      Capsule().fill(
        onSelection
          ? Color.primary.opacity(0.2)
          : (isProduction ? Color(nsColor: .systemRed).opacity(0.18) : Color(nsColor: .quaternaryLabelColor).opacity(0.5))
      )
    )
    .foregroundStyle(
      onSelection ? Color.primary : (isProduction ? Color(nsColor: .systemRed) : Color.secondary)
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(AppLocalization.format("Environment: %1$@", environment.localizedTitle))
  }
}
