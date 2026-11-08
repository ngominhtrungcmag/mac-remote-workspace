import AppCore
import SwiftUI

/// Right-hand detail inspector for the selected host.
/// Shows host metadata, environment, actions (SSH, RDP, Edit, Move, Delete).
struct HostDetailInspectorView: View {
  let host: HostRecord
  let workspaces: [WorkspaceRecord]
  let groups: [HostGroupRecord]
  let onConnectSSH: (HostRecord) -> Void
  let onLaunchRDP: (HostRecord) -> Void
  let onBrowseSFTP: (HostRecord) -> Void
  let onShowMetrics: (HostRecord) -> Void
  let onEdit: (HostRecord) -> Void
  let onMove: (HostRecord, WorkspaceRecord, String?) -> Void
  let onDelete: (HostRecord) -> Void

  private var hostWorkspace: WorkspaceRecord? {
    workspaces.first(where: { $0.id == host.workspaceID })
  }

  private var hostGroup: HostGroupRecord? {
    host.groupID.flatMap { id in groups.first(where: { $0.id == id }) }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        // Header
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            Image(systemName: "server.rack")
              .font(.title2)
              .foregroundStyle(.secondary)

            Text(host.displayName)
              .font(.title2).bold()
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityAddTraits(.isHeader)
          }

          VStack(alignment: .leading, spacing: 8) {
            Text(host.address)
              .font(.callout.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)

            EnvironmentBadge(environment: host.environment)
          }
        }
        .padding(.bottom, 4)

        Divider()

        // Primary Connection Actions
        VStack(spacing: 10) {
          if host.supportsProtocol("ssh") {
            Button {
              onConnectSSH(host)
            } label: {
              Label(AppLocalization.string("Connect SSH"), systemImage: "terminal")
                .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
          .controlSize(.regular)
          .accessibilityLabel(AppLocalization.format("Connect SSH to %1$@", String(describing: host.displayName)))

          }
          if host.supportsProtocol("rdp") {
            Button {
              onLaunchRDP(host)
            } label: {
              Label(AppLocalization.string("Remote Desktop (RDP)"), systemImage: "display")
                .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
          .controlSize(.regular)
          .accessibilityLabel(AppLocalization.format("Remote Desktop (RDP) to %1$@", String(describing: host.displayName)))

          }
          if host.supportsProtocol("ssh") {
            Button {
              onBrowseSFTP(host)
            } label: {
              Label(AppLocalization.string("Browse Files (SFTP)"), systemImage: "folder")
                .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
          .controlSize(.regular)
          .accessibilityLabel(AppLocalization.format("Browse SFTP files on %1$@", String(describing: host.displayName)))

          Button {
            onShowMetrics(host)
          } label: {
            Label(AppLocalization.string("Host Metrics"), systemImage: "gauge.with.dots.needle.33percent")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
          .controlSize(.regular)
          .accessibilityLabel(AppLocalization.format("Show metrics for %1$@", String(describing: host.displayName)))
          }
        }

        Divider()

        // Host Information
        VStack(alignment: .leading, spacing: 12) {
          Text(AppLocalization.string("Host Details"))
            .accessibilityAddTraits(.isHeader)
            .font(.headline)
            .foregroundStyle(.primary)

          Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
              Text(AppLocalization.string("Workspace"))
                .foregroundStyle(.secondary)
              Text(hostWorkspace?.name ?? AppLocalization.string("Unknown"))
                .fontWeight(.medium)
            }

            GridRow {
              Text(AppLocalization.string("Group"))
                .foregroundStyle(.secondary)
              Text(hostGroup?.name ?? AppLocalization.string("Ungrouped"))
                .foregroundStyle(hostGroup == nil ? .secondary : .primary)
            }

            GridRow {
              Text(AppLocalization.string("Environment"))
                .foregroundStyle(.secondary)
              Text(host.environment.localizedTitle)
                .fontWeight(.medium)
                .foregroundStyle(host.environment == .production ? .red : .primary)
            }

            GridRow {
              Text(AppLocalization.string("Address"))
                .foregroundStyle(.secondary)
              Text(host.address)
                .font(.body.monospaced())
                .textSelection(.enabled)
            }
          }
        }

        Divider()

        // Management Actions
        VStack(alignment: .leading, spacing: 10) {
          Text(AppLocalization.string("Manage"))
            .accessibilityAddTraits(.isHeader)
            .font(.headline)
            .foregroundStyle(.primary)

          HStack(spacing: 8) {
            Button {
              onEdit(host)
            } label: {
              Label(AppLocalization.string("Edit…"), systemImage: "pencil")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(AppLocalization.format("Edit host %1$@", String(describing: host.displayName)))

            moveMenu
              .frame(maxWidth: .infinity)
          }

          Button(role: .destructive) {
            onDelete(host)
          } label: {
            Label(AppLocalization.string("Delete Host…"), systemImage: "trash")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
          .tint(.red)
          .accessibilityLabel(AppLocalization.format("Delete host %1$@", String(describing: host.displayName)))
        }

        Spacer(minLength: 20)
      }
      .padding(24)
    }
    .background(.background)
    .frame(minWidth: 260, idealWidth: 300, maxWidth: .infinity)
  }

  private var moveMenu: some View {
    Menu {
      ForEach(workspaces) { workspace in
        Menu(workspace.name) {
          Button(AppLocalization.string("Ungrouped")) {
            onMove(host, workspace, nil)
          }
          .disabled(host.workspaceID == workspace.id && host.groupID == nil)

          let workspaceGroups = groups.filter { $0.workspaceID == workspace.id }
          if !workspaceGroups.isEmpty { Divider() }
          ForEach(workspaceGroups) { group in
            Button(group.name) {
              onMove(host, workspace, group.id)
            }
            .disabled(host.workspaceID == workspace.id && host.groupID == group.id)
          }
        }
      }
    } label: {
      Label(AppLocalization.string("Move…"), systemImage: "folder")
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    .disabled(workspaces.isEmpty)
    .accessibilityLabel(AppLocalization.format("Move %1$@ to workspace or group", String(describing: host.displayName)))
  }

}
