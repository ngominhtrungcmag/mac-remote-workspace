# TASK-01 — Native Keychain Credentials and SSH Authentication

> Historical paths below describe the layout at the time. The Swift package now lives at the repository root; sources are grouped by feature under `Sources/`, tests under `Tests/`, and current commands are in [README](../../README.md).

**Status:** Implemented 2026-10-30 (N1 slice). See `apps/macos/README.md` ("Keychain credentials and SSH authentication") for the delivered behavior, limitations, and fixture evidence.  
**Architecture:** Native Swift only; [ADR-010](../adr/native-swift-target.md).  
**Baseline:** `apps/macos/README.md` states the current native shell does not read or store credentials and has no password UI. Do not infer credential support from SQLite reference tables or the historical Tauri implementation.

## Requirement IDs

US-005, US-008, FR-004, FR-005, FR-006, FR-025, SEC-T03, TC-003, TC-004, TC-005, TC-006, and TC-023.

## Objective

Add one native SSH credential workflow backed by macOS Keychain and connect it to the existing strict host-trust flow. The credential value must not be retrieved or sent until the host is verified or explicitly approved. Preserve mismatch as a hard stop.

## Scope

- `apps/macos/Sources/AppCore/**`: typed secret-store contract and Keychain implementation; credential reference lifecycle; authentication orchestration policy.
- `apps/macos/Sources/MacRemoteWorkspace/SSHSessionSheet.swift` and its view model only if needed for explicit credential entry and user-visible Keychain errors. Coordinate with any active owner before editing these shared session files.
- `apps/macos/Tests/AppCoreTests/**`: service, policy, negative, and integration tests using unique disposable canaries.
- `apps/macos/README.md` and relevant security/runbook documentation.

Do not modify the SQLite schema unless the task owner approves a migration design first. Do not add secrets or secret values to schema; metadata may contain only opaque Keychain references. Do not add Tauri, React, TypeScript, Rust, cloud, telemetry, or unattended-auth behavior.

## Acceptance criteria

1. A user can create, rebind, and remove a Keychain-backed credential through a native, explicit action. Keychain unavailable/locked/denied errors are visible and do not trigger plaintext fallback.
2. SQLite, logs, exports, crash-facing errors, and process arguments contain no credential canary. Temporary buffers are scoped to the operation and cleared best-effort.
3. For an unknown host, no credential lookup/authentication occurs before an explicit trust decision. Rejection and cancellation send no credential. A known-host mismatch blocks before credential lookup/authentication and cannot be overridden from the connection UI.
4. SSH authentication errors remain distinct from DNS, TCP, host-key, and Keychain errors. Failed auth does not retry credentials indefinitely.
5. Unlink/delete explains shared references; deleting a host does not silently delete a Keychain item still referenced elsewhere.
6. Tests cover success, Keychain denial/absence, bad authentication, unknown host, rejected host, stale trust challenge, changed host key, shared reference cleanup, and canary absence. Protocol cases use only a disposable local fixture.

## Out of scope

SFTP, import/export, ProxyJump, SSH tunnels, snippets, RDP, cloud sync, terminal recording, password delivery through process argv or URL, and broad shell command APIs.

## Validation and report

Run `swift build --package-path apps/macos`, `swift test --package-path apps/macos`, `apps/macos/build-native.sh`, and `apps/macos/run-ssh-fixture.sh` where applicable. Report commands and actual results, paths changed, fixture evidence, screenshots for UI changes, security review, unresolved limitations, and follow-up task. Do not use production hosts or credentials.
