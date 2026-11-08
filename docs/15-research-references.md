# D15 — Research and Technical References

> This catalog preserves sources researched for the earlier Tauri/Rust prototype. Tauri, Rust, `ssh2`, and xterm.js links are historical implementation research, not active dependency guidance. Use ADR-010 and the Native Swift documents for current implementation. The Apple Keychain/notarization and FreeRDP references remain background sources only; no current app behavior is implied.

> Sources consulted as of 26/10/2026. Official documentation links should be rechecked before implementation because software versions and API signatures change.

## Official project/documentation sources

1. [Tauri v2 — Capabilities](https://tauri.app/security/capabilities/): permissions granted to windows/webviews, least privilege, command exposure implications.
2. [Tauri Security Architecture](https://tauri.app/security/): WebView–Rust IPC trust boundary and policy ownership.
3. [FreeRDP GitHub](https://github.com/FreeRDP/FreeRDP): RDP protocol library/clients; project describes Apache licensing.
4. [Rust ssh2 crate](https://docs.rs/ssh2/latest/ssh2/): Rust bindings for libssh2, client SSH interfaces.
5. [Rust ssh2 KnownHosts](https://docs.rs/ssh2/latest/ssh2/struct.KnownHosts.html): `check_port`, known-hosts trust and fingerprint comparison primitives.
6. [Apple Keychain Services](https://developer.apple.com/documentation/security/keychain-services): securely store small chunks of secret data.
7. [Apple Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution): Developer ID, hardened runtime, signing, notarization/stapling.
8. [Apple Accessing files from macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox): security-scoped bookmarks/user-selected files for sandboxed apps.
9. [xterm.js GitHub](https://github.com/xtermjs/xterm.js): terminal emulator and addon ecosystem.
10. [xterm.js Addons](https://xtermjs.org/docs/guides/using-addons/): rendering and fit behavior.
11. [Termix GitHub](https://github.com/Termix-SSH/Termix): existing SSH, SFTP, RDP and server management competitor; project describes Apache-2.0.
12. [1Remote GitHub](https://github.com/1Remote/1Remote): Windows-focused multi-protocol remote access manager and launcher.

## Notes on what was/was not verified

**Verified from official references:** Tauri capability model exists; Apple Keychain/Notarization are supported services; `ssh2` crate uses libssh2; FreeRDP is a RDP engine released under Apache; Termix already provides broad remote access features.

**Not validated by native executable spike:** SFTP transport selection and behavior; Keychain credential UX and denial behavior in the Swift app; safe external RDP launcher compatibility with supported macOS clients; FreeRDP embedding in AppKit; measured macOS memory/performance; supported-OS/hardware matrix. These remain feasibility/release gates (D13).

## Product research disclaimer

No user interview survey or statistically representative market-size analysis was performed for this document. Differentiation and adoption hypotheses must be tested during beta. Do not treat requirements design as market validation.


