public struct EmptyState: Equatable, Sendable {
    public let title: String
    public let message: String
}

public enum AppDestination: String, CaseIterable, Hashable, Identifiable, Sendable {
    case hosts
    case transfers
    case credentials
    case knownHosts

    public var id: Self { self }

    public var title: String {
        switch self {
        case .hosts: "Hosts"
        case .transfers: "Transfers"
        case .credentials: "Credentials"
        case .knownHosts: "Known Hosts"
        }
    }

    public var symbolName: String {
        switch self {
        case .hosts: "server.rack"
        case .transfers: "arrow.left.arrow.right"
        case .credentials: "key"
        case .knownHosts: "checkmark.shield"
        }
    }

    public var keyboardShortcut: Character {
        switch self {
        case .hosts: "1"
        case .transfers: "2"
        case .credentials: "3"
        case .knownHosts: "4"
        }
    }

    public var emptyState: EmptyState {
        switch self {
        case .hosts:
            EmptyState(
                title: "No saved hosts",
                message: "Add a host to keep its address and environment on this Mac."
            )
        case .transfers:
            EmptyState(
                title: "No file transfers yet",
                message: "File uploads and downloads initiated during SFTP sessions will appear here with live progress and status."
            )
        case .credentials:
          EmptyState(
            title: "No Keychain credentials yet",
            message: "Add a credential to save its secret in the macOS Keychain. Connections store only an opaque reference — never the secret value."
          )
        case .knownHosts:
            EmptyState(
                title: "No trusted host keys yet",
                message: "When you verify and connect to an SSH host, its public key will appear here for inspection and rotation."
            )
        }
    }
}
