# D16 — Native Swift Implementation Blueprint

**Active target:** `apps/macos/`, as decided in [ADR-010](adr/native-swift-target.md). This blueprint supersedes the React/Tauri/Rust repository proposal in the original Design Kit. That proposal remains in `docs/reference/` as historical source material and is not a current implementation option.

## 1. Active repository layout

```text
mac-remote-workspace/
├── apps/macos/
│   ├── Package.swift
│   ├── Sources/
│   │   ├── AppCore/                 # domain policy, storage, SSH/session services
│   │   │   ├── Migrations/          # versioned SQLite migrations
│   │   │   ├── NativeSSHHostTrustService.swift
│   │   │   ├── NativeSSHSessionCoordinator.swift
│   │   │   ├── NativeSSHTransport.swift
│   │   │   ├── SQLiteHostRepository.swift
│   │   │   ├── SSHOutputBuffer.swift
│   │   │   └── WorkspaceStore.swift
│   │   └── MacRemoteWorkspace/      # SwiftUI/AppKit application and views
│   ├── Tests/AppCoreTests/          # Swift package tests
│   ├── run-ssh-fixture.sh           # disposable loopback SSH fixture
│   ├── build-native.sh
│   └── README.md
├── docs/                            # active requirements, plan, ADRs, runbooks
└── docs/implementation/evidence/    # historical prototype evidence; not native acceptance evidence
```

The root `apps/desktop/`, React/TypeScript packages, Rust crates, and IPC contract are historical prototype artifacts. Do not use them as the active feature layout, dependency source, or acceptance evidence.

## 2. Module boundaries

- **SwiftUI/AppKit app shell:** windows, navigation, forms, menus, accessibility, and presentation state.
- **Swift AppCore:** typed in-process services for validation, host policy, session lifecycle, secrets, repositories, and transports. UI views do not access SQLite, Keychain, or network/process APIs directly.
- **SQLite repository:** versioned transactional migrations for non-secret metadata. Keep foreign keys enabled on every connection. Store only opaque references to secrets.
- **Keychain service:** owns secret creation, retrieval, update, and deletion under explicit user actions. Never provide a file or database fallback that exposes plaintext.
- **SSH adapter:** uses the selected macOS-native OpenSSH implementation with strict host-key verification. Treat every endpoint as untrusted until verified/approved; mismatch is terminal for the attempt.
- **SFTP adapter:** a separate feasibility and implementation slice. Do not shell out with a remote path or represent an unverified prototype as SFTP support.
- **RDP launcher:** opens an installed external macOS client without credentials in argv or URI; launch status is not connection status.

## 3. Interface and concurrency conventions

- Prefer small Swift protocols at AppCore boundaries so policy can be unit-tested without a live UI or remote host.
- Validate all UI-provided values again at the service boundary. Return typed, user-safe errors while keeping sensitive details out of logs.
- Run blocking process and network work away from `MainActor`. Own each `Process`, PTY/file descriptor, session, and cancellation path in one lifecycle object.
- Use bounded queues and output buffers; reap children and close descriptors on disconnect, cancellation, and app shutdown.
- Launch fixed system executables by absolute URL with typed argument arrays. Do not build shell strings, evaluate user input, or forward general-purpose command execution through AppCore.
- Keep trust preflight separate from authentication. No password/key passphrase lookup or auth attempt before a trusted/approved host result. A host-key mismatch cannot be bypassed by UI policy.

## 4. Data and migration conventions

- Add schema changes only as ordered SQL migrations in `apps/macos/Sources/AppCore/Migrations/` and test upgrade, rollback/failure, and foreign-key behavior.
- SQLite contains host/workspace/session metadata and opaque Keychain identifiers only. No password, private-key bytes, passphrase, token, or transcript.
- Destructive host, profile, and credential-reference operations require an explicit confirmation that identifies affected records. Do not delete a shared Keychain item while references remain.
- Keep import/export metadata-only and versioned; never import trust decisions as silently approved.

## 5. Technology decisions

| Layer | Active choice | Constraint |
|---|---|---|
| App UI and lifecycle | SwiftUI + AppKit | Native macOS conventions, VoiceOver, keyboard access |
| Package/build | Swift Package Manager | Package declares macOS 14+ currently; verify this floor before release |
| Domain/core | Swift `AppCore` | No Tauri IPC or renderer-to-backend bridge |
| Metadata | SQLite through native Swift repository | Versioned migrations, foreign keys, no secrets |
| Secret storage | Apple Keychain Services | Native credential workflow still needs implementation and denial tests |
| SSH | macOS system OpenSSH managed by Swift | Fixed executables, strict trust, no shell interpolation |
| SFTP | Future native transport slice | Selection is not yet validated by an executable native SFTP spike |
| External RDP | macOS external client launch | Never include password in argv/URI; report launch separately from connection |
| Embedded RDP | Research only, P2 | AppKit feasibility, compatibility, signing, and security go/no-go required |

No new package or transport dependency is approved by this blueprint. Any substantial dependency or target-platform change requires an ADR and a native feasibility test.

## 6. Incremental implementation slices

1. **Credentials and SSH auth:** implement Keychain references and connect credential resolution only after strict host verification. See [`TASK-01-NATIVE-CREDENTIALS.md`](implementation/TASK-01-NATIVE-CREDENTIALS.md).
2. **SSH session lifecycle:** complete the managed PTY session, multiple-session behavior, cancellation, reconnect, and disconnected restoration states with fixture evidence.
3. **SFTP browse and transfers:** validate the native transport first; add safe paths, queue/cancellation, overwrite confirmation, and interrupted-transfer recovery.
4. **P0 completion:** close import/export, workspace restoration, accessibility, redacted diagnostics, data recovery, and release gaps against FR/TC IDs.
5. **P1/P2:** only after P0 dependencies are complete; keep tunnels, ProxyJump, diagnostics, snippets, RDP and other extensions behind their specific acceptance/security gates.

## 7. Task contract

Every implementation task names requirement IDs, exact owned paths, test and evidence expectations, security constraints, and excluded work. Tasks touching shared migrations, app shell, SSH coordinator, service contracts, or session UI require explicit single-owner coordination. Do not parallel-edit shared interfaces.

## 8. Readiness checklist

- [ ] Native architecture decision ADR-010 is accepted and root guidance points to `apps/macos/`.
- [ ] Task has US/FR/TC/SEC IDs and an explicit path boundary.
- [ ] Keychain/auth work proves trust-before-auth and secret-canary absence.
- [ ] SSH/SFTP integration uses only disposable local fixtures.
- [ ] Native macOS build and Swift tests run; unavailable checks are identified.
- [ ] UI changes include native screenshots and keyboard/VoiceOver review.
- [ ] No prototype Tauri test, demo, or evidence is counted as native acceptance.
- [ ] Signing/notarization and clean-Mac results are reported only when actually produced.
