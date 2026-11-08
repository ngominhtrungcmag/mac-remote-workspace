CREATE TABLE connection_profiles_new (
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
INSERT INTO connection_profiles_new SELECT * FROM connection_profiles;
DROP TABLE connection_profiles;
ALTER TABLE connection_profiles_new RENAME TO connection_profiles;
CREATE INDEX connection_profiles_host_protocol_idx ON connection_profiles(host_id, protocol);
CREATE TRIGGER IF NOT EXISTS prevent_profile_delete_with_live_session
BEFORE DELETE ON connection_profiles
WHEN EXISTS (
  SELECT 1 FROM recent_sessions
  WHERE connection_profile_id = OLD.id
    AND status IN ('resolving', 'connecting', 'verifying_host', 'authenticating', 'connected', 'interrupted', 'closing')
)
BEGIN
  SELECT RAISE(ABORT, 'connection profile has a live session');
END;

CREATE TRIGGER IF NOT EXISTS prevent_profile_delete_with_active_transfer
BEFORE DELETE ON connection_profiles
WHEN EXISTS (
  SELECT 1 FROM transfer_jobs
  WHERE connection_profile_id = OLD.id
    AND status IN ('created', 'validating', 'running', 'verifying')
)
BEGIN
  SELECT RAISE(ABORT, 'connection profile has an active transfer');
END;

