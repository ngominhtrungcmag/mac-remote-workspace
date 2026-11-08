# D09 — Security Architecture & Threat Model

## 1. Security goals

- **Confidentiality:** mật khẩu, passphrase và key material không rò trong DB, export, log, crash report, argv.
- **Integrity:** host identity không bị thay đổi âm thầm; file transfers không ghi sai đích hoặc bị coi thành công giả.
- **Availability:** remote output lớn, queue dài hoặc network failure không làm treo app hay gây retry storm.
- **User agency:** thao tác nguy hiểm phải rõ host, path, environment và xác nhận.

## 2. Trust boundaries và STRIDE

| Boundary / asset | Threat | Mitigation | Test |
|---|---|---|---|
| SwiftUI → AppCore | Invalid or stale input, unauthorized operation | Typed service boundaries, repository lookups, state checks, confirmation challenges | SEC-T01 |
| Swift AppCore → Keychain | Secret leakage/replay | Apple Keychain Services, opaque references, minimal access, zero secret logging | SEC-T02 |
| SSH → remote host | MITM host key substitution | strict known host verification trước auth, mismatch hard block | SEC-T03 |
| Remote SFTP file names | Path traversal/control chars | canonicalization where reliable, safe display, explicit target path, no shell interp | SEC-T04 |
| File transfer | Partial overwrite/corruption | temp file, verify supported attributes, safe rename/fallback warning | SEC-T05 |
| External RDP | Credentials exposed via argv/temp files | no password args; sanitized config and cleanup; clipboard beyond app control | SEC-T06 |
| Local database | Host inventory / operational metadata disclosure | OS file permissions, lock, optional encrypted DB future; no plaintext secrets | SEC-T07 |
| App updates | Supply-chain compromise | signed releases, notarization, SBOM, pinned dependencies, controlled update channel | SEC-T08 |
| Terminal output | Escape-sequence or clipboard abuse | Native text rendering; OSC/links allowlist and opt-in clipboard | SEC-T09 |
| SSH tunnels | Unintended listening on public interface | bind loopback default, port validation, explicit user visibility | SEC-T10 |

## 3. Keychain and credential management

- Use Apple Security Keychain Services to store small secrets. `credential_refs.keychain_item_id` is only locator/identifier; **not password**.
- Credential types: password, key passphrase, maybe RDP password stored for later integration but **do not hand off into external app by argv**.
- Private SSH key: keep file in user-controlled protected path / ssh-agent; do not copy private key bytes into SQLite. The app must honor filesystem permission and never autoscan whole disk for keys.
- Avoid storing secrets in persistent SwiftUI state; input models hold values only for the form's short lifetime and clear them on completion/close best-effort.
- Add credential usage summary and unlink/revoke. Orphan secret cleanup requires confirmation and shared reference count.
- Failed unlock must not fall back to plaintext store.

## 4. SSH host verification

- TOFU with approval: unknown host shows fingerprint/algorithm and suggestion of **out-of-band verification**. Unknown key is not automatically trustworthy.
- Mismatch: block; user must verify with sysadmin and explicitly rotate existing trust in Known Hosts management. Rotation generates audit event.
- Warn for weak/unsupported host key algorithm; never silently downgrade policy to make connection pass.
- `known_hosts` scope hostname/port/algorithm/fingerprint; if reusing OS file, honor format and permissions. Avoid colliding writes with other SSH clients; in-app trust DB may be simpler but distinct to users.

## 5. Secure-by-default UX

- Prominent `PRODUCTION` badge in terminal and SFTP headers; destructive ops show `host + absolute remote path`.
- Never execute custom snippets automatically at connect or on import.
- Prevent copy-to-clipboard of secrets by default and display warning if user requests.
- Open external links only for allowlisted schemes (`https`, `mailto` if approved). SSH terminal clickable URLs require explicit confirmation for non-HTTPS schemes.

## 6. SwiftUI and local process attack surface

SwiftUI invokes typed `AppCore` services, which validate entity ownership and state against the local repository instead of trusting view state. When starting system tools, use a fixed executable path and typed argument arrays. Never build shell command strings, and keep secrets out of arguments, environment variables, and temporary files. SSH terminal input is sent only to a user-connected session; there is no generic command-execution service.

## 7. SFTP safety

- Normalize display separately from remote path identity; files named `..`, symlinks, control characters need explicit tests.
- All file writes require target-dir selected by user. Local filesystem selected through OS file picker; for sandboxed distribution persist security-scoped bookmark if needed.
- Upload temp/rename protected from race with another remote process: re-stat before replace, prevent silent overwrite; UX must disclose potential TOCTOU limitation.
- Download destination under user-selected directory and `.part` strategy; no automatic remote script execution.

## 8. Privacy and telemetry

- No account and no built-in analytics/telemetry by default.
- Diagnostic report generated locally and requires user action to share; redact hostname/IP/path by user selection.
- Crash reporter optional, off by default, must scrub secrets and terminal contents; user can view report before send if implemented.
- Logs metadata-only with default short retention and clear-all support.

## 9. Distribution hardening

- Build hardened runtime; sign Developer ID; notarize and staple direct-download `.dmg`/`.app` where supported.
- Audit bundled Swift packages and native dependencies; scan advisories; pin `Package.resolved` and verify checksums.
- Security update channel must verify signature, support rollback to trusted build where feasible, and never silently install unverified executable.
- Mac App Store version (sandbox rules) is **not** an initial commitment.

## 10. Security acceptance gates

1. SQLite `strings`/fixture scan contains no test passwords, passphrases or raw private key blocks.
2. Host-key mismatch test cannot invoke authentication even with UI tampering.
3. External RDP launch never includes secret in argv, generated profile or logs.
4. Malformed remote filenames cannot escape intended UI actions/execute code.
5. Terminal content with OSC 52 cannot silently read/write clipboard contrary to policy.
6. Disconnect/quit clears sensitive handles best-effort, file transfers have explicit terminal status.
7. Signed/notarized build passes Gatekeeper on a clean Mac without disabling security.

## 11. Residual risks

- If host OS compromised, Keychain/session data can be exposed to sufficiently privileged attacker; local-first is not a guarantee against endpoint compromise.
- Keychain data can be queried under macOS access-control prompts/policies; do not promise perfect in-memory zeroization across Swift or system processes.
- RDP external client has its own certificate/security policy beyond MRW control.
- Native dependency CVEs/security patch turnaround require maintained release process.


