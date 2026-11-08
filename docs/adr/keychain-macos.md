# ADR-SP-02: macOS Keychain probe and release target

> **Historical Rust feasibility probe.** This records a standalone Keychain harness, not a Native Swift app credential implementation or acceptance result. Use ADR-010 and TASK-01 for current app work.

**Status:** Proposed  
**Date:** 2026-10-27  
**Requirements:** SP-02, FR-004/025, SEC-T02/T07/T08, TC-003/018/020, NFR-004/011  
**Scope:** `tests/feasibility/src/bin/keychain_probe.rs`, `tests/feasibility/Cargo.toml`, this ADR  
**Out of scope:** app credential storage, access-control UX, SQLite schema, signing or notarization

## Decision

Use Apple Security.framework through `security-framework` 3.7.0 generic-password APIs for the eventual macOS secret-store adapter. Persist only an opaque reference in metadata; do not add a plaintext fallback. Keep the first release target as a direct-download Developer ID-signed, hardened-runtime and notarized macOS app, as proposed by D09/D13. Signing remains a release gate.

## Keychain probe

Command: `cargo run --manifest-path tests/feasibility/Cargo.toml --locked --bin keychain_probe`  
Result on macOS 27.2 arm64: **passed**. The Rust probe created one item under random service/account identifiers, retrieved and compared only its own in-memory canary, checked the canary bytes were absent from a temporary SQLite database and redacted log containing only the reference, deleted the item, and verified `errSecItemNotFound`. An RAII guard retries deletion on early return or unwind. Output contains only a status line; the canary itself is never printed. No OS access prompt appeared and no prompt behavior was suppressed.

The SQLite/log check is a harness self-check, not evidence about an application database or logger; neither exists in this slice. The probe does not query other Keychain items or inspect signing identities/private keys.

Apple documents Keychain Services as the API for storing small sensitive values; the Rust wrapper exposes [`set_generic_password`](https://docs.rs/security-framework/3.7.0/security_framework/passwords/fn.set_generic_password.html), [`generic_password`](https://docs.rs/security-framework/3.7.0/security_framework/passwords/fn.generic_password.html), and [`delete_generic_password`](https://docs.rs/security-framework/3.7.0/security_framework/passwords/fn.delete_generic_password.html).

## Signing and notarization status

Xcode command-line tools 27.1 and the `notarytool`/`stapler` commands are available. No app bundle was built in this transport slice, no signing identity or private key was inspected, and no authorized signing/notary profile was used. Therefore signing, notarization, stapling, hardened-runtime compatibility, Gatekeeper launch, x86_64 packaging, and sandboxed distribution are **unverified**. Keep the first distribution target as Developer ID direct download; do not claim a signed/notarized artifact until it is tested with authorized credentials on a built app.

The Keychain result verifies only a local generic-password round trip in the current user context. Denied/locked access, access-control prompts, app restart/rebind behavior, shared credential cleanup, and app-level log/database redaction remain for the credential vertical slice.
