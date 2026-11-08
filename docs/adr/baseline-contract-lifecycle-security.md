# ADR: Reconstructed contract, lifecycle, and safety rules

> **Historical prototype contract.** The Rust/Tauri IPC and command details below are not active interfaces. Preserve product security intent where compatible; current implementation uses the Native Swift in-process contracts in D08 and ADR-010.

Status: Accepted for this reconstructed baseline  
Date: 2026-10-27

## Context

D05–D09 describe the model and behavior but leave implementation seams open: persistent session metadata versus ephemeral workers, logical dotted IPC names versus Tauri registration names, caller-controlled trust/confirmation data, and cleanup of active work before deleting its profile.

## Decision

- Treat schema.sql as a logical schema baseline at user_version 1, not a migration. Production changes use versioned transactional migrations and enable SQLite foreign keys on every connection.
- Use row versions for optimistic concurrency on editable workspace/group/host/profile/tag/layout records. JSON columns must parse, and Rust validates their allowlist so settings/options cannot become secret stores.
- Add `transfer.list` to retrieve durable transfer summaries after restart; events alone cannot restore the queue view. This is a derived extension to D08, not an implemented handler.
- Store layout snapshots as versioned tab metadata only. Tabs contain profile IDs and terminal/SFTP kind; they contain no live session IDs, credentials, or transcript. Expose group listing so empty groups remain discoverable.
- Persist host/profile/trust metadata and redacted lifecycle summaries only. Session handles, worker state, trust nonces, terminal bytes, secrets, and transfer contents are never database fields. A process restart restores disconnected placeholders; it never auto-authenticates or replays terminal input.
- On restart, reconcile any nonterminal persisted session to interrupted. A session must be closed and any active transfer cancelled or completed before profile deletion; database triggers reject cascaded deletion while those states remain active. Host deletion may remove dependent history, but never deletes shared Keychain items. Credential rows use RESTRICT while referenced; unlink requires a separate confirmed action before orphan cleanup. Audit metadata remains detached from deleted entities.
- Treat dotted names in ipc.types.ts as logical facade names; the Rust Tauri registration maps them explicitly to actual command handlers.
- Rust owns trust and confirmation challenges. A trust decision carries only the server-issued request ID and a finite decision; it cannot submit a fingerprint or endpoint. The backend checks the live challenge/session and verifies host identity before retrieving credentials. Mismatch is a hard stop. Overwrite confirmation binds the exact profile, direction, local grant, and remote path.
- Native file selection returns short-lived opaque grants. Transfer and private-key commands consume grants; the WebView does not receive broad filesystem authority. Confirmation tokens are short-lived, single-use, and bound to action and target.
- Error/event payloads contain stable codes and redacted user-facing text only. Never include secrets, terminal data, raw file contents, or unreviewed paths in diagnostics.
- Keep metadata import/export as a P1-only type extension. It excludes credentials, local private-key paths, and trusted-host decisions. No RDP command or RDP profile is part of this P0 contract.

## Consequences

Rust command handlers must enforce entity ownership, state transitions, path grants, confirmation tokens, and redaction even when the UI validates the same inputs. The baseline schema intentionally retains sensitive operational metadata such as endpoint and transfer paths locally; production retention and deletion policy must be implemented before those tables are used.

## Validation evidence

The SQL and TypeScript baseline checks validate syntax, constraints, and the trust/transfer type shapes only. They do not prove Rust handler behavior, Keychain behavior, or SSH/SFTP integration.
