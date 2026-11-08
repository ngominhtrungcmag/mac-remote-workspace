# HISTORICAL — TASK-00 Tauri Kickoff (Superseded)

> **Do not execute this task.** It documents the original Tauri/React/Rust bootstrap plan and is retained for project history only. ADR-010 and [TASK-01-NATIVE-CREDENTIALS.md](TASK-01-NATIVE-CREDENTIALS.md) define the active Native Swift target and next implementation slice.

You are the lead engineer for **Mac Remote Workspace**, an open-source, macOS-first, local-first desktop SSH/SFTP manager. The design baseline is indexed in `README.md` and `docs/README.md`, with project guidance in root `AGENTS.md`. The supplied source does not include separate `specs/`, `diagrams/`, or `checklists/` annex files; see `README.md`.

## One-task-only instruction
Implement **Iteration 00: feasibility + reproducible bootstrap**. Do NOT implement inventory/SSH UI/SFTP/RDP/cloud or describe them as completed.

## Work to perform
1. Read `README.md`, `AGENTS.md`, and D01/D02/D05/D06/D07/D08/D09/D12/D13/D16 at `docs/01-vision-prd.md`, `docs/02-srs.md`, `docs/05-architecture.md`, `docs/06-data-model.md`, `docs/07-protocols-sessions.md`, `docs/08-ipc-contracts.md`, `docs/09-security.md`, `docs/12-roadmap-backlog.md`, `docs/13-adr-risks.md`, and `docs/16-implementation-blueprint.md`. Produce a concise file `docs/implementation/00-feasibility.md` mapping technical risks to test results.
2. On the host Mac, collect environment versions (macOS, CPU architecture, Xcode CLI, Node, pnpm, Rust, Cargo); never print secrets or personally identifying environment variables.
3. Create reproducible minimal monorepo scaffold with `apps/desktop` (Tauri 2 + React 19 + TypeScript), root scripts, dependency lockfile and minimal GitHub Actions lint/test jobs. Prefer the official create-tauri-app template and pin versions after compatibility checks.
4. Verify `pnpm dev`, frontend build, `scripts/with-fixed-openssl.sh cargo test`, and package/bundle build **actually** run on the Mac. Record exact commands and output summary.
5. Build a disposable SSH/SFTP test fixture (local VM/container/OpenSSH). Investigate Rust `ssh2`/libssh2 and at least one alternative, with host-key fingerprint inspection, auth, PTY and SFTP feasibility. Do not connect to real/production servers.
6. Demonstrate a macOS Keychain proof through a small Rust adapter or test harness that stores/retrieves/deletes a unique canary; verify canary is not in SQLite or log. Preserve OS access prompts; never bypass them.
7. Document requirements and blockers for macOS Developer ID signing/notarization. If credentials are unavailable, do NOT falsely report notarization success.
8. Record ADRs for chosen Rust SSH implementation, secret store API, dependency version pins and release target. Scope all nontrivial risks for later work.

## Acceptance
- A working Tauri React app window on macOS, with reproducible build/install commands.
- Offline-safe fixture for later SSH/SFTP integration tests.
- Feasibility evidence of Keychain, SSH host identity, build compatibility and packaging prerequisites.
- Unit/integration tests for any introduced adapter.
- No broad Tauri shell/file permissions; no secrets in git/log/export; no disabled SSH host verification.
- Return `Summary`, `Files changed`, `Commands`, `Results`, `Screenshots`, `Blockers`, `ADR decisions`, `Next proposed issue`.

## Explicit out of scope
RDP, SFTP product UI, embedded terminal, cloud sync, automatic remote commands, AI features, full application implementation.
