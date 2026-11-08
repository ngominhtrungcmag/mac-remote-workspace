-- Version 0005: Allow rdp_password in credential_refs table.
-- References: US-005, FR-004, FR-021.

CREATE TABLE credential_refs_v5 (
  id TEXT NOT NULL PRIMARY KEY,
  label TEXT NOT NULL CHECK (length(trim(label)) > 0),
  kind TEXT NOT NULL CHECK (kind IN ('password', 'key_passphrase', 'rdp_password')),
  keychain_item_id TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO credential_refs_v5 (id, label, kind, keychain_item_id, created_at)
  SELECT id, label, kind, keychain_item_id, created_at FROM credential_refs;
DROP TABLE credential_refs;
ALTER TABLE credential_refs_v5 RENAME TO credential_refs;
