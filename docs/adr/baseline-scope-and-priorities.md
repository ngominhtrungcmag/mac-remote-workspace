# ADR: Reconstructed baseline scope and priorities

> **Reconstructed baseline record.** This preserves original requirement priority reconciliation. Its implementation scope and any prototype-specific evidence are subordinate to current requirements and ADR-010; it does not define an implementation framework.

Status: Accepted for this reconstructed baseline  
Date: 2026-10-27

## Context

The referenced SQL, IPC, traceability, and release-gate annexes were not supplied. The extracted design also conflicts with the project boundary in AGENTS.md: D01/D02 call metadata import/export P0/MUST, while the project boundary and delivery plan place it in P1. RDP is not an MVP capability.

## Decision

- Reconstruct the annexes as derived baseline artifacts; do not represent them as recovered originals or implemented product behavior.
- Preserve each source ID and source priority. For implementation scope, FR-014 and US-004 are P1 despite their D02 MUST and D12 P0 labels. Keep them in traceability as deferred P1 work.
- Keep external RDP (FR-016, US-017) deferred to P1 and embedded RDP (FR-021, US-021) deferred to P2. Neither appears in the P0 schema protocol enum or command map.
- Keep the implementation baseline P0 to inventory metadata, Keychain references, SSH trust/auth/session lifecycle, SFTP, and required safety/quality gates. Tunnels, diagnostics, snippets, command palette, and plugin/metrics extensions remain deferred at their source priorities.

## Consequences

Downstream work must follow the implementation-scope column in requirements-traceability.csv while retaining the original design priority for auditability. Revisit this ADR only through an approved scope change; do not silently promote deferred features into P0.

## Validation evidence

This decision reconciles AGENTS.md, D01/D02, D12, and the Task-00 kickoff. It is a scope decision, not application acceptance evidence.
