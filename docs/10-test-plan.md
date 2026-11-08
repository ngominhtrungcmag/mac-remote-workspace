# D10 — Test Strategy, Test Matrix and Quality Gates

## 1. Testing strategy

**Risk-based testing**: first focus host trust, secrets, file writes, session lifecycle; then reliability, performance, accessibility. Units test pure state machines & validation; integration test actual SSH/SFTP service with ephemeral containers; E2E test packaged macOS app on clean machines. RDP external test manual+automation where possible; RDP embedded requires separate validation program P2.

## 2. Test environments

| Environment | Mục tiêu |
|---|---|
| macOS arm64 current supported | Main dev + signed DMG smoke |
| macOS x86_64 supported | Intel compatibility, package smoke |
| macOS oldest supported version (macOS 14+) | SwiftUI, Keychain, system OpenSSH, binary compatibility |
| Ubuntu OpenSSH test container | SSH auth/key/PTY & SFTP lifecycle |
| Host with modified SSH host key | MITM/mismatch rejection |
| Network proxy simulator | DNS fail, TCP drop, RTT/jitter/loss |
| SFTP permission fixture | Read-only folders, symlinks, collision, disk full |
| Windows Server RDP test host | External launcher profile (P1) |

Version targets are candidates, not verified compatibility claims. Maintain pinned runner/container image versions in CI.

## 3. Unit tests — major groups

- `HostInput`: empty, invalid IP/FQDN, 0/65536 port, Unicode host label, oversized strings, environment enum.
- `TrustDecision`: unknown -> pending, mismatch -> fail, stale nonce -> fail, user reject -> closed.
- `SessionReducer`: all legal/illegal transitions, reconnect, duplicate close.
- `Transfer`: cancel at each state, rename fallback, collision and unexpected file size.
- `CredentialRefs`: deleting shared creds, orphan detection, DB-rebind logic.
- `ExportSanitizer`: ensures metadata-only whitelist; fuzz secret-like fields; roundtrip version.
- `NativeSSHSessionCoordinator` and `SSHOutputBuffer`: stale session cancellation, bounded output, and observer cleanup.

## 4. Integration tests — acceptance table

| Test ID | Scenario | Expected |
|---|---|---|
| TC-001 | Add/edit/delete host | DB correct; constraints applied |
| TC-002 | Query host inventory 1k/10k | Search result correct, target budget logged |
| TC-003 | Save credential → inspect SQLite/export | Secret absent, Keychain item exists |
| TC-004 | Unknown SSH host key | Requires user decision before auth |
| TC-005 | SSH host key mismatch | Hard block, no auth attempt |
| TC-006 | SSH password and public-key login | Correct result, error codes distinct |
| TC-007 | Parallel shells and PTY resize | No hang/leak, resize passes |
| TC-008 | FTP-like SFTP listing incl. Unicode/symlink | Safe display/path handling |
| TC-009 | Upload/download 10MB/1GB incl cancel | Verified bytes, no false success |
| TC-010 | Overwrite with collision and interrupted transfer | Explicit policy, source preserved |
| TC-011 | Relaunch workspace | Layout restored, no auto-login by default |
| TC-012 | Export/import metadata | No secrets, duplicate review, transaction |
| TC-013 | UI keyboard-only/VoiceOver | Keyboard flows success |
| TC-014 | RDP launcher no client installed (P1) | Useful fallback; no password in argv |
| TC-015 | Local SSH port forwarding (P1) | Loopback only; teardown cleans listener |
| TC-016 | App quit with running upload | Prompt, cancel cleanup, no leaked workers |
| TC-017 | Host DB migration interruption | Rollback/recovery without silent data loss |
| TC-018 | Error redaction test | No credentials/terminal transcript logged |
| TC-019 | URL/terminal escape injection | Disallowed schemes/OSC clipboard blocked |
| TC-020 | Notarized release on clean Mac | Gatekeeper opens without bypass |
| TC-021 | DNS/TCP/SSH connection diagnostics (P1) | Errors localized to layer; no secrets in report |
| TC-022 | Command snippets require confirmation (P1) | No commands run at connect/import automatically |
| TC-023 | Shared credential unlink and delete | Shared secret not deleted while referenced; confirm effects |
| TC-024 | Reconnect storm throttling | Exponential backoff/cap/cancel, no command replay |

## 5. E2E user journeys

E2E-A: onboarding → add Ubuntu host → verify SHA256 → SSH → SFTP download → close session.

E2E-B: production host → upload file conflict → cancel → verify original file unchanged.

E2E-C: offline launch → browse host list → connect timeout → troubleshooting hint → reconnection manual.

E2E-D (P1): add Windows host → select external RDP client → launch safely → verify process argv sanitized.

E2E-E: keyboard-only navigation, reduce motion, VoiceOver labels, light/dark theme and scaling.

## 6. Performance experiments

- Cold start: 30 runs on clean cache/warm cache separately; p50/p90, RAM baseline.
- Terminal stress: 1/5/10 concurrent SSH shells; output sustained 1–5 MB/min per session; CPU/RAM, missing bytes/latency.
- Transfer: files 0 bytes, 4KB, 100MB, 1GB; direct LAN, 100ms RTT, 2% loss; throughput/cancel reliability.
- Inventory: 1k, 10k hosts seed; search/scroll memory and frame latency.
- App soak: 8h with connection open/close cycles and transfers; file descriptor leak check.

No claim of meeting a budget before results are recorded. Reference hardware and network constraints must be included with every public benchmark.

## 7. Security/fuzz testing

- Fuzz hostname, typed Swift inputs, terminal escape sequences, remote filename, import manifest.
- Simulated compromised host with key rotation; verify block and audit.
- OS Keychain denied/locked, corrupted DB, missing or incompatible system OpenSSH executable.
- Secret search in DB/log/export/argv/crash; use sentinel canary credentials, never real passwords.
- Verify update package signature and negative tampered package test.

## 8. CI pipeline test gates

PR: Swift package build and tests, macOS app build, migration and local OpenSSH integration where available, dependency/license scan, resolved-package verification, build artifact.

Nightly: macOS app UI smoke, SSH/SFTP matrix, soak lite, dependency advisory scan.

Release candidate: full native UI/protocol coverage, notarization, clean-machine smoke, performance report, threat model review, release notes and SBOM.

## 9. Definition of Done / pass criteria

- Every P0 FR has at least 1 automated test or documented manual acceptance (security-critical MUST automated).
- No open P0/P1 blocker bug involving data loss, auth bypass, host key mismatch, secret exposure, crash during transfers.
- Tests for false-positive completion and cancel behavior passed.
- App opens on two CPU architectures, signed/notarized artifact verified.
- User documentation and recovery instructions published.


