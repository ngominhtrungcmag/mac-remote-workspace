# Project documents

The native Swift implementation at the repository root is the only active product target. ADR-010 is accepted and supersedes the implementation technology choices in the original D01–D16 design-kit extracts. The original source is preserved in `reference/`; use it for product intent and historical provenance, not as current framework guidance.

`docs/implementation/IMPLEMENTATION_PLAYBOOK.md` and its active task define the current delivery plan. `docs/08-ipc-contracts.md` is retained as a logical service-contract reference; there is no Tauri IPC layer in the native app.

The D01–D16 working documents below preserve the original requirement IDs and product intent, with implementation choices reconciled to ADR-010. The original Markdown, Word, and PDF files are preserved in [`reference/`](reference/) as historical source. Mermaid diagrams remain embedded in their source sections.

## Product and requirements

- [D01 — Product requirements](01-vision-prd.md)
- [D02 — Software requirements](02-srs.md)
- [D03 — User journeys and states](03-user-journeys.md)
- [D04 — UX/UI](04-ux-ui.md)

## Architecture and security

- [D05 — Architecture](05-architecture.md)
- [D06 — Data model](06-data-model.md)
- [D07 — Protocols and sessions](07-protocols-sessions.md)
- [D08 — Native AppCore service contracts](08-ipc-contracts.md)
- [D09 — Security](09-security.md)

## Delivery and operations

- [D10 — Test plan](10-test-plan.md)
- [D11 — Build, release, and runbook](11-build-release-runbook.md)
- [D12 — Roadmap and backlog](12-roadmap-backlog.md)
- [D13 — ADRs, risks, and spikes](13-adr-risks.md)
- [D14 — Governance](14-governance.md)
- [D15 — Research references](15-research-references.md)
- [D16 — Implementation blueprint](16-implementation-blueprint.md)

## Project instructions

- [Implementation playbook](implementation/IMPLEMENTATION_PLAYBOOK.md)

Earlier prototype history is not published. ADRs and design documents predate the move of the Swift package to the repository root, may reference old `apps/macos/` or Tauri-prototype paths, and are partly written in Vietnamese.
