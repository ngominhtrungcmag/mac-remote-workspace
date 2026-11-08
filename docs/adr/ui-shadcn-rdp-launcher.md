# ADR: Session workspace UI and external Windows RDP

> **Historical React/Tauri UI decision.** Tailwind/shadcn and Rust command details below are superseded by the Native Swift target. Retain external RDP workflow and safety findings only where they match current D02/D12 requirements; this ADR is not implementation guidance for the current root Swift package.

Status: Accepted for local implementation  
Date: 2026-10-27

## Context

The user selected wireframe B with compact copy and repeated metadata hidden, and requested Tailwind and shadcn/ui. D07/D08 define external Windows RDP as P1 (US-017/FR-016); embedded RDP remains P2. The existing profile schema only permits SSH.

## Decision

- Keep the B layout: workspace navigation, compact host inventory, selected connection profile, and session surface. Move host/profile editing, Keychain management and settings into shadcn/Radix dialogs. Preserve the existing SSH/SFTP operations and confirmation policy.
- Use Tailwind v4's Vite plugin and local shadcn Button, Input, Select and Dialog source. `components.json` and `@/` aliases support adding components later. CSS variables in `src/App.css` remain the single brand/theme source; light/dark follow macOS. Keep visible keyboard focus for FR-015.
- Add `rdp` profiles with `authMethod: external`. Reject credentials/private keys on RDP and reject external auth on SSH at both Rust validation and SQLite constraints. SSH/SFTP resolve only SSH profiles.
- Register `rdp.client_status` → `rdp_client_status` (no request, `{available, clientName}`) and `rdp.launch_external` → `rdp_launch_external` (`{profileId}`, `{operationId, status: 'launched'}`). Both native commands run blocking work off the webview thread. Error codes are `RDP_CLIENT_MISSING` and `RDP_LAUNCH_FAILED` in the existing AppError envelope.
- Detect the approved Microsoft bundle (`com.microsoft.rdc.macos`) in `/Applications` or `~/Applications`. Open an endpoint-only `rdp://full%20address=s%3A...` URI through fixed `/usr/bin/open` argv. Percent-encode colons/brackets for macOS URL parsing. No username, password, key or arbitrary URI fields are handed off. No temporary profile files or broader Tauri permissions are needed.
- Show launching, launched or failed; never claim an external session is connected. Show the endpoint and a copy fallback. Windows App controls authentication, certificates and remote session behavior.
- Migrate version 1 → 2 transactionally by rebuilding `connection_profiles`. Checkpoint WAL before the restricted backup, preserve profile IDs/dependent records, recreate deletion guards, and run `foreign_key_check` before commit. Foreign-key enforcement is suspended only on the private migration connection for the rebuild and reenabled afterward; operational connections still enable it on open. The logical schema snapshot now describes v2; migration 0001 is unchanged.

## Consequences

RDP opens in a separate client and is not restored as an SSH tab or counted as a managed session. Client installations outside the approved Application directories fall back to manual endpoint copy. Schema v2 must not be downgraded using an older app; the migration creates a pre-upgrade metadata backup.

## Validation evidence

Rust tests cover secret rejection, protocol routing, URI injection/IPv6, missing client, migration preservation and deletion guards. An explicit ignored native smoke test was run on this Mac and opened Windows App against an unused loopback port. This proves local client dispatch only, not Windows authentication or desktop rendering. Frontend interaction tests and local browser evidence cover the UI; the existing loopback OpenSSH/SFTP fixture was rerun.

## Sources

- [Tailwind with Vite](https://tailwindcss.com/docs/installation/using-vite)
- [shadcn Vite setup](https://ui.shadcn.com/docs/installation/vite) and the official new-york-v4 component registry
- [Microsoft RDP URI scheme](https://learn.microsoft.com/en-us/previous-versions/remote-desktop-client/remote-desktop-uri)
