# Changelog

## 1.0.0 (unreleased)

- Native macOS host inventory, SSH terminal tabs, strict host trust and Keychain credentials.
- SFTP browsing and transfers, ProxyJump, local tunnels and snippets.
- Embedded FreeRDP desktop, serial console, metadata import/export and English/Vietnamese localization.
- SFTP opens in its own window with multi-select, drag-and-drop upload, context menus and keyboard shortcuts.
- Host menu commands (New Host, Connect, Edit, Delete, SFTP, RDP), host search in the command palette, and a default protocol setting (SSH or RDP).
- Per-host connection settings stored in SQLite, inventory export/import v2, and `~/.ssh/config` import (User, Port, IdentityFile, ProxyJump, Include).
- Saved SSH passwords are read by the app after host trust and handed to `ssh` through a one-shot FIFO; no secret touches disk or argv.
- Confirmation before closing windows with live sessions or active transfers; atomic `known_hosts` updates.
