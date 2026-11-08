# ADR-010: Native Swift macOS Application Target

**Status:** Accepted  
**Date:** 2026-10-30  
**Scope:** Product implementation target and active engineering guidance

## Context

The repository contains a React/Tauri/Rust prototype and a separate native SwiftUI/AppKit application under `apps/macos/`. The original design and early implementation records name Tauri as the target, while the current product direction is macOS-native and the native application already contains the active app shell, host inventory, SSH host-trust flow, and PTY session path. Two implementation targets create contradictory architecture, testing, and task guidance.

## Decision

The sole product implementation target is `apps/macos/`, built with SwiftUI/AppKit and Swift `AppCore`. Use SQLite migrations for local metadata, Apple Keychain for secrets, and macOS system services for SSH, RDP launch, and local file access.

The React/Tauri/Rust implementation under `apps/desktop/`, along with its IPC types, capabilities, and build tooling, is a superseded prototype kept as historical evidence. Do not add product features, migration work, or maintenance fixes to those paths unless a future issue explicitly requests prototype maintenance or historical analysis.

## Consequences

- Views call typed in-process Swift services; there is no WebView-to-Rust IPC boundary in the product app.
- New features, tests, CI checks, packaging, and implementation tasks target `apps/macos/` and Swift Package Manager.
- SSH and other subprocesses use fixed executable paths and typed argument arrays. Secrets never enter argv, logs, SQLite, or generated config files.
- Existing prototype test results remain evidence for the prototype only; they do not establish native feature completion.
- Product work proceeds one native vertical slice at a time. Feature parity with the prototype is not assumed.

## Validation

This is a scope and architecture decision, not a claim that native P0 or release gates are complete. Native build, SSH/SFTP integration, Keychain, signing, notarization, and supported-macOS evidence must be recorded separately against their requirements.
