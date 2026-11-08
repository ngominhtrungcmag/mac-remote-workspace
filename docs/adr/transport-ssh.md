# ADR-SP-01: SSH/SFTP transport feasibility

> **Historical Rust transport spike.** The Rust `ssh2`/libssh2 decision and evidence apply only to the prototype harness. ADR-010 selects a Native Swift app target; validate native SSH/SFTP behavior independently before implementation or release claims.

**Status:** Proposed for the first adapter, conditional on packaging review  
**Date:** 2026-10-27  
**Requirements:** SP-01, FR-005–010, SEC-T03/T05, TC-004–010, NFR-004/005/011  
**Scope:** `tests/feasibility/**`, `tests/integration/ssh-sftp/**`, this ADR  
**Out of scope:** product SSH/session implementation, app manifests, UI, production hosts

## Decision

Use `ssh2` 0.9.6/libssh2 for the first Rust SSH/SFTP adapter prototype. Keep every blocking session on a dedicated worker in the app. The test harness now probes cooperative cancellation at a chunk boundary, but does not establish product cancellation or in-flight blocking-call interruption. Pin direct dependencies in the standalone crate and its `Cargo.lock`:

| Crate | Pin | Use |
|---|---:|---|
| `ssh2` | 0.9.6 | SSH, host-key hash, PTY, SFTP |
| `base64` | 0.23.1 | OpenSSH-style SHA-256 fingerprint text |
| `uuid` | 1.29.0 | Disposable fixture IDs |
| `security-framework` | 3.7.0 | macOS Keychain canary probe |
| `rusqlite` | 0.37.0 | Temporary reference-only SQLite check |
| `tempfile` | 3.27.0 | Temporary probe files |

The crate resolves `libssh2-sys` 0.3.3. Exact transitive versions are fixed by `tests/feasibility/Cargo.lock`.

## Evidence

On macOS 27.2 arm64, Xcode 27.1, Rust 1.99.0 and OpenSSH 10.5p1, `tests/integration/ssh-sftp/run-local.sh` passed ten checks against a generated OpenSSH service bound only to `127.0.0.1`:

- Unknown key returns a trust challenge; rejecting it and presenting a mismatched known fingerprint both leave the authentication callback untouched.
- After a fresh fingerprint is pinned, the generated key authenticates. A separate non-authorized key produces an authentication failure.
- An interactive shell accepts a PTY, a 132×40 resize is reflected by `stty size`, and a result line is received separately from the echoed command.
- Ten authenticated PTY channels on ten SSH connections stay open at once and each returns its own result marker.
- SFTP creates, writes, reads and lists a fixture file. `CREATE|EXCLUSIVE` rejects a pre-existing path and its bytes remain unchanged.
- A 100 MiB payload is streamed in bounded 64 KiB chunks, then its size and every byte are verified after readback.
- A test-only worker writes 64 KiB to an exclusive temporary path, reports partial progress, and waits at a chunk boundary. The test confirms no terminal event was sent, requests cancellation, then verifies `CANCELLED`, worker exit within 2 seconds, temp-file removal, and unchanged pre-existing destination bytes. This proves cooperative cancellation between SFTP calls only; it does not interrupt an in-flight blocking `write_all`.
- Before Rust tests run, the fixture validates its generated key against the same server using OpenSSH with a generated known-hosts file and `StrictHostKeyChecking=yes`.

The sshd runs as the current unprivileged account and is not chrooted or otherwise OS-sandboxed. It is disposable loopback infrastructure for trusted test code only. Generated host/client keys, authorized keys, config, logs and remote test files live in the user-owned macOS `TMPDIR`; the fixture trap shuts down sshd and removes that directory. It does not use `sudo`, the user's SSH agent, existing credentials, or production endpoints.

The temporary `sshd_config` exempts only `127.0.0.1` from OpenSSH per-source penalties because the host-trust cases intentionally close pre-authentication sessions; the fixture does not alter system SSH configuration. OpenSSH documents that `PerSourcePenaltyExemptList` is the address list excluded from those penalties ([`sshd_config(5)`](https://man.openbsd.org/sshd_config#PerSourcePenaltyExemptList)).

The first attempt put the fixture under world-writable `/tmp`; OpenSSH `StrictModes yes` correctly rejected the authorized-key path. Moving the fixture under the user-owned macOS `TMPDIR` fixed the server setup without relaxing `StrictModes`.

The test key files are ECDSA PEM because `ssh2::Session::userauth_pubkey_file` accepts PEM-encoded private keys. This validates that documented path only; it does not establish support for OpenSSH-format Ed25519 keys or encrypted keys/passphrases.

The pinned [`Session` documentation](https://docs.rs/ssh2/0.9.6/ssh2/struct.Session.html#method.set_blocking) states that blocking calls wait for I/O and that related session objects are mutex-synchronized; [`set_timeout`](https://docs.rs/ssh2/0.9.6/ssh2/struct.Session.html#method.set_timeout) bounds blocking-call wait time. The probe therefore cancels between blocking SFTP calls and does not claim another thread can interrupt one already in flight.

The Tauri shell also cross-built as an unsigned x86_64 app bundle with `pnpm tauri build --target x86_64-apple-darwin --bundles app --no-sign`; `file` and `lipo -info` confirmed an x86_64 Mach-O. This bundle contains no SSH adapter and was not run on Intel hardware. The SSH/SFTP feasibility crate did not cross-compile: `cargo test --manifest-path tests/feasibility/Cargo.toml --locked --target x86_64-apple-darwin --no-run` stopped in `openssl-sys` because this host has no x86_64 OpenSSL SDK/sysroot and `pkg-config` is not configured for cross-compilation. This is an environment dependency gap, not a demonstrated libssh2 incompatibility.

## Alternative reviewed: `russh`

`russh` 0.65.0 was reviewed at source/documentation level, not added to the crate or run against the fixture. Its async client requires a `Handler::check_server_key`; the documented default rejects keys, and the callback decides trust after key-exchange signature verification. The client API includes PTY shell examples. SFTP is a separate `russh-sftp` crate (3.0.1), with a client implementation. This may fit cancellation and async worker orchestration better, but requires Tokio and a second SFTP integration. No comparative performance or signed-build result is claimed.

Sources: [`ssh2::Session`](https://docs.rs/ssh2/0.9.6/ssh2/struct.Session.html), [`russh::client::Handler`](https://docs.rs/russh/latest/russh/client/trait.Handler.html), [`russh` client module](https://docs.rs/russh/latest/russh/client/), [`russh-sftp` client module](https://docs.rs/russh-sftp/latest/russh_sftp/client/).

## Gate and revisit conditions

This is a **local transport pass only**, not a full SP-01 or G1 pass. Keep `ssh2` for the first adapter unless the signed/hardened build fails, key-format coverage blocks supported users, or worker cancellation proves unsafe. Evaluate `russh` on the same fixture if one of those triggers occurs.

Not exercised: password or SSH-agent authentication, encrypted/private-key passphrase handling, x86_64 SSH/SFTP runtime, signed/hardened/notarized artifacts, interruption of an in-flight blocking `ssh2` write, disconnect during transfer, 100 ms RTT behavior, atomic rename guarantees, and a wider SSH algorithm/server matrix. The chunk-boundary cancellation, 100 MiB, and ten-session checks establish only local fixture behavior; they are not throughput, latency, soak, or production worker lifecycle results.
