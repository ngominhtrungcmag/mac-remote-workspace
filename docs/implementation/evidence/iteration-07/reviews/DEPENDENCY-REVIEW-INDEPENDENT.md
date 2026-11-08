# Independent dependency review: libssh2 and OpenSSL

Review date: 2026-10-28  
Target checkout: `mrw-release-dependencies`, commit `d6b3d4f38848f45db667c1b6303f4658dedfbb8c`  
Requirements: `SEC-T08`, `R-09`, `US-016`, `NFR-008`, `NFR-011`, `TC-020`  
Scope: read-only review of `docs/implementation/evidence/iteration-07/DEPENDENCY-REVIEW.local.md`, both Cargo manifests/lockfiles, the SSH/SFTP Rust call paths, and the exact cached `libssh2-sys 0.3.3` source. No target-worktree files were changed.

## Summary

The recorded lockfile identities and the three cited libssh2 fixes are confirmed, but the evidence note should distinguish a fixed Cargo crate version from the newer unpatched C source actually locked: the Rust crate `libssh2-sys 0.3.3` includes several earlier fixes, while the exact embedded C source still lacks the upstream fixes for CVE-2026-66032, CVE-2026-66033, and CVE-2026-66035. I also found CVE-2026-66034 in the vendored publickey parser; the current Rust application does not call that publickey subsystem, so its runtime reachability is not established. The OpenSSL 3.6.3 source is opt-in for vendored builds, the fixed OpenSSL patch is available upstream, but no matching fixed `openssl-src` crate was published at review time and the final app's actual crypto linkage remains unverified.

## Evidence and findings

### libssh2

Both Cargo lockfiles resolve `ssh2 0.9.6` → `libssh2-sys 0.3.3`; the locked checksum (`0f5eb742…8372c1cd`) matches the cached `.crate` archive. Its embedded header says `LIBSSH2_VERSION "1.11.1_DEV"`. Crates.io's version API showed `libssh2-sys 0.3.3` as latest on 2026-10-28. Upstream libssh2's release page still lists 1.11.1 as its latest release, while upstream `master` identifies itself as `1.11.2_DEV`; therefore there is no official released libssh2 version number that can yet be cited as containing the newer fixes. The libssh2-sys 0.3.3 source is not identical to an upstream release tarball, so the source content and checksum matter more than the embedded version string.

The Rust `ssh2-rs` maintainers' [PR #359](https://github.com/rust-lang/ssh2-rs/pull/359) records that the 0.3.3 crate includes backports for CVE-2026-55200, CVE-2026-55199, and CVE-2025-15661. Source inspection confirms the packet-length cap in `transport.c`, the `_libssh2_get_string()` error checks in the `SSH_MSG_EXT_INFO` parser, and the bounds-aware SFTP symlink parser. These three findings should not be counted as still-unfixed in this exact locked crate.

| Finding | Exact locked-source evidence and app path | Risk assessment |
|---|---|---|
| CVE-2026-66032 | In `libssh2/src/sftp.c`, `sftp_open()` frees its response buffer but does not set the pointer to `NULL`; upstream [commit 5e47761](https://github.com/libssh2/libssh2/commit/5e4776146552d898b9c0e1b313cd093fa8dc92d0) adds that guard. The app calls SFTP `open` for downloads and upload temp files (`apps/desktop/src-tauri/src/adapters/sftp.rs`). | Confirmed vulnerable source on a reachable SFTP operation. It requires a server-controlled SFTP response after SSH authentication; host-key verification reduces who can supply that server but does not fix a compromised or intentionally trusted server. Double-free/memory-corruption impact is confirmed upstream; no app exploit was attempted. |
| CVE-2026-66033 | `libssh2/src/openssl.c` still calculates AES-GCM `cryptlen` before bounds checks and relies on assertions; [commit a2ed82d](https://github.com/libssh2/libssh2/commit/a2ed82d40964bbc0d64cd717aa0a5a892117d2e6) replaces this with runtime checks. | A malicious server can reach cipher negotiation before user authentication. Upstream describes a client crash/DoS; code-execution impact is not established for this app. Host-key verification happens too late to mitigate handshake parsing. |
| CVE-2026-66035 | `libssh2/src/transport.c` still computes `decrypt_size = p->total_num - mac_len - 4` without the minimum packet-size guard; [commit 42e33d8](https://github.com/libssh2/libssh2/commit/42e33d81577ed4b95d4b4f6f845e5ee8efe5eeb4) adds it. | Malicious Encrypt-then-MAC negotiation can reach the parser before authentication. Treat the undersized-packet/heap-corruption defect as real; the published code-execution scenario is allocator/platform-specific and has not been demonstrated on macOS arm64/x86_64. |
| CVE-2026-66034 | Exact `publickey.c` still lacks the comment-length bound added by upstream [commit a13bb6c](https://github.com/libssh2/libssh2/commit/a13bb6c773f0d55ad1628cede57e99803cd898d9). | The code is in `libssh2_publickey_list_fetch()`, the legacy publickey management subsystem. No caller for this subsystem appears in the app or feasibility Rust source, and `ssh2-rs` does not expose it as the ordinary `userauth_pubkey_file` path. Treat as a package/source finding pending final linked-symbol/reachability inspection, not as confirmed app-path exposure. |
| CVE-2026-7598 (older username-length issue) | `userauth.c` retains `username_len + 40`; both app and feasibility harness validate credentials immediately before `userauth_password()`. App validation rejects usernames over 256 bytes; the existing trust-policy test covers over-limit input. | The application guard mitigates the password-auth call path. It does not patch the dependency, and the proof is limited to call sites inspected; keep the boundary test in the release evidence. |

The most conservative minimal product fix is to update the `libssh2-sys` lock resolution when a published crate carries the missing 66032/66033/66035 patches. At review time no such newer crates.io version existed. If a release must be prepared before then, the practical fallback is a coordinator-owned `libssh2-sys` patch/fork pinned to a reviewed source revision and containing those upstream changes; do not replace the embedded C tree with unpinned `master`. Build/test the Rust wrapper against that source and preserve the exact source revision/hash in the SBOM. Include the publickey fix if retaining that C API in the final binary.

### OpenSSL

The lockfiles contain `openssl-sys 0.9.117` and `openssl-src 300.6.1+3.6.3`. `vendored-openssl` is opt-in in the Cargo manifests; the feasibility cross-build script enables it, while the normal feature set does not. Cargo tree confirmed the `openssl-src` edge when the feasibility feature is enabled. The existing evidence says an arm64 feasibility test executable linked Homebrew OpenSSL 4.1.0, which is evidence about that test executable only, not the distributable app.

OpenSSL's official advisory lists 3.6.0 through 3.6.4 as affected by CVE-2026-54872 and 3.6.5 as fixed; [OpenSSL 3.6.5 release notes](https://www.openssl-library.org/news/openssl-3.6-notes/) also list the security fixes shipped since 3.6.3. The 3.5.9 LTS line is also fixed for this CVE and is supported through 2030-04-08, while the 3.6 line is scheduled to end support on 2026-11-01 ([OpenSSL release strategy](https://www.openssl-library.org/policies/releasestrat/), [3.5.9 notes](https://www.openssl-library.org/news/openssl-3.5-notes/)). Same-major OpenSSL releases guarantee API/ABI compatibility; this makes a fixed 3.x patch/minor line preferable to an unreviewed major jump.

The official crates.io version API showed no `openssl-src` package for OpenSSL 3.6.5 or 3.5.9 at review time (latest 3.6 source wrapper: `300.6.1+3.6.3`; latest 3.5 wrapper: `300.5.5+3.5.5`). `openssl-src 400.0.2+4.0.3` exists, but the locked `openssl-sys 0.9.117` declares the optional source dependency as `openssl-src = 300.2.0`; Cargo's semver range excludes 400.x. Switching to OpenSSL 4 therefore needs a separately reviewed binding/dependency update and compatibility build. The smallest long-term path is to use a newly published `openssl-src` wrapper for a fixed, supported OpenSSL 3.x release (prefer 3.5.9 LTS if it remains the chosen support line), then update both lockfiles and rebuild the x86_64 vendored path.

Reachability is not established for CVE-2026-54872 in the product binary. OpenSSL describes a timing leak during ECDSA/SM2 signing on non-NIST curves; NIST P-256/384/521 are explicitly unaffected. The inspected libssh2 SSH key-type mapping exposes NIST ECDSA types, but the app accepts user-selected private-key files and no runtime test proves how unusual EC keys are rejected before signing. This is a lower and narrower concern than the libssh2 packet flaws, but the stale vendored source still needs replacement or an explicit, evidence-backed reachability disposition before SEC-T08 clearance.

## Smallest practical remediation

1. Keep `ssh2 0.9.6`; it already accepts the `libssh2-sys 0.3.x` dependency family. Update only the resolved sys crate when a published fixed version exists. If release timing prevents that, use a pinned local/fork patch with the three reachable upstream C fixes and a reviewable provenance record.
2. Keep `vendored-openssl` opt-in. When the Rust source wrapper publishes a fixed OpenSSL 3.x source, bump the wrapper through the supported `openssl-sys` dependency range and update both Cargo locks. If validation cannot wait, use an externally built, pinned OpenSSL 3.5.9/3.6.5 SDK only for compile feasibility; that does not clear runtime linkage or bundle/signing requirements.
3. Do not infer final crypto versions from Cargo.lock alone. Inspect the actual signed app executable and bundled dylibs for each architecture, record the dependency source/version in the SBOM, and verify that the linked OpenSSL is the intended fixed build.

## Feasible validation and current limits

Already performed read-only checks:

- `cargo tree --locked --manifest-path apps/desktop/src-tauri/Cargo.toml -i ssh2` — confirmed the `ssh2 0.9.6` application dependency.
- `cargo tree --locked --manifest-path tests/feasibility/Cargo.toml -i openssl-src --features vendored-openssl` — confirmed the vendored source path resolves to 3.6.3.
- Compared the locked libssh2-sys checksum with the cached crate archive; inspected relevant C functions and Rust SSH/SFTP callers.
- Queried official upstream release/commit pages and crates.io version metadata on 2026-10-28.

Not run for this review: builds, test suites, sanitizers, malicious-server regression tests, app-bundle link inspection, signing, notarization, or Gatekeeper checks. Feasible follow-up is to run the existing disposable SSH/SFTP integration and trust-policy suites on arm64 plus the x86_64 cross-build after dependency remediation; add isolated malformed-packet regressions for SFTP `OPEN`, AES-GCM, and EtM under ASan/UBSan. Then inspect each architecture's app binary with `otool -L`, derive the SBOM from the built artifact, and repeat after code signing. Existing OpenSSH fixtures do not appear to send these malformed packets, so a dedicated local protocol fixture or C regression test is required. Never run the hostile fixtures against a production server.

## SEC-T08 blocker and risks

`SEC-T08` remains a release blocker: three lock-resolved libssh2 defects remain in active pre-auth/SFTP code paths, no newer fixed `libssh2-sys` crate was available at review time, and the vendored OpenSSL source is older than an upstream fixed release. In addition, the product binary's exact OpenSSL linkage and final SBOM have not been verified. CVE-level memory-corruption claims describe upstream vulnerability conditions, not proof of exploitation against this app; the OpenSSL side-channel reachability and final binary's linked dependencies are unresolved. This review is evidence for remediation planning only and is not release clearance.

## Sources

- Upstream [libssh2 releases](https://github.com/libssh2/libssh2/releases) and [current version header](https://github.com/libssh2/libssh2/blob/master/include/libssh2.h).
- Upstream fixes: [CVE-2026-66032](https://github.com/libssh2/libssh2/commit/5e4776146552d898b9c0e1b313cd093fa8dc92d0), [CVE-2026-66033](https://github.com/libssh2/libssh2/commit/a2ed82d40964bbc0d64cd717aa0a5a892117d2e6), [CVE-2026-66035](https://github.com/libssh2/libssh2/commit/42e33d81577ed4b95d4b4f6f845e5ee8efe5eeb4), [CVE-2026-66034](https://github.com/libssh2/libssh2/commit/a13bb6c773f0d55ad1628cede57e99803cd898d9), and Rust wrapper [PR #359](https://github.com/rust-lang/ssh2-rs/pull/359).
- Official [Ubuntu libssh2 advisory USN-8722-1](https://ubuntu.com/security/notices/USN-8722-1) for stated impact/attack context.
- OpenSSL [3.6 vulnerabilities](https://www.openssl-library.org/news/vulnerabilities-3.6/), [3.6 release notes](https://www.openssl-library.org/news/openssl-3.6-notes/), [3.5 release notes](https://www.openssl-library.org/news/openssl-3.5-notes/), and [release strategy](https://www.openssl-library.org/policies/releasestrat/).
- Official registry metadata queried on review date: [libssh2-sys](https://crates.io/api/v1/crates/libssh2-sys), [ssh2](https://crates.io/api/v1/crates/ssh2), [openssl-src](https://crates.io/api/v1/crates/openssl-src), and [openssl-sys](https://crates.io/api/v1/crates/openssl-sys).
