import AppCore
import SwiftUI

struct ConnectionSettings: View {
  @AppStorage("defaultSSHUsername") private var username = ""
  @AppStorage("defaultSSHPort") private var port = 22
  @AppStorage("rdpLaunchMode") private var rdpLaunchMode: RdpLaunchMode = .external
  @AppStorage(HostRecord.preferredProtocolKey) private var preferredProtocol = "ssh"

  var body: some View {
    Form {
      Section {
        Picker(AppLocalization.string("Default protocol"), selection: $preferredProtocol) {
          Text("SSH").tag("ssh")
          Text("RDP").tag("rdp")
        }
        .pickerStyle(.segmented)
      } footer: {
        Text(AppLocalization.string("Used when opening a host that supports both SSH and RDP."))
          .foregroundStyle(.secondary)
      }
      Section {
        TextField(AppLocalization.string("Default username"), text: $username, prompt: Text(NSUserName()))
        TextField(AppLocalization.string("Default port"), value: $port, format: .number.grouping(.never))
          .onChange(of: port) { _, new in port = min(max(new, 1), 65535) }
      } header: {
        Text("SSH")
      } footer: {
        Text(AppLocalization.string("Used for hosts that have no saved connection settings."))
          .foregroundStyle(.secondary)
      }
      Section(AppLocalization.string("Remote Desktop")) {
        Picker(AppLocalization.string("Default launch mode"), selection: $rdpLaunchMode) {
          ForEach(RdpLaunchMode.allCases) { Text($0.localizedTitle).tag($0) }
        }
      }
    }
    .formStyle(.grouped)
  }
}
