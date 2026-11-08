# D08 — Native AppCore Service Contracts

ADR-010 replaces the original Tauri IPC design with typed in-process Swift services. `specs/ipc.types.ts` and dotted command names are retained for prototype history only; do not extend them for product work.

## 1. Principles

- SwiftUI calls typed `AppCore` services. Views do not access SQLite, Keychain, files, or SSH/SFTP transports directly.
- Service boundaries validate entity IDs, host/profile ownership, paths, state transitions, and explicit user decisions before side effects.
- Types crossing actor or worker boundaries are `Sendable` where applicable. UI state is published through Swift observation/Combine; operation completion is not treated as a successful network connection.
- Errors are typed and redacted. Present user-safe messages while retaining only safe diagnostic codes and local operation metadata.
- Terminal bytes and file contents are streamed in bounded buffers and never persisted as events or logs.

## 2. AppCore service surface

| Service | Operation | Input | Result / policy |
|---|---|---|---|
| `WorkspaceService` | list/create/update/delete | workspace/group IDs and validated drafts | Local metadata; destructive actions require confirmation |
| `HostService` | list/create/update/move/delete | host IDs and validated endpoint drafts | Resolve all references in the local repository |
| `CredentialStore` | store/read/delete | credential reference and short-lived secret bytes | Apple Keychain only; never return secret values to persistent UI state |
| `HostTrustService` | inspect/approve/reject/revoke | endpoint and server-created challenge | Unknown keys require explicit review; mismatch blocks |
| `SSHSessionService` | connect/write/resize/disconnect | saved connection/profile and session IDs | Strict host verification before auth; cancellation and idempotent close |
| `SFTPService` | list/enqueue/cancel/mutate | active session, typed remote paths, conflict policy | Validate every path and require confirmation for destructive actions |
| `RdpLauncher` | status/launch | saved RDP profile | Report `launched`, not `connected`; no password handoff |
| `DiagnosticsService` | inspect connection stages | selected host/profile | Redacted DNS/TCP/SSH timing, no credentials in report |

Service protocols should stay small and domain-focused. Use injected protocols for repository, secret store, SSH transport and RDP launcher so AppCore tests can replace operating-system boundaries without introducing a second runtime layer.

## 3. Observable state and streaming

| State | Owner | Update policy |
|---|---|---|
| Workspace/host inventory | `WorkspaceStore` | Reload after successful repository writes; errors remain visible |
| SSH session state | session view model/session owner | Typed transitions: idle, connecting, trust review, authenticating, running, interrupted, closing, closed, failed |
| SSH terminal output | bounded session buffer | Drain at a bounded UI cadence; preserve byte order and UTF-8 boundaries |
| Transfer progress | transfer service/store | Throttle UI updates; report completed only after validation and final rename |
| User notifications | SwiftUI presentation state | Include operation context and redacted error; never include secrets or terminal content |

Closing a sheet unsubscribes UI observers and asks its session owner to terminate/reap the process, close PTY descriptors and cancel in-flight work. Session IDs are metadata only; process handles are never persisted.

## 4. Typed contract examples

```swift
struct SSHConnectRequest: Sendable {
  let profileID: String
}

enum SSHSessionState: Sendable, Equatable {
  case idle
  case verifyingHost(host: String, port: Int)
  case trustRequired(SSHHostTrustChallenge)
  case connecting
  case running
  case interrupted
  case closed
  case failed(code: SSHFailureCode, message: String)
}

protocol SSHSessionService: Sendable {
  func connect(_ request: SSHConnectRequest) async throws -> SSHSessionHandle
  func disconnect(sessionID: UUID) async
}
```

Secrets are not fields in the connection request. AppCore resolves the referenced credential only after endpoint identity is verified.

## 5. Host trust authorization

A trust challenge is ephemeral and bound to the session, canonical endpoint, port, presented key, and nonce. SwiftUI may approve or reject the active challenge, but cannot submit a replacement fingerprint or endpoint. Approval revalidates that the challenge is still active and unchanged before persisting. Host-key mismatch is a hard stop; rotation is a separate, explicit workflow after out-of-band verification.

For ProxyJump, evaluate each hop independently. Verify a hop before authenticating to it; verify the downstream endpoint before sending its credentials. A mismatch or rejection at any stage aborts the remaining chain.

## 6. Validation, idempotence and concurrency

- `disconnect`, `cancelTransfer`, and `rejectTrustChallenge` are idempotent.
- Repository writes use optimistic versions where concurrent edits are possible.
- File mutations require a short-lived, single-use confirmation bound to session, action, and exact path.
- Terminal input is size-bounded. Transfer queues and output buffers are bounded and cancellable.
- Blocking `Process` and file operations run off the main actor. Cancellation must close descriptors and reap child processes.
- No service accepts arbitrary shell commands. The SSH terminal sends user keystrokes only to an explicitly connected session.

## 7. Versioning and migrations

Swift service contracts are versioned with the app. SQLite schema changes use transactional Swift migrations and pre-upgrade backups. `Codable` models used by import/export require an explicit schema version and strict validation. There is no remote API or cross-process IPC contract in the native app.

## 8. Testing

Use Swift unit tests for validators and state transitions; repository integration tests for migrations and constraints; and disposable loopback OpenSSH tests for host trust, authentication ordering, PTY lifecycle, cancellation, and process cleanup. UI tests verify visible errors, explicit trust/confirmation actions, VoiceOver labels, and observer teardown.
