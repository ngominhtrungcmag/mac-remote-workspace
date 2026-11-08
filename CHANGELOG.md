# Changelog

## 1.0.1 — 2026-11-08

- FreeRDP 3.33.0: fixes RDP failing on Macs with long hostnames, plus upstream security fixes.
- RDP fixes: app-managed certificate trust on every handshake, desktop resize, stuck Ctrl after Cmd shortcuts, close-during-connect race, wheel delta, Caps Lock.
- SSH/SFTP fixes: multi-key host trust, auth-failure backoff, final error output, symlinked `~/.ssh`, askpass timing, SFTP password lifetime with queued transfers, stale listings, metrics off the main thread, import strips credential IDs.
- Build: Xcode 27 required; CI runs on the xcode-27 runner.

## 1.0.0 — 2026-11-08

- Native macOS host inventory, SSH terminal tabs, strict host trust and Keychain credentials.
- SFTP browsing and transfers, ProxyJump, local tunnels and snippets.
- Embedded FreeRDP desktop, serial console, metadata import/export and English/Vietnamese localization.
- SFTP opens in its own window with multi-select, drag-and-drop upload, context menus and keyboard shortcuts.
- Host menu commands (New Host, Connect, Edit, Delete, SFTP, RDP), host search in the command palette, and a default protocol setting (SSH or RDP).
- Per-host connection settings stored in SQLite, inventory export/import v2, and `~/.ssh/config` import (User, Port, IdentityFile, ProxyJump, Include).
- Saved SSH passwords are read by the app after host trust and handed to `ssh` through a one-shot FIFO; no secret touches disk or argv.
- Confirmation before closing windows with live sessions or active transfers; atomic `known_hosts` updates.
