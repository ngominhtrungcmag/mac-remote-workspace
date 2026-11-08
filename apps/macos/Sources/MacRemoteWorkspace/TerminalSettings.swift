import AppCore
import SwiftUI

struct TerminalSettings: View {
  @AppStorage("terminalFontSize") private var fontSize = 13.0
  @AppStorage("terminalCursorStyle") private var cursorStyle: TerminalCursorStyle = .blinkBlock
  @AppStorage("terminalOptionAsMeta") private var optionAsMeta = true

  var body: some View {
    Form {
      Section {
        Stepper(value: $fontSize, in: 9...28) {
          LabeledContent(AppLocalization.string("Font size"), value: AppLocalization.format("%1$@ pt", String(describing: Int(fontSize))))
        }
        Picker(AppLocalization.string("Cursor"), selection: $cursorStyle) {
          ForEach(TerminalCursorStyle.allCases) { Text($0.localizedTitle).tag($0) }
        }
        Toggle(isOn: $optionAsMeta) {
          Text(AppLocalization.string("Use Option as Meta key"))
          Text(AppLocalization.string("Turn off to type special characters with Option."))
        }
        .accessibilityLabel(AppLocalization.string("Use Option as Meta key"))
        .accessibilityHint(AppLocalization.string("Turn off to type special characters with Option."))
      }
      Section(AppLocalization.string("Preview")) {
        Text("user@host:~$ ls -la")
          .font(.system(size: fontSize, design: .monospaced))
      }
    }
    .formStyle(.grouped)
  }
}
