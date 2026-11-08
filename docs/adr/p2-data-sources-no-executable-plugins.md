# ADR: P2 optional data sources are declarative; executable plugins stay blocked

## Status
Accepted (P2 GO, scoped).

## Context
FR-024 (COULD) describes a plugin API for protocol adapters requiring a signed manifest/capability model and forbids running untrusted native code implicitly. The roadmap excludes plugin execution; R-09 says plugins come only after P2 and after audit/SBOM.

## Decision
- Ship only a declarative data source: read-only import of `Host`/`HostName` from an OpenSSH config file chosen by the user (file named `config` or `*.sshconfig`), feeding the existing dry-run/conflict import flow (`InventoryImportExportService.previewSSHConfig`). No schema change (migration 0008 not used).
- Text parsing only. IdentityFile, ProxyCommand, Include, Match, passwords and all other keywords are ignored, so no secret, key path or command is imported or run. Wildcard hosts are skipped; aliases/hostnames with option-like (`-`) or shell metacharacters are rejected; input is capped at 1 MiB.
- Do NOT load or execute dylibs, scripts or any third-party code. FR-024 executable plugins are not implemented.

## Security gate for any future executable plugin
Requires a separate ADR and review covering: signed manifest with pinned developer key, explicit capability grants (no Keychain/secret access by default), out-of-process XPC sandbox, user opt-in per plugin, SBOM/audit, and tests proving secret canaries never cross the boundary.
