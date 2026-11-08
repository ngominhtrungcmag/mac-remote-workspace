import AppCore
import SwiftUI

struct GeneralSettings: View {
  @AppStorage("appearance") private var appearance: AppAppearance = .system
  @AppStorage(AppLanguage.preferenceKey) private var language: AppLanguage = .system
  @AppStorage("confirmQuit") private var confirmQuit = true

  var body: some View {
    Form {
      Picker(AppLocalization.string("Appearance"), selection: $appearance) {
        ForEach(AppAppearance.allCases) { Text($0.localizedTitle).tag($0) }
      }
      .pickerStyle(.segmented)
      Picker(AppLocalization.string("Language"), selection: $language) {
        ForEach(AppLanguage.allCases) { Text($0.localizedTitle).tag($0) }
      }
      .pickerStyle(.menu)
      Toggle(isOn: $confirmQuit) {
        Text(AppLocalization.string("Confirm before quitting"))
        Text(AppLocalization.string("Ask when SSH/RDP sessions or SFTP transfers are still active."))
      }
      .accessibilityLabel(AppLocalization.string("Confirm before quitting"))
      .accessibilityHint(AppLocalization.string("Ask when SSH/RDP sessions or SFTP transfers are still active."))
    }
    .formStyle(.grouped)
    .onChange(of: appearance) { _, new in new.apply() }
  }
}

#if DEBUG
#Preview("GeneralSettings") {
  GeneralSettings().frame(width: 560, height: 440)
}

#endif
