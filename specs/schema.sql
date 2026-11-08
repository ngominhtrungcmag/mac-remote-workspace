-- Reconstructed logical baseline from D06; this is not a production migration.
-- Enable foreign keys on every opened connection, not only while loading this file.
PRAGMA foreign_keys = ON;
PRAGMA user_version = 2;

CREATE TABLE workspaces (
  id TEXT NOT NULL PRIMARY KEY,
  name TEXT NOT NULL CHECK (length(trim(name)) > 0),
  color TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  version INTEGER NOT NULL DEFAULT 1 CHECK (version > 0)
);

CREATE TABLE host_groups (
  id TEXT NOT NULL PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  name TEXT NOT NULL CHECK (length(trim(name)) > 0),
  sort_order INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  version INTEGER NOT NULL DEFAULT 1 CHECK (version > 0),
  UNIQUE (id, workspace_id),
  UNIQUE (workspace_id, name COLLATE NOCASE)
);

CREATE TABLE hosts (
  id TEXT NOT NULL PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  group_id TEXT,
  display_name TEXT NOT NULL CHECK (length(trim(display_name)) > 0),
  address TEXT NOT NULL CHECK (length(trim(address)) > 0),
  environment TEXT NOT NULL CHECK (environment IN ('development', 'staging', 'production')),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  version INTEGER NOT NULL DEFAULT 1 CHECK (version > 0),
  FOREIGN KEY (group_id, workspace_id)
    REFERENCES host_groups(id, workspace_id)
    DEFERRABLE INITIALLY DEFERRED
);

-- Deleting a group detaches its hosts instead of deleting them.
CREATE TRIGGER host_groups_detach_hosts_before_delete
BEFORE DELETE ON host_groups
BEGIN
  UPDATE hosts SET group_id = NULL
  WHERE group_id = OLD.id AND workspace_id = OLD.workspace_id;
END;

CREATE TABLE credential_refs (
  id TEXT NOT NULL PRIMARY KEY,
  label TEXT NOT NULL CHECK (length(trim(label)) > 0),
  kind TEXT NOT NULL CHECK (kind IN ('password', 'key_passphrase')),
  keychain_item_id TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE connection_profiles (
  id TEXT NOT NULL PRIMARY KEY,
  host_id TEXT NOT NULL REFERENCES hosts(id) ON DELETE CASCADE,
  protocol TEXT NOT NULL CHECK (protocol IN ('ssh', 'rdp')),
  port INTEGER NOT NULL CHECK (port BETWEEN 1 AND 65535),
  username TEXT NOT NULL CHECK (length(trim(username)) > 0),
  auth_method TEXT NOT NULL CHECK (auth_method IN ('password', 'private_key', 'ssh_agent', 'external')),
  private_key_path TEXT,
  credential_ref_id TEXT REFERENCES credential_refs(id) ON DELETE RESTRICT,
  options_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(options_json)),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  version INTEGER NOT NULL DEFAULT 1 CHECK (version > 0),
  CHECK ((protocol = 'rdp' AND auth_method = 'external' AND credential_ref_id IS NULL AND private_key_path IS NULL) OR (protocol = 'ssh' AND auth_method != 'external')),
  CHECK ((auth_method = 'private_key') = (private_key_path IS NOT NULL))
);

CREATE TABLE tags (
  id TEXT NOT NULL PRIMARY KEY,
  name TEXT NOT NULL CHECK (length(trim(name)) > 0),
  normalized_name TEXT NOT NULL UNIQUE CHECK (length(trim(normalized_name)) > 0),
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  version INTEGER NOT NULL DEFAULT 1 CHECK (version > 0)
);

CREATE TABLE host_tags (
  host_id TEXT NOT NULL REFERENCES hosts(id) ON DELETE CASCADE,
  tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  PRIMARY KEY (host_id, tag_id)
);

CREATE TABLE trusted_host_keys (
  endpoint TEXT NOT NULL CHECK (length(trim(endpoint)) > 0),
  port INTEGER NOT NULL CHECK (port BETWEEN 1 AND 65535),
  key_algorithm TEXT NOT NULL CHECK (length(trim(key_algorithm)) > 0),
  fingerprint_sha256 TEXT NOT NULL CHECK (substr(fingerprint_sha256, 1, 7) = 'SHA256:'),
  first_seen TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (endpoint, port, key_algorithm)
);

-- This table stores lifecycle metadata only; session/channel/worker handles stay in memory.
CREATE TABLE recent_sessions (
  id TEXT NOT NULL PRIMARY KEY,
  connection_profile_id TEXT NOT NULL REFERENCES connection_profiles(id) ON DELETE CASCADE,
  started_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  ended_at TEXT,
  status TEXT NOT NULL CHECK (status IN (
    'resolving', 'connecting', 'verifying_host', 'authenticating', 'connected',
    'interrupted', 'closing', 'closed', 'failed'
  )),
  error_code TEXT
);

CREATE TABLE transfer_jobs (
  id TEXT NOT NULL PRIMARY KEY,
  connection_profile_id TEXT NOT NULL REFERENCES connection_profiles(id) ON DELETE CASCADE,
  direction TEXT NOT NULL CHECK (direction IN ('upload', 'download')),
  local_path TEXT NOT NULL,
  remote_path TEXT NOT NULL,
  conflict_policy TEXT NOT NULL CHECK (conflict_policy IN ('skip', 'rename', 'overwrite')),
  bytes_total INTEGER CHECK (bytes_total IS NULL OR bytes_total >= 0),
  bytes_transferred INTEGER NOT NULL DEFAULT 0 CHECK (bytes_transferred >= 0),
  status TEXT NOT NULL CHECK (status IN (
    'created', 'validating', 'running', 'verifying', 'completed',
    'failed', 'cancelled', 'interrupted'
  )),
  error_code TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  ended_at TEXT
);

-- Reject cascaded deletion while a live session or transfer still needs cleanup.
CREATE TRIGGER prevent_profile_delete_with_live_session
BEFORE DELETE ON connection_profiles
WHEN EXISTS (
  SELECT 1 FROM recent_sessions
  WHERE connection_profile_id = OLD.id
    AND status IN ('resolving', 'connecting', 'verifying_host', 'authenticating', 'connected', 'interrupted', 'closing')
)
BEGIN
  SELECT RAISE(ABORT, 'connection profile has a live session');
END;

CREATE TRIGGER prevent_profile_delete_with_active_transfer
BEFORE DELETE ON connection_profiles
WHEN EXISTS (
  SELECT 1 FROM transfer_jobs
  WHERE connection_profile_id = OLD.id
    AND status IN ('created', 'validating', 'running', 'verifying')
)
BEGIN
  SELECT RAISE(ABORT, 'connection profile has an active transfer');
END;

CREATE TABLE audit_events (
  id TEXT NOT NULL PRIMARY KEY,
  action TEXT NOT NULL CHECK (length(trim(action)) > 0),
  entity_type TEXT NOT NULL CHECK (length(trim(entity_type)) > 0),
  entity_id TEXT,
  outcome TEXT NOT NULL CHECK (outcome IN ('success', 'failure', 'denied')),
  error_code TEXT,
  occurred_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE app_settings (
  key TEXT NOT NULL PRIMARY KEY,
  json_value TEXT NOT NULL CHECK (json_valid(json_value))
);

-- Snapshots contain disconnected tab/layout metadata, never live session IDs or secrets.
CREATE TABLE layout_snapshots (
  id TEXT NOT NULL PRIMARY KEY,
  workspace_id TEXT REFERENCES workspaces(id) ON DELETE CASCADE,
  name TEXT NOT NULL CHECK (length(trim(name)) > 0),
  layout_json TEXT NOT NULL CHECK (json_valid(layout_json)),
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  version INTEGER NOT NULL DEFAULT 1 CHECK (version > 0),
  UNIQUE (workspace_id, name)
);

CREATE INDEX hosts_workspace_environment_idx ON hosts(workspace_id, environment);
CREATE INDEX hosts_display_name_idx ON hosts(display_name COLLATE NOCASE);
CREATE INDEX connection_profiles_host_protocol_idx ON connection_profiles(host_id, protocol);
CREATE INDEX recent_sessions_started_at_idx ON recent_sessions(started_at DESC);
CREATE INDEX transfer_jobs_status_updated_at_idx ON transfer_jobs(status, updated_at);
CREATE INDEX audit_events_occurred_at_idx ON audit_events(occurred_at DESC);
