import AppCore
import SwiftUI

/// Sidebar destination identifying either an inventory scope (under Workspace / Workspaces)
/// or a security destination.
enum ShellDestination: Hashable, Identifiable {
  case inventory(InventoryScope)
  case security(AppDestination)

  init?(storedID: String) {
    if storedID == "inventory-all" { self = .inventory(.all) }
    else if storedID.hasPrefix("inventory-workspace-") { self = .inventory(.workspace(String(storedID.dropFirst("inventory-workspace-".count)))) }
    else if storedID.hasPrefix("inventory-group-") { self = .inventory(.group(String(storedID.dropFirst("inventory-group-".count)))) }
    else if storedID.hasPrefix("security-"), let destination = AppDestination(rawValue: String(storedID.dropFirst("security-".count))), destination != .hosts { self = .security(destination) }
    else { return nil }
  }

  var id: String {
    switch self {
    case .inventory(let scope):
      return "inventory-\(scope.id)"
    case .security(let destination):
      return "security-\(destination.id)"
    }
  }

  /// Map to existing AppDestination for ⌘1-4 shortcut compatibility
  var appDestination: AppDestination {
    switch self {
    case .inventory:
      return .hosts
    case .security(let dest):
      return dest
    }
  }
}

/// Scope within inventory: All Hosts, a specific Workspace, or a specific Group.
enum InventoryScope: Hashable, Identifiable {
  case all
  case workspace(String)
  case group(String)

  var id: String {
    switch self {
    case .all:
      return "all"
    case .workspace(let id):
      return "workspace-\(id)"
    case .group(let id):
      return "group-\(id)"
    }
  }
}

/// Active modal sheet in the shell/inventory
enum InventorySheet: Identifiable {
  case launchRdp(HostRecord)
  case hostMetrics(HostRecord)
  case addHost(workspaceID: String?, groupID: String?)
  case editHost(HostRecord)
  case organization(OrganizationSheetKind)
  case importExport(ImportExportTab)
  case serialConsole

  var id: String {
    switch self {
    case .launchRdp(let host): "launch-rdp-\(host.id)"
    case .hostMetrics(let host): "host-metrics-\(host.id)"
    case .addHost: "add-host"
    case .editHost(let host): "edit-host-\(host.id)"
    case .organization(let kind): kind.id
    case .importExport(let tab): "import-export-\(tab.rawValue)"
    case .serialConsole: "serial-console"
    }
  }
}

/// Organization CRUD sheet kind
enum OrganizationSheetKind: Identifiable {
  case createWorkspace
  case renameWorkspace(WorkspaceRecord)
  case createGroup(WorkspaceRecord)
  case renameGroup(HostGroupRecord)

  var id: String {
    switch self {
    case .createWorkspace: "create-workspace"
    case .renameWorkspace(let workspace): "rename-workspace-\(workspace.id)"
    case .createGroup(let workspace): "create-group-\(workspace.id)"
    case .renameGroup(let group): "rename-group-\(group.id)"
    }
  }
}

/// Delete target for confirmation dialog
enum DeleteTarget {
  case workspace(WorkspaceRecord, hostCount: Int)
  case group(HostGroupRecord, hostCount: Int)
  case host(HostRecord)

  var title: String {
    switch self {
    case .workspace(let workspace, _): AppLocalization.format("Delete %1$@?", workspace.name)
    case .group(let group, _): AppLocalization.format("Delete %1$@?", group.name)
    case .host(let host): AppLocalization.format("Delete %1$@?", host.displayName)
    }
  }

  var buttonTitle: String {
    switch self {
    case .workspace: AppLocalization.string("Delete Workspace")
    case .group: AppLocalization.string("Delete Group")
    case .host: AppLocalization.string("Delete Host")
    }
  }

  var message: String {
    switch self {
    case .workspace(_, let count):
      AppLocalization.format(
        "This removes %1$@ %2$@, groups, profiles, and history from this Mac. Saved credentials are kept. Active sessions or transfers block deletion.",
        String(count),
        AppLocalization.string(count == 1 ? "host" : "hosts")
      )
    case .group(_, let count):
      AppLocalization.format(
        count == 1 ? "%1$@ host stays in this workspace and becomes ungrouped." : "%1$@ hosts stay in this workspace and become ungrouped.",
        String(count)
      )
    case .host:
      AppLocalization.string("Its connection profiles and history will be removed. Saved credentials are kept.")
    }
  }
}
