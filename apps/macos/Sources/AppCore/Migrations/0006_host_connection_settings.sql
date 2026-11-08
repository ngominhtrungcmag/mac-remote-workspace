-- Per-host non-secret SSH settings. The migration runner wraps this in a transaction.
CREATE TABLE host_connection_settings (
  host_id TEXT PRIMARY KEY NOT NULL REFERENCES hosts(id) ON DELETE CASCADE,
  username TEXT NOT NULL,
  port INTEGER NOT NULL CHECK (port BETWEEN 1 AND 65535),
  auth_method TEXT NOT NULL CHECK (auth_method IN ('password', 'keychainCredential', 'sshAgent')),
  credential_id TEXT,
  key_file_path TEXT NOT NULL
);
