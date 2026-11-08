import AppCore
import SwiftUI

@main
struct MacRemoteWorkspaceApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var store = WorkspaceStore()
  @AppStorage(AppLanguage.preferenceKey) private var language: AppLanguage = .system

  private var appLocale: Locale { language.locale ?? Locale.current }

  var body: some Scene {
    WindowGroup(AppLocalization.string("Mac Remote Workspace")) {
      WorkspaceShellView(store: store)
        .id(language)
        .frame(minWidth: 780, minHeight: 480)
        .environment(\.locale, appLocale)
    }
    .defaultSize(width: 1100, height: 700)
    .commands {
      SidebarCommands()
      WorkspaceCommands()
    }

    // SSH sessions open in their own movable/resizable window instead of a sheet.
    WindowGroup(AppLocalization.string("SSH Session"), id: "ssh-session", for: String.self) { $hostID in
      if let host = store.hosts.first(where: { $0.id == hostID }) {
        SSHSessionTabsSheet(
          host: host,
          group: host.groupID.flatMap { id in store.groups.first(where: { $0.id == id }) }
        )
        .navigationTitle(AppLocalization.format("SSH: %1$@", String(describing: host.displayName)))
        .environment(\.locale, appLocale)
      } else {
        UnavailableSessionView(title: AppLocalization.string("SSH session unavailable"), symbol: "terminal")
      }
    }
    .defaultSize(width: 1000, height: 720)

    WindowGroup(AppLocalization.string("SFTP Session"), id: "sftp-session", for: String.self) { $hostID in
      if let host = store.hosts.first(where: { $0.id == hostID }) {
        SFTPBrowserSheet(host: host, transferQueue: AppLifecycle.shared.transferQueue)
          .navigationTitle(AppLocalization.format("SFTP — %1$@", host.displayName))
          .environment(\.locale, appLocale)
      } else {
        UnavailableSessionView(title: AppLocalization.string("SFTP session unavailable"), symbol: "folder")
      }
    }
    .defaultSize(width: 1000, height: 720)

    WindowGroup(AppLocalization.string("Remote Desktop"), id: "rdp-session", for: String.self) { $windowID in
      if let windowID {
        RdpSessionWindowView(windowID: windowID)
          .environment(\.locale, appLocale)
      }
    }
    .defaultSize(width: 1280, height: 800)

    Settings {
      NativeSettingsView()
        .environment(\.locale, appLocale)
    }
  }
}


struct UnavailableSessionView: View {
  @Environment(\.dismiss) private var dismiss
  let title: String
  let symbol: String

  var body: some View {
    ContentUnavailableView {
      Label(title, systemImage: symbol)
    } actions: {
      Button(AppLocalization.string("Close")) { dismiss() }
    }
  }
}

private struct PaletteResult: Identifiable {
  let id: String
  let title: String
}

private struct WorkspaceShellView: View {
  @ObservedObject var store: WorkspaceStore
  @ObservedObject private var transferQueue = AppLifecycle.shared.transferQueue
  @State private var selection: ShellDestination = .inventory(.all)
  @SceneStorage("sidebarSelection") private var savedSelection = "inventory-all"
  @Environment(\.openWindow) private var openWindow
  @State private var showPalette = false
  @State private var paletteQuery = ""
  @State private var paletteIndex = 0
  @State private var pendingPaletteRdpHost: HostRecord?
  @FocusState private var paletteFocused: Bool

  // Sheets and alerts managed at shell level
  @State private var activeSheet: InventorySheet?
  @State private var deleteTarget: DeleteTarget?
  @State private var operationError: String?

  /// Binding allowing ⌘1-4 commands and external focus to read/set destination
  private var appDestinationBinding: Binding<AppDestination> {
    Binding(
      get: { selection.appDestination },
      set: { destination in
        switch destination {
        case .hosts:
          selection = .inventory(.all)
        case .transfers:
          selection = .security(.transfers)
        case .credentials:
          selection = .security(.credentials)
        case .knownHosts:
          selection = .security(.knownHosts)
        }
      }
    )
  }

  private var optionalSelection: Binding<ShellDestination?> {
    Binding(
      get: { selection },
      set: { if let dest = $0 { selection = dest } }
    )
  }

  var body: some View {
    NavigationSplitView {
      sidebarList
        .listStyle(.sidebar)
        .labelStyle(SidebarIconLabelStyle())
        .navigationTitle(AppLocalization.string("Mac Remote Workspace"))
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
    } detail: {
      detailContent
    }
    .focusedSceneValue(\.workspaceDestination, appDestinationBinding)
    .onReceive(NotificationCenter.default.publisher(for: .openCredentialsVault)) { _ in
      selection = .security(.credentials)
    }
    .focusedSceneValue(\.commandPalette, $showPalette)
    .focusedSceneValue(\.activeSheet, $activeSheet)
    .sheet(isPresented: $showPalette, onDismiss: {
      if let host = pendingPaletteRdpHost { activeSheet = .launchRdp(host); pendingPaletteRdpHost = nil }
    }) {
      VStack(alignment: .leading, spacing: 12) {
        Text(AppLocalization.string("Search hosts and workspaces")).font(.headline)
        TextField(AppLocalization.string("Search hosts and workspaces"), text: $paletteQuery)
          .focused($paletteFocused)
          .onSubmit { openPaletteResult() }
          .onKeyPress(.downArrow) { movePaletteSelection(1); return .handled }
          .onKeyPress(.upArrow) { movePaletteSelection(-1); return .handled }
        List(Array(paletteResults.enumerated()), id: \.element.id) { index, result in
          Button(result.title) { paletteIndex = index; openPaletteResult() }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowBackground(index == paletteIndex ? Color.accentColor.opacity(0.2) : Color.clear)
        }
        Button(AppLocalization.string("Close")) { showPalette = false }.keyboardShortcut(.cancelAction)
      }
      .padding()
      .frame(width: 420, height: 360)
      .onAppear { paletteIndex = 0; paletteFocused = true }
      .onChange(of: paletteQuery) { _, _ in paletteIndex = 0 }
      .onDisappear { paletteQuery = "" }
    }
    .onAppear { restoreSidebarSelection() }
    .onChange(of: selection) { _, value in savedSelection = value.id }
    .sheet(item: $activeSheet, content: sheetContent)
    .confirmationDialog(
      deleteTarget?.title ?? AppLocalization.string("Delete item?"),
      isPresented: deleteConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button(deleteTarget?.buttonTitle ?? AppLocalization.string("Delete"), role: .destructive, action: deleteSelectedItem)
      Button(AppLocalization.string("Cancel"), role: .cancel) { deleteTarget = nil }
    } message: {
      Text(deleteTarget?.message ?? AppLocalization.string("This action cannot be undone."))
    }
    .alert(AppLocalization.string("Inventory error"), isPresented: errorAlertPresented) {
      Button(AppLocalization.string("OK"), role: .cancel) { operationError = nil }
    } message: {
      Text(operationError ?? AppLocalization.string("The operation could not be completed."))
    }
    .onChange(of: store.workspaces) { _, _ in
      validateSelectionAfterStoreChange()
    }
    .onChange(of: store.groups) { _, _ in
      validateSelectionAfterStoreChange()
    }
  }

  private var paletteResults: [PaletteResult] {
    let workspaceNames = Dictionary(store.workspaces.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    let groupNames = Dictionary(store.groups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    let hosts = HostSearch.filter(store.hosts, query: paletteQuery, workspaceNames: workspaceNames, groupNames: groupNames)
      .map { PaletteResult(id: "host:" + $0.id, title: $0.displayName) }
    let workspaces = store.workspaces.filter { paletteQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(paletteQuery) }
      .map { PaletteResult(id: "workspace:" + $0.id, title: $0.name) }
    if paletteQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return [PaletteResult(id: "all", title: AppLocalization.string("All Hosts"))] + workspaces + hosts
    }
    return hosts + workspaces
  }

  private func movePaletteSelection(_ offset: Int) {
    guard !paletteResults.isEmpty else { return }
    paletteIndex = min(max(0, paletteIndex + offset), paletteResults.count - 1)
  }

  private func openPaletteResult() {
    guard paletteResults.indices.contains(paletteIndex) else { return }
    let id = paletteResults[paletteIndex].id
    if id == "all" { selection = .inventory(.all) }
    else if id.hasPrefix("workspace:") { selection = .inventory(.workspace(String(id.dropFirst(10)))) }
    else if id.hasPrefix("host:"), let host = store.hosts.first(where: { $0.id == String(id.dropFirst(5)) }) {
      switch host.defaultConnectionProtocol {
      case "ssh": openWindow(id: "ssh-session", value: host.id)
      case "rdp": pendingPaletteRdpHost = host
      default: return
      }
    }
    showPalette = false
  }

  private func restoreSidebarSelection() {
    guard let restored = ShellDestination(storedID: savedSelection) else { return }
    selection = restored
    validateSelectionAfterStoreChange()
  }

  // MARK: - Sidebar

  private var sidebarList: some View {
    List(selection: optionalSelection) {
      Section(AppLocalization.string("Workspace")) {
        NavigationLink(value: ShellDestination.inventory(.all)) {
          scopeRow(AppLocalization.string("All Hosts"), symbol: "server.rack", count: store.hosts.count)
        }
        .accessibilityLabel(AppLocalization.format("All Hosts, %1$@ hosts", String(describing: store.hosts.count)))

        NavigationLink(value: ShellDestination.security(.transfers)) {
        Label(AppDestination.transfers.localizedTitle, systemImage: AppDestination.transfers.symbolName)
        }
        .badge(transferQueue.items.filter(\.isActiveTransfer).count)
        .accessibilityLabel(AppDestination.transfers.localizedTitle)
      }

      if !store.workspaces.isEmpty {
        Section(AppLocalization.string("Workspaces")) {
          ForEach(store.workspaces) { workspace in
            let hostCount = store.hosts.filter { $0.workspaceID == workspace.id }.count
            NavigationLink(value: ShellDestination.inventory(.workspace(workspace.id))) {
              scopeRow(
                workspace.name,
                symbol: "folder",
                count: hostCount
              )
            }
            .accessibilityLabel(AppLocalization.format("Workspace %1$@, %2$@ hosts", String(describing: workspace.name), String(describing: hostCount)))
            .contextMenu {
              Button(AppLocalization.string("New Group")) { activeSheet = .organization(.createGroup(workspace)) }
              Button(AppLocalization.string("Rename Workspace")) { activeSheet = .organization(.renameWorkspace(workspace)) }
              Button(AppLocalization.string("Delete Workspace"), role: .destructive) { requestWorkspaceDeletion(workspace) }
            }

            ForEach(groups(in: workspace.id)) { group in
              let groupHostCount = store.hosts.filter { $0.groupID == group.id }.count
              NavigationLink(value: ShellDestination.inventory(.group(group.id))) {
                scopeRow(
                  group.name,
                  symbol: "folder.fill",
                  count: groupHostCount
                )
                .padding(.leading, 12)
              }
              .accessibilityLabel(AppLocalization.format("Group %1$@, %2$@ hosts", String(describing: group.name), String(describing: groupHostCount)))
              .contextMenu {
                Button(AppLocalization.string("Rename Group")) { activeSheet = .organization(.renameGroup(group)) }
                Button(AppLocalization.string("Delete Group"), role: .destructive) { requestGroupDeletion(group) }
              }
            }
          }
        }
      }

      Section(AppLocalization.string("Security")) {
        NavigationLink(value: ShellDestination.security(.credentials)) {
          Label(AppDestination.credentials.localizedTitle, systemImage: AppDestination.credentials.symbolName)
        }
        .accessibilityLabel(AppDestination.credentials.localizedTitle)

        NavigationLink(value: ShellDestination.security(.knownHosts)) {
          Label(AppDestination.knownHosts.localizedTitle, systemImage: AppDestination.knownHosts.symbolName)
        }
        .accessibilityLabel(AppDestination.knownHosts.localizedTitle)
      }
    }
  }

  private func scopeRow(_ name: String, symbol: String, count: Int) -> some View {
    HStack(spacing: 8) {
      Label(name, systemImage: symbol)
        .lineLimit(1)
      Spacer(minLength: 4)
      Text(count.formatted())
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
    .padding(.vertical, 3)
    .contentShape(Rectangle())
  }

  private func groups(in workspaceID: String) -> [HostGroupRecord] {
    store.groups.filter { $0.workspaceID == workspaceID }
  }

  // MARK: - Detail Content

  @ViewBuilder
  private var detailContent: some View {
    switch selection {
    case .inventory(let scope):
      NativeInventoryView(
        store: store,
        selectedScope: scope,
        activeSheet: $activeSheet,
        deleteTarget: $deleteTarget,
        operationError: $operationError
      )
    case .security(let destination):
      if destination == .credentials {
        CredentialVaultView()
          .navigationTitle(destination.localizedTitle)
      } else if destination == .knownHosts {
        KnownHostsVaultView()
          .navigationTitle(destination.localizedTitle)
      } else if destination == .transfers {
        TransfersQueueView(queue: transferQueue)
      } else {
        VStack(spacing: 12) {
          Image(systemName: destination.symbolName)
            .font(.largeTitle)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)

          Text(destination.localizedEmptyStateTitle)
            .font(.title2.weight(.semibold))
            .accessibilityAddTraits(.isHeader)

          Text(destination.localizedEmptyStateMessage)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(destination.localizedTitle)
        .navigationSubtitle("")
      }
    }
  }

  // MARK: - Stale Selection Handling

  private func validateSelectionAfterStoreChange() {
    switch selection {
    case .inventory(let scope):
      switch scope {
      case .all:
        break
      case .workspace(let id):
        if !store.workspaces.contains(where: { $0.id == id }) {
          selection = .inventory(.all)
        }
      case .group(let id):
        if let group = store.groups.first(where: { $0.id == id }) {
          if !store.workspaces.contains(where: { $0.id == group.workspaceID }) {
            selection = .inventory(.all)
          }
        } else {
          selection = .inventory(.all)
        }
      }
    case .security:
      break
    }
  }

  // MARK: - Deletion & CRUD

  private func requestWorkspaceDeletion(_ workspace: WorkspaceRecord) {
    let hostCount = store.hosts.filter { $0.workspaceID == workspace.id }.count
    deleteTarget = .workspace(workspace, hostCount: hostCount)
  }

  private func requestGroupDeletion(_ group: HostGroupRecord) {
    let hostCount = store.hosts.filter { $0.groupID == group.id }.count
    deleteTarget = .group(group, hostCount: hostCount)
  }

  private func deleteSelectedItem() {
    guard let deleteTarget else { return }
    do {
      switch deleteTarget {
      case .workspace(let workspace, _):
        let scopeBelongsToWorkspace: Bool
        if case .inventory(let scope) = selection {
          switch scope {
          case .all:
            scopeBelongsToWorkspace = false
          case .workspace(let id):
            scopeBelongsToWorkspace = id == workspace.id
          case .group(let id):
            scopeBelongsToWorkspace = store.groups.first(where: { $0.id == id })?.workspaceID == workspace.id
          }
        } else {
          scopeBelongsToWorkspace = false
        }

        try store.deleteWorkspace(id: workspace.id, expectedVersion: workspace.version)
        if scopeBelongsToWorkspace {
          selection = .inventory(.all)
        }
      case .group(let group, _):
        try store.deleteGroup(id: group.id, expectedVersion: group.version)
        if case .inventory(.group(let gid)) = selection, gid == group.id {
          selection = .inventory(.workspace(group.workspaceID))
        }
      case .host(let host):
        try store.deleteHost(id: host.id)
      }
      self.deleteTarget = nil
    } catch {
      operationError = error.localizedDescription
    }
  }

  private var errorAlertPresented: Binding<Bool> {
    Binding(
      get: { operationError != nil },
      set: { if !$0 { operationError = nil } }
    )
  }

  private var deleteConfirmationPresented: Binding<Bool> {
    Binding(
      get: { deleteTarget != nil },
      set: { if !$0 { deleteTarget = nil } }
    )
  }

  // MARK: - Sheets

  @ViewBuilder
  private func sheetContent(for sheet: InventorySheet) -> some View {
    switch sheet {
    case .launchRdp(let host):
      RdpLaunchSheet(host: host)
    case .serialConsole:
      SerialConsoleSheet()
    case .hostMetrics(let host):
      HostMetricsSheet(host: host)
    case .addHost(let workspaceID, let groupID):
      HostEditorSheet(
        host: nil,
        workspaces: store.workspaces,
        groups: store.groups,
        preferredWorkspaceID: workspaceID,
        preferredGroupID: groupID
      ) { draft in
        try store.createHost(draft)
      }
    case .editHost(let host):
      HostEditorSheet(
        host: host,
        workspaces: store.workspaces,
        groups: store.groups,
        preferredWorkspaceID: nil,
        preferredGroupID: nil
      ) { draft in
        try store.updateHost(id: host.id, expectedVersion: host.version, draft: draft)
      }
    case .organization(let kind):
      organizationSheet(for: kind)
    case .importExport(let tab):
      InventoryImportExportSheet(store: store, initialTab: tab)
    }
  }

  private func organizationSheet(for kind: OrganizationSheetKind) -> some View {
    switch kind {
    case .createWorkspace:
      OrganizationNameSheet(title: AppLocalization.string("New Workspace"), fieldLabel: AppLocalization.string("Workspace name")) { name in
        _ = try store.createWorkspace(name: name)
      }
    case .renameWorkspace(let workspace):
      OrganizationNameSheet(
        title: AppLocalization.string("Rename Workspace"), fieldLabel: AppLocalization.string("Workspace name"), initialName: workspace.name
      ) { name in
        _ = try store.updateWorkspace(id: workspace.id, expectedVersion: workspace.version, name: name)
      }
    case .createGroup(let workspace):
      OrganizationNameSheet(title: AppLocalization.string("New Group"), fieldLabel: AppLocalization.string("Group name")) { name in
        _ = try store.createGroup(workspaceID: workspace.id, name: name)
      }
    case .renameGroup(let group):
      OrganizationNameSheet(title: AppLocalization.string("Rename Group"), fieldLabel: AppLocalization.string("Group name"), initialName: group.name) { name in
        _ = try store.updateGroup(id: group.id, expectedVersion: group.version, name: name)
      }
    }
  }
}

// MARK: - Focus & Commands

extension HostRecord {
  func supportsProtocol(_ name: String) -> Bool {
    protocols.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
  }

  static let preferredProtocolKey = "defaultConnectionProtocol"

  /// Settings choice (SSH by default) wins when supported; protocol order from storage is not meaningful.
  var defaultConnectionProtocol: String? {
    let preferred = UserDefaults.standard.string(forKey: Self.preferredProtocolKey) == "rdp" ? "rdp" : "ssh"
    let other = preferred == "ssh" ? "rdp" : "ssh"
    return supportsProtocol(preferred) ? preferred : supportsProtocol(other) ? other : nil
  }
}

struct SelectedHostActions {
  let host: HostRecord
  let connect: () -> Void
  let sftp: () -> Void
  let rdp: () -> Void
  let edit: () -> Void
  let delete: () -> Void

  func supports(_ name: String) -> Bool {
    host.supportsProtocol(name)
  }
}

private struct SelectedHostActionsKey: FocusedValueKey {
  typealias Value = SelectedHostActions
}

extension FocusedValues {
  var selectedHostActions: SelectedHostActions? {
    get { self[SelectedHostActionsKey.self] }
    set { self[SelectedHostActionsKey.self] = newValue }
  }
}

private struct WorkspaceDestinationKey: FocusedValueKey {
  typealias Value = Binding<AppDestination>
}

private struct CommandPaletteKey: FocusedValueKey {
  typealias Value = Binding<Bool>
}

private struct ActiveSheetKey: FocusedValueKey {
  typealias Value = Binding<InventorySheet?>
}

private extension FocusedValues {
  var commandPalette: Binding<Bool>? {
    get { self[CommandPaletteKey.self] }
    set { self[CommandPaletteKey.self] = newValue }
  }

  var activeSheet: Binding<InventorySheet?>? {
    get { self[ActiveSheetKey.self] }
    set { self[ActiveSheetKey.self] = newValue }
  }

  var workspaceDestination: Binding<AppDestination>? {
    get { self[WorkspaceDestinationKey.self] }
    set { self[WorkspaceDestinationKey.self] = newValue }
  }
}

private struct WorkspaceCommands: Commands {
  @FocusedValue(\.workspaceDestination) private var destination: Binding<AppDestination>?
  @FocusedValue(\.commandPalette) private var commandPalette: Binding<Bool>?
  @FocusedValue(\.activeSheet) private var activeSheet: Binding<InventorySheet?>?
  @FocusedValue(\.selectedHostActions) private var hostActions: SelectedHostActions?

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button(AppLocalization.string("New Host")) {
        activeSheet?.wrappedValue = .addHost(workspaceID: nil, groupID: nil)
      }
      .keyboardShortcut("n", modifiers: .command)
      .disabled(activeSheet == nil)
      Button(AppLocalization.string("Serial Console")) { activeSheet?.wrappedValue = .serialConsole }
        .disabled(activeSheet == nil)
    }

    CommandGroup(replacing: .importExport) {
      Button(AppLocalization.string("Import Inventory…")) {
        activeSheet?.wrappedValue = .importExport(.importTab)
      }
      .disabled(activeSheet == nil)

      Button(AppLocalization.string("Export Inventory…")) {
        activeSheet?.wrappedValue = .importExport(.export)
      }
      .disabled(activeSheet == nil)
    }

    CommandMenu(AppLocalization.string("Host")) {
      if hostActions == nil || hostActions?.supports("ssh") == true {
        Button(AppLocalization.string("Connect SSH")) { hostActions?.connect() }
          .keyboardShortcut("o", modifiers: .command)
          .disabled(hostActions == nil)
        Button(AppLocalization.string("Open SFTP")) { hostActions?.sftp() }
          .disabled(hostActions == nil)
      }
      if hostActions == nil || hostActions?.supports("rdp") == true {
        Button(AppLocalization.string("Open RDP")) { hostActions?.rdp() }
          .disabled(hostActions == nil)
      }
      Divider()
      Button(AppLocalization.string("Edit…")) { hostActions?.edit() }
        .keyboardShortcut("i", modifiers: .command)
        .disabled(hostActions == nil)
      Button(AppLocalization.string("Delete…")) { hostActions?.delete() }
        .keyboardShortcut(.delete, modifiers: .command)
        .disabled(hostActions == nil)
    }

    CommandMenu(AppLocalization.string("Navigate")) {
      Button(AppLocalization.string("Command Palette…")) { commandPalette?.wrappedValue = true }
        .keyboardShortcut("k", modifiers: .command)
        .disabled(commandPalette == nil)
      Divider()
      ForEach(AppDestination.allCases) { item in
        Button(item.localizedTitle) {
          destination?.wrappedValue = item
        }
        .keyboardShortcut(KeyEquivalent(item.keyboardShortcut), modifiers: .command)
      }
    }

    CommandGroup(after: .help) {
      Button(AppLocalization.string("Export Diagnostics Report…")) {
        exportDiagnostics()
      }
    }
  }

  private func exportDiagnostics() {
    let report = RedactedLogger.generateDiagnosticsReport(repository: nil)
    let savePanel = NSSavePanel()
    savePanel.canCreateDirectories = true
    savePanel.title = AppLocalization.string("Save Diagnostics Report")
    savePanel.nameFieldStringValue = "mrw-diagnostics-\(Date().formatted(.iso8601.year().month().day())).md"
    savePanel.allowedContentTypes = [.plainText]
    if savePanel.runModal() == .OK, let targetURL = savePanel.url {
      do {
        try report.write(to: targetURL, atomically: true, encoding: .utf8)
      } catch {
        NSAlert(error: error).runModal()
      }
    }
  }
}

/// Sidebar rows: fixed-width, medium-scale icons so titles align (Homebrew-style).
private struct SidebarIconLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 8) {
      configuration.icon
        .imageScale(.medium)
        .frame(width: 20)
      configuration.title
    }
  }
}
