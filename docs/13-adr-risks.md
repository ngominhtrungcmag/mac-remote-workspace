# D13 — Architecture Decision Records, Risks and Spikes

## 1. Accepted/proposed ADRs

| ADR | Status | Decision | Rationale | Revisit trigger |
|---|---|---|---|---|
| ADR-001 | Superseded | Previous prototype used React+Tauri+Rust | Prototype established domain and security behavior | Superseded by ADR-010 |
| ADR-002 | Proposed | Local-first no cloud/backend | Simpler privacy and offline inventory | Team sync product demand validated |
| ADR-003 | Proposed | Secrets in macOS Keychain, metadata SQLite | Separation of secret/data and OS integration | Security audit issues |
| ADR-004 | Superseded | libssh2 / Rust ssh2 for the historical prototype | Feasibility evidence is retained; it is not a native app dependency decision | Reconsider only through a new native architecture ADR |
| ADR-005 | Proposed | RDP through external client in V1, FreeRDP embedded V2 | Deliver safe MVP without native rendering risk | Embedded spike passes early |
| ADR-006 | Proposed | No terminal recording/default telemetry | Privacy by default, reduce risk | Explicit opt-in feature demand |
| ADR-007 | Superseded | Typed Tauri IPC and Rust policy engine for the historical prototype | Native app uses typed in-process Swift services | Reconsider only through a new architecture decision |
| ADR-008 | Proposed | Direct-download Developer ID notarized first | Avoid App Store sandbox promise | App Store distribution request |
| ADR-009 | Proposed | AGPLv3 or Apache-2.0 must be selected before public code publication | OSS strategy impacts inbound contributions/commercial use | Maintainer decision |
| [ADR-010](adr/native-swift-target.md) | Accepted | Native macOS SwiftUI/AppKit, Swift AppCore, SQLite, Apple Keychain, and macOS system services are the sole product implementation target | Native menus, lifecycle, accessibility, Keychain and platform services fit the macOS-only product | Revisit only if a new product decision changes the target platform |

**ADR-009 note:** Propose **Apache-2.0** as default if broad adoption, integration and low friction are primary. If copyleft enforcement is deliberate project objective, seek legal review before choosing AGPLv3; cannot treat both as equivalent. No license file should be generated with an undecided license.

## 2. Technical risk register

| ID | Risk | Likelihood | Impact | Mitigation | Owner/Exit |
|---|---|---|---|---|---|
| R-01 | Native OpenSSH transport or packaging limitations | Medium | High | SP-01 validate system client, host trust, PTY, SFTP, cancellation, and packaging | Native transport lead; G1 |
| R-02 | SSH host key verification bypass through UI flow | Low–Med | Critical | Swift AppCore policy and adversarial tests | Security; SEC-T03 |
| R-03 | Keychain errors/locked access disrupt login | Medium | High | SP-02 and recovery UX | Platform; G2 |
| R-04 | Interrupted SFTP overwrites remote target | Medium | Critical | temp/verify/rename; crash tests | SFTP; G3 |
| R-05 | External RDP client integration varies by OS/version | High | Medium | SP-03, fallback copy endpoint | Platform; G4 |
| R-06 | FreeRDP embed performance/input issues | High | High | Separate SP-04, P2 only | Platform; G5 |
| R-07 | Unsupported macOS oldest target | Medium | Medium | CI clean-machine test matrix | Release |
| R-08 | Network dead sessions leak child processes or descriptors | Medium | High | cancellation, bounded buffers, process reaping, soak tests | Native runtime |
| R-09 | Dependency vulnerability/unsafe plugin | Medium | High | audit, lockfile, SBOM, plugin after P2 | Security |
| R-10 | Feature parity chase vs Termix | High | Product high | focus context-first workflows | Product |
| R-11 | Security-scoped local path inaccessible | Medium | Medium | sandbox strategy, OS picker/bookmarks | UX/Platform |
| R-12 | Secret leaked through diagnostics/clipboard | Medium | Critical | structured redaction, test sentinels | Security |

## 3. Feasibility spike protocols

### SP-01 — Native SSH/SFTP transport (2–4 developer-days estimate)

Validate the selected macOS system OpenSSH transport: SSH agent and supported key-file auth, strict host-key verification before authentication, PTY, SFTP listing/transfer/cancellation, supported CPU architectures, and signed-app feasibility. Record reproducible commands and a `PASS / BLOCKED` decision. Do not add a Rust SSH dependency or a general shell-command bridge.

### SP-02 — Keychain and permissions (1–2 days)

Create/select/delete Keychain item with access control, locked/unavailable behavior; integrate UserSelected file picker; sign/notarize sample. Verify DB/logs contain no secret. Compare sandbox/non-sandbox distribution assumptions.

### SP-03 — RDP external launcher (1–3 days)

Survey installed supported RDP clients on macOS; verify launch method/API/sanitized profile, process argv, cleanup temp file, fallback copy endpoint. Explicitly distinguish `launched` and `connected`.

### SP-04 — FreeRDP embedded (5–10+ days, P2)

Prototype sidecar/native engine with Swift/AppKit host surface or other credible integration approach. Validate security (TLS/NLA), keyboard mapping, HiDPI, resizing, clipboard, multiple displays, memory/latency, signing/notarization. No version promise until this passes.

## 4. Decision logs template

```markdown
# ADR-NNN: Short title
Status: Proposed | Accepted | Rejected | Superseded
Date:
Context:
Decision:
Options considered:
Security/privacy effects:
Consequences:
Validation evidence:
Review date:
```

## 5. Assumptions to validate with real users

- IT users prefer client-local credential storage to synced vault; validate across 5–10 user interviews.
- Context-based production warning reduces mistakes rather than alert fatigue; test task completion in usability study.
- SFTP dual-pane handles 80% routine transfers; measure actual task patterns.
- External RDP launcher is acceptable in V1; beta feedback to validate before spending embedded RDP effort.
- macOS-first adoption enough to justify native focus; research Windows demand with GitHub issues/polls.


