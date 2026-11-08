# D14 — Open Source Governance, License and Community Plan

> **Active implementation target:** Native Swift in `apps/macos/` (ADR-010). The native package currently has no third-party dependencies and delegates SSH/SFTP to maintained macOS system services (OpenSSH client, Keychain, SQLite via system framework). Third-party acknowledgments apply only to dependencies actually bundled in a shipped release (for example, FreeRDP only if embedded RDP passes its P2 feasibility gate). Historical prototype acknowledgments for xterm.js and Rust crates do not apply to the native app; keep notice inventory accurate per release from the app's binary dependencies.

## 1. Licensing recommendation

For a general-purpose desktop utility, **Apache-2.0** is the recommended option to review before public repository launch: permissive contributions/integrations, explicit patent grant, widespread ecosystem compatibility. This is a project recommendation, **not legal advice**. Decision must be finalized and an official LICENSE/NOTICE added before accepting contributions or distributing third-party bundled binaries.

- Alternative: MIT is simpler but lacks the same explicit patent formulation.
- AGPLv3 is an option for deliberate network copyleft objective but may complicate enterprise adoption; assess legal and dependency compatibility first.
- FreeRDP reports Apache License; check exact versions and bundled native components before distributing embedded RDP engine (P2 only).
- Third-party acknowledgments required for any bundled native dependencies or external binaries; the current `apps/macos` package has no third-party dependencies, so no xterm.js/Rust-crate acknowledgments carry over from the superseded prototype.

## 2. Repository governance

- `README.md`: value proposition, screenshots, support, install links, security notes.
- `CONTRIBUTING.md`: setup requirements, coding conventions, tests, issue templates, DCO/CLA decision.
- `CODE_OF_CONDUCT.md`: contributor behavior.
- `SECURITY.md`: private vulnerability reporting, supported versions, disclosure window.
- `PRIVACY.md`: no data collection by default, local storage, diagnostics, how to delete data.
- `CHANGELOG.md`: Keep a Changelog; SemVer for public API if plugin API introduced.

## 3. Contribution process

- Label issues: `good-first-issue`, `help-wanted`, `bug`, `security`, `protocol:ssh`, `protocol:sftp`, `ux`, `macos`.
- Small PR focused on module + tests + FR reference + screenshots for UI.
- Security-sensitive PR (Keychain, host trust, IPC, transfer overwrite) requires second reviewer before merge.
- No production credentials/screenshots showing real IP/domains in issues; provide synthetic fixtures.
- Community translation after UI text keys stable; Vietnamese and English at first release.

## 4. Project structure and product ethos

- Offline first, no account, no mandatory telemetry.
- Monetization if introduced should not create surprise restrictions on previously open core capabilities; explain roadmap and license changes transparently.
- Avoid copying third-party UI assets/screenshots into product without permissions.
- Developer may contribute to Termix/FreeRDP upstream where appropriate rather than duplicating maintenance work.

## 5. Initial public launch checklist

- License chosen, author rights confirmed, CONTRIBUTING/SECURITY/privacy docs.
- Screenshots sanitized, onboarding docs, install methods, release artifacts signed/notarized.
- Small reproducible integration test environment available.
- Source code secrets scanner clean; fixtures synthetic only.
- Roadmap honest about RDP launcher vs embedded RDP.

## 6. Suggested community roadmap

1. **0.1.0-alpha:** inventory, host trust and basic SSH.
2. **0.2.0-alpha:** SFTP queue, safe transfer, keyboard/accessibility pass.
3. **0.5.0-beta:** signed/notarized beta, import/export, docs and privacy review.
4. **1.0.0:** external RDP, local SSH tunnel and stable core, after all gates pass.
5. **2.0.0:** embedded RDP only if feasibility and security matrix pass; otherwise 1.x continues.

These are semantic targets, not fixed shipping dates.


