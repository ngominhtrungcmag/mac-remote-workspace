-- Version 0003: user-authored command snippets scoped to one host or group.
-- Snippet content is local metadata; never include secrets or credentials.

CREATE TABLE command_snippets (
  id TEXT NOT NULL PRIMARY KEY,
  title TEXT NOT NULL CHECK (length(trim(title)) BETWEEN 1 AND 80),
  command_text TEXT NOT NULL
    CHECK (length(trim(command_text)) > 0 AND length(CAST(command_text AS BLOB)) <= 8192),
  host_id TEXT REFERENCES hosts(id) ON DELETE CASCADE,
  group_id TEXT REFERENCES host_groups(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  version INTEGER NOT NULL DEFAULT 1 CHECK (version > 0),
  CHECK ((host_id IS NOT NULL AND group_id IS NULL) OR (host_id IS NULL AND group_id IS NOT NULL))
);

CREATE INDEX command_snippets_host_title_idx
  ON command_snippets(host_id, title COLLATE NOCASE);
CREATE INDEX command_snippets_group_title_idx
  ON command_snippets(group_id, title COLLATE NOCASE);
