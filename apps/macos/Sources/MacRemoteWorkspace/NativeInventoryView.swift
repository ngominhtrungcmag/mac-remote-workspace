import AppCore
import SwiftUI

/// Main native inventory view for Mac Remote Workspace.
/// Contains the searchable, selectable table and the collapsible host detail inspector.
/// Scope and destination are owned by the shell sidebar.
struct NativeInventoryView: View {
  @Environment(\.openWindow) private var openWindow
  @ObservedObject var store: WorkspaceStore
  let selectedScope: InventoryScope

  @Binding var activeSheet: InventorySheet?
  @Binding var deleteTarget: DeleteTarget?
  @Binding var operationError: String?

  @State private var showSSHConfigImport = false
  @State private var selectedHostID: String?
  @State private var searchText: String = ""
  @State private var tagFilter: String?
  @State private var protocolFilter: String?
  @State private var isInspectorPresented: Bool = true
  @AppStorage("inventoryGridView") private var showsGrid = false

  private var selectedWorkspace: WorkspaceRecord? {
    switch selectedScope {
    case .all:
      return nil
    case .workspace(let id):
      return store.workspaces.first { $0.id == id }
    case .group(let id):
      guard let group = store.groups.first(where: { $0.id == id }) else { return nil }
      return store.workspaces.first { $0.id == group.workspaceID }
    }
  }

  private var selectedGroup: HostGroupRecord? {
    guard case .group(let id) = selectedScope else { return nil }
    return store.groups.first { $0.id == id }
  }

  private var scopedHosts: [HostRecord] {
    switch selectedScope {
    case .all:
      return store.hosts
    case .workspace(let id):
      return store.hosts.filter { $0.workspaceID == id }
    case .group(let id):
      return store.hosts.filter { $0.groupID == id }
    }
  }

  private var visibleHosts: [HostRecord] {
    let wsNames = Dictionary(store.workspaces.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    let grpNames = Dictionary(store.groups.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    return HostSearch.filter(
      scopedHosts, query: searchText, tag: tagFilter, protocolName: protocolFilter,
      workspaceNames: wsNames, groupNames: grpNames)
  }

  private var availableTags: [String] {
    Array(Set(scopedHosts.flatMap(\.tags))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }

  /// Selected host strictly derived from visibleHosts so filtered-out/deleted hosts are never actionable
  private var selectedHost: HostRecord? {
    guard let selectedHostID else { return nil }
    return visibleHosts.first(where: { $0.id == selectedHostID })
  }

  private var scopeTitle: String {
    switch selectedScope {
    case .all:
      return AppLocalization.string("inventory.scope.all_hosts")
    case .workspace(let id):
      return store.workspaces.first(where: { $0.id == id })?.name ?? AppLocalization.string("Workspace")
    case .group(let id):
      return store.groups.first(where: { $0.id == id })?.name ?? AppLocalization.string("Group")
    }
  }

  private var scopeSubtitle: String {
    let count = visibleHosts.count
    let countString = AppLocalization.format(
      count == 1 ? "%1$@ host" : "%1$@ hosts",
      String(count)
    )
    let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      return AppLocalization.format("%1$@ matching “%2$@”", countString, trimmed)
    }
    return countString
  }

  var body: some View {
    Group {
      if let storageError = store.storageError {
        unavailableState(storageError)
      } else {
        inventoryMainContent
          .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
          .inspector(isPresented: Binding(
            get: { isInspectorPresented && selectedHost != nil },
            set: { isInspectorPresented = $0 }
          )) {
            if let host = selectedHost {
              HostDetailInspectorView(
                host: host,
                workspaces: store.workspaces,
                groups: store.groups,
                onConnectSSH: { openWindow(id: "ssh-session", value: $0.id) },
                onLaunchRDP: { activeSheet = .launchRdp($0) },
                onBrowseSFTP: { openWindow(id: "sftp-session", value: $0.id) },
                onShowMetrics: { activeSheet = .hostMetrics($0) },
                onEdit: { activeSheet = .editHost($0) },
                onMove: { move($0, to: $1, groupID: $2) },
                onDelete: { deleteTarget = .host($0) }
              )
              .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
            }
          }
      }
    }
    .sheet(isPresented: $showSSHConfigImport) {
      SSHConfigImportSheet(store: store)
    }
    .focusedSceneValue(\.selectedHostActions, selectedHost.map { host in
      SelectedHostActions(host: host,
        connect: { openWindow(id: "ssh-session", value: host.id) },
        sftp: { openWindow(id: "sftp-session", value: host.id) },
        rdp: { activeSheet = .launchRdp(host) },
        edit: { activeSheet = .editHost(host) },
        delete: { deleteTarget = .host(host) })
    })
    .navigationTitle(scopeTitle)
    .navigationSubtitle(scopeSubtitle)
    .searchable(
      text: $searchText,
      placement: .toolbar,
      prompt: AppLocalization.string("Search Hosts")
    )
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button(action: addHost) {
          Label(AppLocalization.string("Add Host"), systemImage: "plus")
        }
        .buttonStyle(WorkspacePrimaryButtonStyle())
        .help(AppLocalization.string("Add a saved host"))
        .disabled(store.storageError != nil)
      }
      ToolbarItem {
        Menu {
          Picker(AppLocalization.string("Protocol"), selection: $protocolFilter) {
            Text(AppLocalization.string("Any Protocol")).tag(String?.none)
            Text("SSH").tag(String?.some("ssh"))
            Text("RDP").tag(String?.some("rdp"))
          }
          Picker(AppLocalization.string("Tag"), selection: $tagFilter) {
            Text(AppLocalization.string("Any Tag")).tag(String?.none)
            ForEach(availableTags, id: \.self) { Text($0).tag(String?.some($0)) }
          }
        } label: {
          Label(
            AppLocalization.string("Filter"),
            systemImage: (tagFilter ?? protocolFilter) == nil
              ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .help(AppLocalization.string("Filter hosts by protocol or tag"))
      }
      ToolbarItem {
        Picker(AppLocalization.string("Host view"), selection: $showsGrid) {
          Label(AppLocalization.string("Grid"), systemImage: "square.grid.2x2").tag(true)
          Label(AppLocalization.string("List"), systemImage: "list.bullet").tag(false)
        }
        .pickerStyle(.segmented)
        .help(AppLocalization.string("Switch between host grid and list"))
      }
      ToolbarItem {
        organizationMenu
      }
      ToolbarItem {
        Button {
          isInspectorPresented.toggle()
        } label: {
          Label(
            selectedHost != nil && isInspectorPresented ? AppLocalization.string("Hide Inspector") : AppLocalization.string("Show Inspector"),
            systemImage: "sidebar.right")
        }
        .help(AppLocalization.string("Toggle host inspector"))
        .disabled(selectedHost == nil)
      }
    }
    .onChange(of: visibleHosts.map(\.id)) { _, _ in
      clearStaleSelection()
    }
    .onChange(of: selectedHostID) { _, hostID in
      if hostID != nil { isInspectorPresented = true }
    }
    .onAppear {
      clearStaleSelection()
    }
  }

  /// Explicitly clears stale or hidden selection to nil rather than auto-selecting another item
  private func clearStaleSelection() {
    guard let currentID = selectedHostID else { return }
    if !visibleHosts.contains(where: { $0.id == currentID }) {
      selectedHostID = nil
    }
  }

  private var inventoryMainContent: some View {
    VStack(spacing: 0) {
      if store.hosts.isEmpty {
        emptyAllHostsState
      } else if scopedHosts.isEmpty {
        emptyScopeState
      } else if visibleHosts.isEmpty {
        noSearchResultsState
      } else if showsGrid {
        ScrollView {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 20)], alignment: .leading, spacing: 20) {
            ForEach(visibleHosts) { host in
              HostCardView(
                host: host,
      workspaceName: store.workspaces.first(where: { $0.id == host.workspaceID })?.name ?? AppLocalization.string("Unknown"),
                isSelected: selectedHostID == host.id,
                onSelect: { selectedHostID = host.id; isInspectorPresented = true },
                onConnect: { connectDefault(host) }
              ) {
                hostActions(for: host)
              }
            }
          }
          .padding(24)
        }
      } else {
        hostTable
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var hostTable: some View {
    Table(visibleHosts, selection: $selectedHostID) {
      TableColumn(AppLocalization.string("Host")) { host in
        VStack(alignment: .leading, spacing: 3) {
          Text(host.displayName).font(.headline).lineLimit(1).truncationMode(.middle)
          Text(host.address).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .padding(.vertical, 4)
      }
      TableColumn(AppLocalization.string("Workspace")) { host in
        Text(store.workspaces.first(where: { $0.id == host.workspaceID })?.name ?? AppLocalization.string("Unknown"))
          .lineLimit(1).truncationMode(.middle)
      }
      TableColumn(AppLocalization.string("Group")) { host in
        Text(host.groupID.flatMap { id in store.groups.first(where: { $0.id == id })?.name } ?? AppLocalization.string("Ungrouped"))
          .foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle)
      }
      TableColumn(AppLocalization.string("Environment")) { host in
        EnvironmentBadge(environment: host.environment)
      }
    }
    .onDeleteCommand { if let host = selectedHost { deleteTarget = .host(host) } }
    .tableStyle(.inset(alternatesRowBackgrounds: false))
    .contextMenu(forSelectionType: HostRecord.ID.self) { selection in
      if let hostID = selection.first, let host = visibleHosts.first(where: { $0.id == hostID }) {
        hostActions(for: host)
      }
    } primaryAction: { selection in
      if let hostID = selection.first, let host = visibleHosts.first(where: { $0.id == hostID }) {
        connectDefault(host)
      }
    }
  }

  private func connectDefault(_ host: HostRecord) {
    switch host.defaultConnectionProtocol {
    case "ssh": openWindow(id: "ssh-session", value: host.id)
    case "rdp": activeSheet = .launchRdp(host)
    default: break
    }
  }

  @ViewBuilder
  private func hostActions(for host: HostRecord) -> some View {
    if host.supportsProtocol("ssh") {
      Button {
        openWindow(id: "ssh-session", value: host.id)
      } label: {
        Label(AppLocalization.string("Connect SSH"), systemImage: "terminal")
    }

    }
    if host.supportsProtocol("rdp") {
      Button {
        activeSheet = .launchRdp(host)
      } label: {
        Label(AppLocalization.string("Remote Desktop (RDP)…"), systemImage: "display")
    }

    }
    if host.supportsProtocol("ssh") {
      Button {
        openWindow(id: "sftp-session", value: host.id)
      } label: {
        Label(AppLocalization.string("Browse Files (SFTP)"), systemImage: "folder")
    }

    }

    Divider()

    Button {
      activeSheet = .editHost(host)
    } label: {
      Label(AppLocalization.string("Edit…"), systemImage: "pencil")
    }

    moveContextMenu(for: host)

    Divider()

    Button(role: .destructive) {
      deleteTarget = .host(host)
    } label: {
      Label(AppLocalization.string("Delete…"), systemImage: "trash")
    }
  }

  private var emptyAllHostsState: some View {
    ContentUnavailableView {
      Label(AppLocalization.string("No saved hosts"), systemImage: "server.rack")
    } description: {
      Text(AppLocalization.string("Add a host to keep its address and environment on this Mac."))
    } actions: {
      VStack(spacing: 8) {
        Button(AppLocalization.string("Add Host"), action: addHost).buttonStyle(WorkspacePrimaryButtonStyle())
        Button(AppLocalization.string("Import from ~/.ssh/config")) { showSSHConfigImport = true }
        Button(AppLocalization.string("Import file…")) { activeSheet = .importExport(.importTab) }
      }
    }
  }

  private var emptyScopeState: some View {
    ContentUnavailableView {
      Label(AppLocalization.format("No hosts in %1$@", String(describing: scopeTitle)), systemImage: "folder")
    } description: {
      Text(AppLocalization.string("Move hosts here or create a new host."))
    } actions: {
      Button(AppLocalization.string("Add Host"), action: addHost).buttonStyle(WorkspacePrimaryButtonStyle())
    }
  }

  private var noSearchResultsState: some View {
    ContentUnavailableView {
      Label(AppLocalization.string("No matching hosts"), systemImage: "magnifyingglass")
    } description: {
      Text(AppLocalization.format("No hosts in %1$@ match the current search and filters.", String(describing: scopeTitle)))
    } actions: {
      Button(AppLocalization.string("Clear Filters")) {
        searchText = ""
        tagFilter = nil
        protocolFilter = nil
      }
      .buttonStyle(WorkspaceSecondaryButtonStyle())
    }
  }

  private func unavailableState(_ message: String) -> some View {
    ContentUnavailableView {
      Label(AppLocalization.string("Workspace inventory is unavailable"), systemImage: "externaldrive.badge.xmark")
    } description: {
      Text(message)
    } actions: {
      Button(AppLocalization.string("Try Again"), action: store.retry).buttonStyle(WorkspaceSecondaryButtonStyle())
    }
    .navigationTitle(AppDestination.hosts.localizedTitle)
  }

  private var organizationMenu: some View {
    Menu {
      Button(AppLocalization.string("New Workspace")) { activeSheet = .organization(.createWorkspace) }
      if let workspace = selectedWorkspace {
        Divider()
        Button(AppLocalization.format("New Group in %1$@", String(describing: workspace.name))) { activeSheet = .organization(.createGroup(workspace)) }
        Button(AppLocalization.string("Rename Workspace…")) { activeSheet = .organization(.renameWorkspace(workspace)) }
        Button(AppLocalization.string("Delete Workspace…"), role: .destructive) { requestWorkspaceDeletion(workspace) }
      }
      if let group = selectedGroup {
        Divider()
        Button(AppLocalization.string("Rename Group…")) { activeSheet = .organization(.renameGroup(group)) }
        Button(AppLocalization.string("Delete Group…"), role: .destructive) { requestGroupDeletion(group) }
      }
    } label: {
      Label(AppLocalization.string("Manage Organization"), systemImage: "folder.badge.gearshape")
    }
    .disabled(store.storageError != nil)
    .accessibilityLabel(AppLocalization.string("Manage workspaces and groups"))
  }

  private func moveContextMenu(for host: HostRecord) -> some View {
    Menu {
      ForEach(store.workspaces) { workspace in
        Menu(workspace.name) {
          Button(AppLocalization.string("Ungrouped")) {
            move(host, to: workspace, groupID: nil)
          }
          .disabled(host.workspaceID == workspace.id && host.groupID == nil)

          let workspaceGroups = store.groups.filter { $0.workspaceID == workspace.id }
          if !workspaceGroups.isEmpty { Divider() }
          ForEach(workspaceGroups) { group in
            Button(group.name) {
              move(host, to: workspace, groupID: group.id)
            }
            .disabled(host.workspaceID == workspace.id && host.groupID == group.id)
          }
        }
      }
    } label: {
      Label(AppLocalization.string("Move…"), systemImage: "folder")
    }
    .disabled(store.workspaces.isEmpty)
  }

  private func addHost() {
    let workspace = selectedWorkspace ?? (store.workspaces.count == 1 ? store.workspaces.first : nil)
    activeSheet = .addHost(workspaceID: workspace?.id, groupID: selectedGroup?.id)
  }

  private func requestWorkspaceDeletion(_ workspace: WorkspaceRecord) {
    let hostCount = store.hosts.filter { $0.workspaceID == workspace.id }.count
    deleteTarget = .workspace(workspace, hostCount: hostCount)
  }

  private func requestGroupDeletion(_ group: HostGroupRecord) {
    let hostCount = store.hosts.filter { $0.groupID == group.id }.count
    deleteTarget = .group(group, hostCount: hostCount)
  }

  private func move(_ host: HostRecord, to workspace: WorkspaceRecord, groupID: String?) {
    do {
      _ = try store.moveHost(
        id: host.id, expectedVersion: host.version, toWorkspaceID: workspace.id, groupID: groupID)
    } catch {
      operationError = error.localizedDescription
    }
  }
}


struct SSHConfigImportSelection {
  let preview: InventoryImportPreview
  var existingNames: Set<String> = []

  var existingAliases: Set<String> {
    Set(preview.conflicts.map { $0.displayName.lowercased() }).union(existingNames.map { $0.lowercased() })
  }
  var selectable: [ImportedHostDraft] { preview.hosts.filter { !existingAliases.contains($0.displayName.lowercased()) } }
  var initialSelection: Set<String> { Set(selectable.map { $0.displayName.lowercased() }) }
  func selected(_ aliases: Set<String>) -> [ImportedHostDraft] {
    selectable.filter { aliases.contains($0.displayName.lowercased()) }
  }
}

struct SSHConfigImportSheet: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var store: WorkspaceStore
  @State private var preview: InventoryImportPreview?
  @State private var selected: Set<String> = []
  @State private var error: String?
  @State private var loading = true

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(AppLocalization.string("Import from ~/.ssh/config")).font(.headline)
      if loading {
        ProgressView(AppLocalization.string("Reading SSH configuration…"))
      } else if let preview {
        let selection = SSHConfigImportSelection(preview: preview, existingNames: Set(store.hosts.map(\.displayName)))
        if !preview.validationErrors.isEmpty {
          Text(AppLocalization.string("Some SSH configuration entries are invalid.")).foregroundStyle(.red)
          ForEach(preview.validationErrors, id: \.self) { Text($0).font(.caption) }
        }
        if preview.hosts.isEmpty { Text(AppLocalization.string("No hosts found in SSH configuration.")) }
        List(preview.hosts, id: \.displayName) { host in
          let key = host.displayName.lowercased()
          let exists = selection.existingAliases.contains(key)
          Toggle(isOn: Binding(get: { selected.contains(key) }, set: { enabled in
            if enabled { selected.insert(key) } else { selected.remove(key) }
          })) {
            VStack(alignment: .leading) {
              Text(host.displayName)
              Text(exists ? AppLocalization.string("Already in inventory") : host.address).font(.caption).foregroundStyle(.secondary)
            }
          }
          .disabled(exists)
        }
      }
      if let error { Text(error).foregroundStyle(.red).accessibilityAddTraits(.updatesFrequently) }
      HStack {
        Spacer()
        Button(AppLocalization.string("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(AppLocalization.string("Import")) { importSelected() }
          .buttonStyle(WorkspacePrimaryButtonStyle()).keyboardShortcut(.defaultAction)
          .disabled(preview == nil || selected.isEmpty || !(preview?.validationErrors.isEmpty ?? false))
      }
    }
    .padding().frame(minWidth: 480, minHeight: 360)
    .task { await load() }
  }

  private func load() async {
    guard let repository = store.currentRepository as? SQLiteHostRepository else {
      error = AppLocalization.string("Workspace inventory is unavailable")
      loading = false
      return
    }
    do {
      let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
      let result = try await Task.detached {
        try InventoryImportExportService.previewSSHConfig(fileURL: url, repository: repository)
      }.value
      preview = result
      selected = SSHConfigImportSelection(preview: result, existingNames: Set(store.hosts.map(\.displayName))).initialSelection
    } catch { self.error = error.localizedDescription }
    loading = false
  }

  private func importSelected() {
    guard let preview else { return }
    do {
      let hosts = SSHConfigImportSelection(preview: preview, existingNames: Set(store.hosts.map(\.displayName))).selected(selected)
      guard !hosts.isEmpty else { dismiss(); return }
      _ = try store.importInventory(workspaces: preview.workspaces, groups: preview.groups, hosts: hosts, conflictPolicy: .skip)
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}
