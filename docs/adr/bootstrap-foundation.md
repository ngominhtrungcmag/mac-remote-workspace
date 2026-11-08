# ADR-BS-001: Minimal desktop bootstrap

> **Historical prototype decision.** This ADR describes the React/Tauri/Rust bootstrap and its evidence. ADR-010 supersedes its implementation target; none of its paths, commands, dependencies, or test results are current Native Swift acceptance evidence.

Status: Accepted for the scaffold; transport and signing choices remain gated by feasibility spikes.  
Date: 2026-10-27  
Requirement IDs: Task 00, SP-01, SP-02, R-01, R-03  
Scope: root workspace/config, `apps/desktop/**`, `.github/workflows/ci.yml`, and this ADR.  
Out of scope: host inventory, credentials UI, SSH, terminal, SFTP, RDP, cloud, and release signing.

## Context

The project needs a reproducible macOS Tauri 2 + React 19 shell before product work. The design says native transport, Keychain access, and signed distribution must be proven separately. A generated starter screen must not imply those capabilities are already implemented.

## Decision

- Use the official `create-tauri-app` React + TypeScript template as the starting point, then remove its demo command, opener plugin, and unused demo assets. The app displays only bootstrap status and has no product IPC commands. [Tauri create-project guide](https://v2.tauri.app/start/create-project/)
- Pin Node 26.12.1, pnpm 11.9.0, Rust 1.99.0, React/React DOM 19.3.1, TypeScript 6.0.3, Vite 8.3.5, ESLint 10.13.0, typescript-eslint 8.72.0, and Vitest 5.0.5. TypeScript 6.0.3 is within typescript-eslint 8.72.0's declared support range (`>=4.8.4 <6.1.0`). [React versions](https://react.dev/versions), [typescript-eslint setup](https://typescript-eslint.io/getting-started/)
- Pin Tauri CLI 2.12.4 and Rust runtime `tauri` 2.12.5 plus `tauri-build` 2.7.4. The local macOS build is the compatibility gate. [Tauri releases](https://v2.tauri.app/release/)
- Enforce pnpm’s 24-hour minimum release age with strict rejection and no exceptions; dependency lifecycle scripts are disabled. Pin typescript-eslint 8.72.0 because the initial installer auto-waived the newer 8.72.1 package family; this keeps the original age guard intact.
- Keep Tauri capability permissions at `core:default` only. Add a restrictive production CSP and a local-dev CSP for Vite/HMR. No shell, filesystem, opener, SSH, or secret-store permissions are enabled. [Tauri CSP guidance](https://v2.tauri.app/security/csp/)
- Use Apple's Security framework `SecItem` Keychain Services API behind a future Rust `SecretStore` boundary. Choose the API, not a Rust binding; SP-02 must exercise add/read/delete and permission-denied behavior before an adapter is selected. Apple recommends SecItem over its legacy Keychain APIs. [Apple TN3137](https://developer.apple.com/documentation/Technotes/tn3137-on-mac-keychains)
- Keep `ssh2`/libssh2 as the proposed initial SSH/SFTP implementation from D07/D13, but do not add it to the app until SP-01 compares it with `russh` for host fingerprint verification, auth, PTY, SFTP, and packaging.
- Target direct-download macOS distribution with Developer ID signing and notarization. The Task 00 bundle has no Developer ID signature or notarization; its executable carries only the linker’s ad-hoc signature. Strict bundle verification and Gatekeeper assessment fail, so it is not a distributable beta. Revisit if App Store distribution is requested.
- Use one macOS CI job for frontend lint, typecheck, test, build, and Rust format, clippy, and test checks. The CI job does not claim a signed release or x86_64 validation.

## Consequences

The shell is reproducible and intentionally has no SSH, SFTP, inventory, or credential behavior. Adding an IPC bridge will require an explicit command contract and capability review in a later task. Exact pins reduce unreviewed dependency movement; routine upgrades require lockfile and build validation.

## Validation evidence

- `pnpm install --frozen-lockfile`, `pnpm lint`, `pnpm typecheck`, `pnpm test` (1 test passed), and `pnpm build` passed on the local macOS arm64 host.
- `cargo fmt --manifest-path apps/desktop/src-tauri/Cargo.toml -- --check`, `cargo clippy --manifest-path apps/desktop/src-tauri/Cargo.toml --all-targets -- -D warnings`, and `cargo test --manifest-path apps/desktop/src-tauri/Cargo.toml` passed. The scaffold has no Rust adapter tests yet.
- `pnpm tauri dev` launched the native debug app. The coordinator captured a native window. `pnpm build:desktop` produced `apps/desktop/src-tauri/target/release/bundle/macos/Mac Remote Workspace.app` (9.71 MiB).
- The worker’s first default `pnpm tauri build` failed during DMG unmount (`Resource busy`). A coordinator rerun from the integrated repository succeeded and produced both the 9.71 MiB `.app` and 2.86 MiB arm64 `.dmg`; the earlier failure is retained as transient evidence.
- No Developer ID signing or notarization was attempted; no Apple signing profile was supplied. `codesign -dv` reports `adhoc,linker-signed`, no TeamIdentifier, and no sealed resources. `codesign --verify --deep --strict` and `spctl --assess --type execute` both fail with `code has no resources but signature indicates they must be present`. No security protection was bypassed.

## Review triggers

- SP-01 rejects `ssh2`/libssh2 on trust, PTY, SFTP, or package feasibility.
- SP-02 shows the chosen SecItem access model cannot satisfy Keychain UX or distribution needs.
- Signing/notarization or future App Store requirements change the release target.
- A pinned framework release no longer works with the pinned Node/Rust toolchain.
