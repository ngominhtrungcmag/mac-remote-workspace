import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AppCore

public enum ImportExportTab: String, CaseIterable, Identifiable {
  case export = "Export"
  case importTab = "Import"

  public var id: Self { self }
  public var localizedTitle: String { AppLocalization.string(rawValue) }
}

public struct InventoryImportExportSheet: View {
  @ObservedObject var store: WorkspaceStore
  @Environment(\.dismiss) private var dismiss

  @State private var selectedTab: ImportExportTab = .export

  // Export State
  @State private var exportFormat: ExportFormat = .json
  @State private var exportStatusMessage: String?
  @State private var exportErrorMessage: String?

  // Import State
  @State private var showSSHConfigImport = false
  @State private var selectedImportURL: URL?
  @State private var importPreview: InventoryImportPreview?
  @State private var conflictPolicy: ImportConflictPolicy = .skip
  @State private var isAnalyzing = false
  @State private var importErrorMessage: String?
  @State private var importSuccessResult: ImportExecutionResult?

  public enum ExportFormat: String, CaseIterable, Identifiable {
    case json = "JSON Document (.json)"
    case csv = "Comma-Separated Values (.csv)"

    public var id: Self { self }
    public var localizedTitle: String { AppLocalization.string(rawValue) }
  }

  public init(store: WorkspaceStore, initialTab: ImportExportTab = .export) {
    self.store = store
    self._selectedTab = State(initialValue: initialTab)
  }

  public var body: some View {
    VStack(spacing: 0) {
      // Header
      HStack {
        Text(AppLocalization.string("Inventory Management"))
          .font(.headline)
        Spacer()
        Button(AppLocalization.string("Done")) {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
      }
      .padding()

      Divider()

      Picker(AppLocalization.string("Action"), selection: $selectedTab) {
        ForEach(ImportExportTab.allCases) { tab in
          Text(tab.localizedTitle).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .padding([.horizontal, .top])

      TabView(selection: $selectedTab) {
        exportPane
          .tag(ImportExportTab.export)

        importPane
          .tag(ImportExportTab.importTab)
      }
      .tabViewStyle(.automatic)
      .padding()
    }
    .frame(minWidth: 540, idealWidth: 600, minHeight: 460, idealHeight: 520)
    .sheet(isPresented: $showSSHConfigImport) { SSHConfigImportSheet(store: store) }
  }

  // MARK: - Export View

  private var exportPane: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(AppLocalization.string("Export Workspace & Host Inventory"))
        .font(.title3.bold())

      Text(AppLocalization.string("Export your workspaces, host groups, and host configurations to a portable file for backup or sharing. All credentials, passwords, private keys, passphrases, and SSH trust decisions are strictly excluded."))
        .font(.subheadline)
        .foregroundStyle(.secondary)

      GroupBox {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Label(AppLocalization.string("Workspaces to export:"), systemImage: "folder")
            Spacer()
            Text(String(store.workspaces.count)).bold()
          }
          HStack {
            Label(AppLocalization.string("Host groups to export:"), systemImage: "folder.badge.gearshape")
            Spacer()
            Text(String(store.groups.count)).bold()
          }
          HStack {
            Label(AppLocalization.string("Configured hosts:"), systemImage: "desktopcomputer")
            Spacer()
            Text(String(store.hosts.count)).bold()
          }
        }
        .padding(4)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text(AppLocalization.string("Export Format"))
          .font(.subheadline.bold())
        Picker(AppLocalization.string("Format"), selection: $exportFormat) {
          ForEach(ExportFormat.allCases) { fmt in
            Text(fmt.localizedTitle).tag(fmt)
          }
        }
        .pickerStyle(.radioGroup)
      }

      if let status = exportStatusMessage {
        Label(status, systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .font(.subheadline)
      }

      if let err = exportErrorMessage {
        Label(err, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .font(.subheadline)
      }

      Spacer()

      HStack {
        Spacer()
        Button {
          performExport()
        } label: {
          Label(AppLocalization.string("Export to File..."), systemImage: "square.and.arrow.up")
        }
        .buttonStyle(WorkspacePrimaryButtonStyle())
        .controlSize(.large)
        .disabled(store.hosts.isEmpty && store.workspaces.isEmpty)
      }
    }
  }

  // MARK: - Import View

  private var importPane: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        Text(AppLocalization.string("Import Inventory"))
          .font(.title3.bold())

        Text(AppLocalization.string("Import hosts and workspaces from a JSON or CSV file. Preview duplicates before making changes."))
          .font(.subheadline)
          .foregroundStyle(.secondary)

        Button(AppLocalization.string("Import from ~/.ssh/config")) { showSSHConfigImport = true }

        HStack {
          Button {
            selectImportFile()
          } label: {
            Label(selectedImportURL == nil ? AppLocalization.string("Choose File (JSON or CSV)...") : AppLocalization.string("Change File..."), systemImage: "doc.badge.plus")
          }

          if let url = selectedImportURL {
            Text(url.lastPathComponent)
              .font(.subheadline.bold())
              .lineLimit(1)
          }
        }

        if isAnalyzing {
          ProgressView(AppLocalization.string("Analyzing import file..."))
            .padding()
        } else if let preview = importPreview {
          GroupBox(AppLocalization.string("Import Preview")) {
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Text(AppLocalization.string("Hosts found in file:"))
                Spacer()
                Text(String(preview.totalHostsInFile)).bold()
              }
              HStack {
                Text(AppLocalization.string("Valid hosts to import:"))
                Spacer()
                Text(String(preview.hosts.count)).foregroundStyle(.green).bold()
              }
              HStack {
                Text(AppLocalization.string("Workspaces to create:"))
                Spacer()
                Text(String(preview.workspaces.count))
              }
              if !preview.conflicts.isEmpty {
                HStack {
                  Text(AppLocalization.string("Conflicts with existing hosts:"))
                  Spacer()
                  Text(String(preview.conflicts.count))
                    .foregroundStyle(.orange)
                    .bold()
                }
              }
              if !preview.validationErrors.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                  Text(AppLocalization.string("Validation Errors:"))
                    .foregroundStyle(.red)
                    .bold()
                  ForEach(preview.validationErrors, id: \.self) { err in
                    Text("• \(err)").font(.caption).foregroundStyle(.red)
                  }
                }
              }
            }
            .padding(4)
          }

          if !preview.conflicts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
              Text(AppLocalization.string("Conflict Resolution Policy"))
                .font(.subheadline.bold())
              Picker(AppLocalization.string("Policy"), selection: $conflictPolicy) {
                ForEach(ImportConflictPolicy.allCases) { policy in
                  Text(AppLocalization.string(policy.rawValue)).tag(policy)
                }
              }
              .pickerStyle(.radioGroup)
            }
          }
        }

        if let res = importSuccessResult {
          GroupBox {
            VStack(alignment: .leading, spacing: 4) {
              Label(AppLocalization.string("Import completed successfully!"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .bold()
              Text(AppLocalization.format("Added: %1$@, Updated: %2$@, Skipped: %3$@", String(describing: res.addedHostsCount), String(describing: res.updatedHostsCount), String(describing: res.skippedHostsCount)))
                .font(.subheadline)
              Text(AppLocalization.format("Workspaces created: %1$@, Groups created: %2$@", String(describing: res.createdWorkspacesCount), String(describing: res.createdGroupsCount)))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(4)
          }
        }

        if let err = importErrorMessage {
          Label(err, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .font(.subheadline)
        }

        Spacer()

        HStack {
          Spacer()
          Button {
            performImport()
          } label: {
            Label(AppLocalization.string("Complete Import"), systemImage: "tray.and.arrow.down")
          }
          .buttonStyle(WorkspacePrimaryButtonStyle())
          .controlSize(.large)
          .disabled(importPreview == nil || importPreview?.canImport == false)
        }
      }
    }
  }

  // MARK: - Actions

  private func performExport() {
    guard let repo = store.currentRepository else { return }
    exportStatusMessage = nil
    exportErrorMessage = nil

    let savePanel = NSSavePanel()
    savePanel.canCreateDirectories = true
    savePanel.title = AppLocalization.string("Export Workspace Inventory")

    switch exportFormat {
    case .json:
      savePanel.allowedContentTypes = [UTType.json]
      savePanel.nameFieldStringValue = "mrw-inventory-\(Date().formatted(.iso8601.year().month().day())).json"
    case .csv:
      savePanel.allowedContentTypes = [UTType.commaSeparatedText]
      savePanel.nameFieldStringValue = "mrw-inventory-\(Date().formatted(.iso8601.year().month().day())).csv"
    }

    guard savePanel.runModal() == .OK, let targetURL = savePanel.url else { return }

    do {
      switch exportFormat {
      case .json:
        let data = try InventoryImportExportService.exportToJSON(repository: repo)
        try data.write(to: targetURL, options: .atomic)
      case .csv:
        let csvString = try InventoryImportExportService.exportToCSV(repository: repo)
        try csvString.write(to: targetURL, atomically: true, encoding: .utf8)
      }
      exportStatusMessage = AppLocalization.format("Successfully exported to %1$@", targetURL.lastPathComponent)
    } catch {
      exportErrorMessage = AppLocalization.format("Export failed: %1$@", error.localizedDescription)
    }
  }

  private func selectImportFile() {
    let openPanel = NSOpenPanel()
    openPanel.canChooseFiles = true
    openPanel.canChooseDirectories = false
    openPanel.allowsMultipleSelection = false
    openPanel.allowedContentTypes = [UTType.json, UTType.commaSeparatedText, UTType.text, UTType.data]
    openPanel.title = AppLocalization.string("Select Inventory File to Import")

    guard openPanel.runModal() == .OK, let fileURL = openPanel.url else { return }
    selectedImportURL = fileURL
    importSuccessResult = nil
    importErrorMessage = nil
    runDryRun(fileURL: fileURL)
  }

  private func runDryRun(fileURL: URL) {
    guard let repo = store.currentRepository else { return }
    isAnalyzing = true
    importPreview = nil
    importErrorMessage = nil

    Task {
      do {
        let preview: InventoryImportPreview
        if fileURL.lastPathComponent == "config" || fileURL.pathExtension.lowercased() == "sshconfig" {
          // Declarative OpenSSH config source (P2); parsed as text only, never executed.
          preview = try InventoryImportExportService.previewSSHConfig(fileURL: fileURL, repository: repo)
        } else if fileURL.pathExtension.lowercased() == "csv" {
          let content = try String(contentsOf: fileURL, encoding: .utf8)
          preview = try InventoryImportExportService.previewCSV(text: content, repository: repo)
        } else {
          let data = try Data(contentsOf: fileURL)
          preview = try InventoryImportExportService.previewJSON(data: data, repository: repo)
        }

        await MainActor.run {
          self.importPreview = preview
          self.isAnalyzing = false
        }
      } catch {
        await MainActor.run {
          self.importErrorMessage = AppLocalization.format("Preview failed: %1$@", error.localizedDescription)
          self.isAnalyzing = false
        }
      }
    }
  }

  private func performImport() {
    guard let preview = importPreview else { return }
    importErrorMessage = nil

    do {
      let result = try store.importInventory(
        workspaces: preview.workspaces,
        groups: preview.groups,
        hosts: preview.hosts,
        conflictPolicy: conflictPolicy
      )
      self.importSuccessResult = result
      self.importPreview = nil
    } catch {
      self.importErrorMessage = AppLocalization.format("Import failed: %1$@", error.localizedDescription)
    }
  }
}

#if DEBUG
#Preview("InventoryImportExportSheet") {
  InventoryImportExportSheet(store: try! PreviewFixtures.store()).frame(width: 700, height: 550)
}

#endif
