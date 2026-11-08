# AGENTS.md — Mac Remote Workspace

## Mission

Build a macOS-first, local-first SSH/SFTP workspace as a native Swift application. The sole implementation target is the Swift package at the repository root: SwiftUI/AppKit UI, Swift `AppCore`, SQLite metadata, Apple Keychain, and macOS system services. Deliver safe, working vertical slices; do not treat the historical Tauri prototype as the product target.

## Source of truth

1. Read `README.md`, `docs/README.md`, and `docs/00-document-guide.md`.
2. Read product and behavior requirements in `docs/01-vision-prd.md`, `docs/02-srs.md`, and `docs/03-user-journeys.md`.
3. Read `docs/05-architecture.md`, `docs/06-data-model.md`, `docs/07-protocols-sessions.md`, and `docs/09-security.md`.
4. Read `docs/10-test-plan.md`, `docs/11-build-release-runbook.md`, `docs/12-roadmap-backlog.md`, `docs/13-adr-risks.md`, and `docs/16-implementation-blueprint.md`.
5. Read `docs/implementation/IMPLEMENTATION_PLAYBOOK.md`, and `README.md` before implementation.

Earlier prototype history is not published. Current implementation decisions in ADR-010 and these instructions take precedence.

## Implementation boundary

- Change product code only under `Sources/**` and `Tests/**`, unless the user explicitly requests historical prototype maintenance or a migration of another path.
- Do not add product features to the superseded Tauri prototype.
- Use typed Swift service protocols between SwiftUI and `AppCore`; views do not access SQLite, Keychain, SSH, or SFTP directly.
- Validate input at service boundaries. Use versioned, transactional SQLite migrations and enable foreign keys on every connection.
- Run blocking process and network work away from the main actor. Bound buffers, support cancellation, and clean up subprocesses and file descriptors.
- SSH uses the native transport selected by ADR-010/`docs/07-protocols-sessions.md`. Launch fixed system executables with typed argument arrays; never interpolate user input into a shell command.
- Preserve strict host-key verification before authentication. Unknown keys require an explicit decision; mismatches block authentication.
- Never persist secrets, private-key bytes, passphrases, tokens, or terminal transcripts in SQLite, logs, exports, crash reports, or process arguments.
- Keep local-first behavior. No cloud backend, login, telemetry, server-installed agent, unattended command execution, or arbitrary remote shell API.

## Product boundaries

- **P0:** host/workspace inventory, Keychain-backed credentials, strict SSH host trust, SSH PTY sessions, SFTP browsing/transfers, session lifecycle, safety tests, and macOS beta.
- **P1:** local loopback SSH tunnels, ProxyJump with independent trust checks for every hop, external RDP launcher, diagnostics, and user-confirmed snippets.
- **P2:** embedded remote desktop and other extensions only after their feasibility gates.

## Never do

- Never use `StrictHostKeyChecking=no`, silently trust unknown SSH hosts, or authenticate after a host-key mismatch.
- Never put secrets in SQLite, logs, exports, process arguments, or temporary configuration files.
- Never turn remote paths or user text into shell commands.
- Never silently overwrite a remote or local file.
- Never add broad filesystem or process privileges to bypass macOS privacy controls.
- Never run against production servers during development or testing unless expressly authorized and scoped.
- Never claim tests, signing, notarization, performance, or screenshots that were not produced.
- Never modify another worker's owned files or merge an unreviewed failed change.

## Ownership and collaboration

Work on one vertical slice at a time in an isolated worktree when other work is active. Keep `Sources/AppCore/**`, `Sources/MacRemoteWorkspace/**`, migrations, and Swift tests scoped to the assigned task. Coordinate before editing shared SSH session UI, SQLite migrations, or app-shell files. Do not launch workers unless the user explicitly requests delegation.

## Definition of Done

1. Cite applicable US/FR/TC/SEC IDs and declare the exact in-scope and out-of-scope paths.
2. Implement real behavior and its error, empty, and loading states; no silent fake data.
3. Update appropriate Swift tests, including negative/security cases.
4. Run `swift build`, `swift test`, and `./build-native.sh` where applicable; document anything unavailable. Run `./run-ssh-fixture.sh` for SSH trust/session changes.
5. Include screenshots for UX changes and disposable-server evidence for protocol changes.
6. Report changed paths, commands/results, risks, and known limitations.
7. Keep credentials out of the repository and logs; host-key failure must reject authentication.
