import SwiftUI

struct OrganizationNameSheet: View {
  @Environment(\.dismiss) private var dismiss
  @FocusState private var nameFocused: Bool
  @State private var name: String
  @State private var validationError: String?

  let title: String
  let fieldLabel: String
  let onSave: (String) throws -> Void

  init(title: String, fieldLabel: String, initialName: String = "", onSave: @escaping (String) throws -> Void) {
    self.title = title
    self.fieldLabel = fieldLabel
    self.onSave = onSave
    _name = State(initialValue: initialName)
  }

  var body: some View {
    NavigationStack {
      Form {
        TextField(fieldLabel, text: $name)
          .focused($nameFocused)
          .accessibilityLabel(fieldLabel)
        if let validationError {
          Text(validationError)
            .foregroundStyle(.red)
            .accessibilityAddTraits(.updatesFrequently)
        }
      }
      .formStyle(.grouped)
      .navigationTitle(title)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(AppLocalization.string("Cancel")) { dismiss() }
            .keyboardShortcut(.cancelAction)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(AppLocalization.string("Save"), action: save)
            .buttonStyle(WorkspacePrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
      }
      .frame(minWidth: 400, minHeight: 160)
      .onAppear { nameFocused = true }
    }
  }

  private func save() {
    do {
      try onSave(name)
      dismiss()
    } catch {
      validationError = error.localizedDescription
      nameFocused = true
    }
  }
}

#if DEBUG
#Preview("OrganizationNameSheet") {
  OrganizationNameSheet(title: "New Workspace", fieldLabel: "Name", onSave: { _ in }).frame(width: 440, height: 220)
}

#endif
