import AppCore
import SwiftUI

struct HostCardView<Actions: View>: View {
  let host: HostRecord
  let workspaceName: String
  let isSelected: Bool
  let onSelect: () -> Void
  var onConnect: () -> Void = {}
  @ViewBuilder let actions: () -> Actions
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button(action: onSelect) {
        VStack(alignment: .leading, spacing: 16) {
          Image(systemName: "server.rack")
            .font(.largeTitle)
            .foregroundStyle(.tint)
            .frame(maxWidth: .infinity, minHeight: 80)
            .background {
              RoundedRectangle(cornerRadius: 12)
                .fill(.tint.opacity(0.08))
            }
            .accessibilityHidden(true)

          VStack(alignment: .leading, spacing: 6) {
            Text(host.displayName).font(.headline)
              .multilineTextAlignment(.leading)
            Text(host.address).font(.callout.monospaced())
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.leading)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .simultaneousGesture(TapGesture(count: 2).onEnded { onConnect() })
      .accessibilityLabel(AppLocalization.format(
        "Host %1$@, address %2$@, workspace %3$@, environment %4$@",
        String(describing: host.displayName),
        String(describing: host.address),
        String(describing: workspaceName),
        host.environment.localizedTitle
      ))
      .accessibilityHint(AppLocalization.string("Select to show host details and connection actions."))
      .accessibilityAddTraits(isSelected ? .isSelected : [])

      HStack {
        EnvironmentBadge(environment: host.environment)
        Spacer(minLength: 8)
        Menu(AppLocalization.string("Host Actions"), systemImage: "ellipsis") { actions() }
          .labelStyle(.iconOnly)
          .menuIndicator(.hidden)
          .fixedSize()
          .accessibilityLabel(AppLocalization.format("Actions for %1$@", String(describing: host.displayName)))
          .help(AppLocalization.format("Connect or manage %1$@", String(describing: host.displayName)))
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 16)
    }
    .background(.background, in: .rect(cornerRadius: 20))
    .overlay {
      RoundedRectangle(cornerRadius: 20)
        .strokeBorder(
          isSelected ? Color.accentColor : Color.secondary.opacity(contrast == .increased ? 1 : 0.25),
          lineWidth: isSelected ? 2 : 1)
        .allowsHitTesting(false)
    }
    .contextMenu { actions() }
    .accessibilityElement(children: .contain)
  }
}
