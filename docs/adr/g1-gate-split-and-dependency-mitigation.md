# ADR-G1: Gate G1 Split (G1-Local vs. G1-Release) and Native Dependency Mitigation

> **Historical feasibility evidence.** The local GO result below covers the prior Tauri/Rust/libssh2 prototype only. It does not pass Native Swift transport, Keychain, P0, or release gates. Apply the gate split only as release planning structure; rerun native evidence against ADR-010.

**Status:** Accepted (User-authorized scope decision)  
**Date:** 2026-10-27  
**Requirements:** Task 00, SP-01, SP-02, FR-004–011, SEC-T01–T08, NFR-004/005/008/011/014  
**Scope:** `docs/adr/g1-gate-split-and-dependency-mitigation.md`, `tests/feasibility/**`, `tests/integration/ssh-sftp/run-local.sh`, `apps/desktop/**`, `docs/implementation/**`

## Context

In the initial Task 00 baseline, Gate `G1` coupled local technical feasibility (SSH/SFTP transport, host-key trust before auth, PTY, cancellation, Keychain persistence, SQLite schema/migrations, cross-compilation) with external release prerequisites (Apple Developer ID signing identity, notarization profile, physical Intel `x86_64` hardware runtime, and clean-Mac Gatekeeper machines). Because those external distribution credentials and hardware environments are not attached to the local development machine, keeping a monolithic `G1: NO-GO` blocked 100% of product implementation across Iterations 01–06.

Additionally, native dependency review identified:
1. `libssh2-sys` 0.3.3 embeds libssh2 `1.11.1_DEV`, where `userauth_password()` computes `username_len + 40` without upstream commit `256d04b`/`2fedc0b` input length caps.
2. Opt-in `vendored-openssl` for `x86_64` cross-compilation compiles `openssl-src` `300.6.1+3.6.3` (predating upstream 3.6.5 fixes).

## Decision

1. **Split Gate G1 into `G1-Local` and `G1-Release`:**
   - **`G1-Local` (Local Technical & Security Feasibility Gate — GO):** Covers reproducible Tauri 2 + React 19 + Rust + SQLite 3.53.2 build on macOS arm64, `x86_64` cross-compile check, strict pre-auth SSH host-key verification, public-key (unencrypted + passphrase-encrypted PEM), disposable `ssh-agent`, password FFI boundary guard, 10 concurrent PTY sessions, 100 MiB SFTP streaming, chunk-boundary and blocked-native-write cancellation, unrecovered disconnect exit and temp-file reconciliation, fresh-process Keychain canary round-trip, and deterministic Keychain `OSStatus` error classification (`LockedOrUnavailable` / `AccessDenied` / `NotFound` with zero plaintext fallback).
   - **`G1-Release` (Distribution & Multi-Hardware Release Gate — Mandatory at Iteration 07):** Covers Apple Developer ID code signing, Hardened Runtime, notarization/stapling, clean-Mac Gatekeeper verification (`TC-020`), physical Intel `x86_64` and oldest-supported macOS runtime verification (`NFR-008`, `NFR-011`), and final native dependency clearance for distributed binaries (`SEC-T08`).
   - **Rule:** Passing `G1-Local` authorizes implementation of Iterations 01–06 on the local development machine. It never authorizes claiming a distributable signed beta or bypassing `G1-Release` in Iteration 07.

2. **Enforce Rust-Boundary Input Validation Before `libssh2` FFI:**
   - Every SSH username and password/passphrase reaching the Rust `SshTransport` adapter (and feasibility harness) must pass `validate_ssh_credentials`:
     - `username` must be non-empty, `<= 256` bytes (`MAX_SSH_USERNAME_BYTES`), and contain no ASCII control characters or NUL bytes.
     - `password` must be non-empty, `<= 1024` bytes (`MAX_SSH_PASSWORD_BYTES`), and contain no NUL bytes.
   - This prevents oversized local or imported usernames from reaching `libssh2_userauth_password_ex`.

3. **Keep `vendored-openssl` Opt-In Only for Compile Verification:**
   - Default builds do not enable `vendored-openssl` unless explicitly requested for `x86_64` cross-build verification. Distributing a binary with statically linked OpenSSL remains gated by `G1-Release` until an updated upstream source (`>= 3.6.5`) or verified system/framework crypto path is cleared.

4. **Deterministic Keychain Status Classification Without Prompt Suppression:**
   - Preserve all macOS Keychain access prompts. Map `errSecItemNotFound` (`-25300`) and `errSecInteractionNotAllowed` / `errSecNotAvailable` (`-25308`, `-25291`) to `CREDENTIAL_UNAVAILABLE`, and `errSecAuthFailed` / `errSecUserCanceled` (`-25293`, `-128`) to `CREDENTIAL_ACCESS_DENIED`. Never fall back to storing or reading secrets in SQLite or plaintext files.

5. **Unrecovered Outage & Stale Temp Cleanup Policy:**
   - Blocking `ssh2` operations run on dedicated worker threads with bounded socket/session timeouts (`<= 500 ms`–`5000 ms`) so a permanently severed connection exits within deadline (`<= 2 s`) and marks the transfer `failed` or `interrupted` (never `completed`).
   - Best-effort `unlink` of `.upload-<uuid>.part` runs immediately on cancellation/failure and during session/SFTP reconciliation when reconnecting to the target directory.

## Validation Evidence

- `tests/integration/ssh-sftp/run-local.sh`: **PASS** (12 SSH/SFTP integration tests + 6 trust/credential/keychain unit policy tests).
- `cargo run --manifest-path tests/feasibility/Cargo.toml --locked --bin keychain_probe`: **PASS**.
- `apps/desktop/src-tauri/capabilities/default.json` narrowed from `core:default` to `core:event:default`.
