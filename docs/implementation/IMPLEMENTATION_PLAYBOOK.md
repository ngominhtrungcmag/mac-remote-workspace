# Mac Remote Workspace — Implementation Playbook

Date: 2026-10-30. Active product target: the native Swift application in `apps/macos/`, as accepted by [ADR-010](../adr/native-swift-target.md). The original Design Kit and the React/Tauri/Rust implementation are preserved as historical records; they are not implementation guidance. The original design references reconstructed annexes; see the repository [README](../../README.md) for their provenance.

## Delivery strategy

Ship one tested native macOS vertical slice at a time. Treat `apps/macos/README.md` and the active task document as the implementation baseline. Do not report a feature complete based on the historical Tauri prototype, a mock, or a plan. Requirements and test IDs remain traceable to D01–D16, while Native Swift services and macOS behavior define the implementation.

## Current baseline

The native SwiftPM package currently contains SwiftUI navigation and host inventory, SQLite metadata persistence, strict OpenSSH host-key preflight/trust handling, a PTY session surface, an external RDP launcher, and the N1 Keychain credential slice (generic-password store, credential-reference metadata CRUD, Security → Credentials UI, Keychain-backed password/key-passphrase authentication through a short-lived askpass helper). Terminal uses SwiftTerm (ANSI/full-screen apps, up to 8 tabs per host; remote OSC-52 clipboard and OSC-8 links ignored). This is a partial implementation baseline, not P0 completion. See `apps/macos/README.md` and the current source/tests for exact behavior.

## Native delivery sequence

| Slice | Requirement IDs | Deliverable | Acceptance gate | Status |
|---|---|---|---|---|
| N0 — Native baseline | US-024, US-001/002, FR-001/002/015 | SwiftUI shell, host/workspace metadata, SQLite migrations, macOS build/test path | AppCore repository tests and native app build; no claim beyond observed app behavior | Existing partial baseline; continue from current source |
| N1 — Credentials and SSH authentication | US-005/008, FR-004/005/025, SEC-T03, TC-003/006/023 | Keychain references, explicit credential form and supported authentication, cleanup/rebind behavior | Secret canary absent from SQLite/logs/argv; auth only after strict host trust; denied/locked Keychain handled | Implemented 2026-10-30: Keychain store, credential-ref CRUD, Security → Credentials UI, askpass password/passphrase auth; fixture evidence in run-ssh-fixture.sh. Updated 2026-11-02: OSStatus mapping (errSecAuthFailed/InteractionNotAllowed/UserCanceled/ItemNotFound), distinct user messages, save aborts before any SQLite write, Vault delete keeps metadata when Keychain delete is denied, askpass missing item exits non-zero with empty stdout (no empty-password fallback) are unit-tested. Updated 2026-11-02 (post-N4 fixes): the ephemeral-password path now goes through the injected `CredentialSecretStore` (`create(reference:secret:)` is a protocol member) and `testEphemeralPathAbortsOnDeniedLockedCancelledWithoutLeak` covers denied/locked/cancelled with no leak. Manual-only: real Keychain ACL prompt Deny/Cancel/locked-keychain flows |
| N2 — Session and terminal lifecycle | US-009/010/014, FR-007/008/012/027/028, TC-007/011/016/024 | Multiple managed SSH sessions, terminal surface, resize, cancellation, restoration placeholders | Disposable OpenSSH fixture; bounded output; no command replay or orphan subprocess | Implemented; automated + loopback-fixture evidence (PTY/resize/UTF-8/cleanup, backoff, placeholder restore). 2026-11-02: 4 parallel sessions isolation + resize (SSHPTYParallelSessionTests), backoff jitter and throttle on every failure incl. invalid credentials, no-replay tests (SSHReconnectPolicyTests). Not yet verified: interactive GUI tab/restore flow and real reconnect-storm UI |
| N3 — SFTP and safe transfers | US-011/012/013, FR-009/010/011, TC-008/009/010 | Native SFTP browse, queue, cancellation, collision and overwrite flow | Disposable SFTP fixture; interrupted transfer never appears successful or silently overwrites | Implemented 2026-10-30: NativeSFTPClient over /usr/bin/sftp batch mode, breadcrumb navigation, directory listing parser, atomic staging .part transfers, collision prevention on overwrite=false, SFTPTransferQueue (max 2 concurrency), Transfers view, live loopback fixture round-trip verified in run-ssh-fixture.sh. 2026-11-02: 10 MB/1 GB SHA-256 round-trip and mid-transfer cancel safety (SFTPLargeTransferTests, fixture) |
| N4 — P0 completion and release hardening | US-003/004/007/015/016, FR-003/013/014/015, TC-001/002/012/013/017/018/020 | Import/export, accessibility, redacted diagnostics, migration recovery, signed beta | Traceability review, security acceptance, clean-Mac signing/notarization evidence | Implemented 2026-10-30: JSON & CSV export/import with versioned schema, dry-run validation preview and conflict policies (skip/overwrite/keepBoth), atomic rollback, canary absence test; RedactedLogger with regex sanitization (PEM keys, passwords, bearer tokens, URLs) and bounded 10MB file; Diagnostics bundle export; AuditRepository logging in SQLite; Accessibility shortcuts & VoiceOver labels verified Traceability/security review recorded 2026-11-02 in `TRACEABILITY.md`; `scripts/release-macos.sh` (sign/notarize, dry-run by default) added but not executed. Updated 2026-11-02 (post-N4 fixes): host search with tag/protocol filter and 10k test (FR-003), RedactedLogger and audit wiring for host-key trust, credentials and RDP cert trust (FR-013), `TerminalSecurityPolicy` wired into SwiftTerm delegate (FR-026), `scripts/sbom-macos.sh` + `SBOM.md` (SEC-T08), quit confirmation with active transfers/sessions (FR-028), SFTP delete/rename hardening and unit tests (FR-011). Open: signed/notarized clean-Mac evidence (TC-020); automated tests for the quit prompt and SwiftTerm delegate wiring; audit of SSH/SFTP/RDP session events and host-key rotation (FR-013); advisory scan result and license verification (SEC-T08); live SFTP delete/rename and quit tests run only with an SSH fixture |
| P1 — Workflow additions | US-017–020, US-026–029, FR-016–020 | External RDP, local tunnel, ProxyJump, diagnostics, confirmed snippets and command palette | Feature-specific security and disposable-server evidence; ProxyJump host trust per hop | Implemented: external RDP launcher, loopback local tunnel, ProxyJump with per-hop trust, diagnostics, snippets (merged to dev) |
| P2 — Feasibility-gated extensions | US-021–023, US-030–032, FR-021–024 | Embedded remote desktop, serial, metrics, optional data sources/plugins | Separate compatibility/security gate and explicit go/no-go | In progress (embedded RDP, ADR embedded-rdp-freerdp): FreeRDP 3.10.2 xcframework via `scripts/build-freerdp-macos.sh` (run before `swift build`; `apps/macos/vendor/` is gitignored), real transport with SHA-256 cert trust gate, Keychain NLA credentials, Metal frames, input, disp resize, UTF-8 cliprdr clipboard. FreeRDP now runs in the out-of-process `RdpSessionHelper` (socketpair IPC: frames, input, resize, clipboard, cert-trust prompt round-trip; credentials sent over the socket only after trust acceptance, never argv/env; helper crash surfaces as `.helperCrashed`; helper killed on close and exits on socket EOF; bundled in `bundle-app.sh`). Verified by fake-helper/real-helper unit tests only; frames are copied over the socket (IOSurface not yet). NOT verified against a disposable Windows host (no NLA/cert/resize/clipboard evidence on a real server) |

This plan does not claim that every old roadmap item is in the native application. ProxyJump is P1 per the current user instruction; each hop requires independent host-key verification.

## Dependencies and ownership

- The sole active product code path is `apps/macos/**`. Do not extend `apps/desktop/**`, React/TypeScript packages, Tauri configuration, Rust crates, or the old TypeScript IPC contract.
- Keep SwiftUI presentation separate from typed in-process AppCore service protocols. AppCore owns validation, persistence, trust decisions, and transport policy.
- Coordinate before changing shared app-shell files, SQLite migrations, the session coordinator, SSH session UI, or service contracts. Use isolated worktrees for parallel tasks; do not overlap a shared-file owner.
- `docs/implementation/evidence/**`, the design-kit source, and older prototype ADRs are provenance only. They may support historical claims but do not establish native behavior or test status.

## Native validation baseline

From `apps/macos/`:

```sh
swift build
swift test
./build-native.sh
```

For SSH host-trust/session work, use the disposable loopback fixture:

```sh
./run-ssh-fixture.sh
```

Run the applicable commands for each slice and report unavailable checks. Do not run against production hosts. Protocol changes need real disposable-server evidence; UX changes need native screenshots and accessibility review. Do not invent test results or signing evidence.

## Definition of Done

Each task must cite US/FR/TC/SEC IDs and exact in-scope/out-of-scope paths; implement real behavior and error/empty/loading states; add relevant Swift tests including negative/security cases; run applicable native build, tests, and fixture; update docs/traceability; review the diff; and report `Summary`, `Requirement IDs`, `Files`, `Validation`, `Evidence`, `Risks`, and `Next task`. Host-key failure must reject authentication.
