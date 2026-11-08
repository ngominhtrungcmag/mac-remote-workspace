-- Independent protocol switches preserve profiles and their associated history.
CREATE TABLE host_protocols (
  host_id TEXT PRIMARY KEY NOT NULL REFERENCES hosts(id) ON DELETE CASCADE,
  ssh_enabled INTEGER NOT NULL DEFAULT 0 CHECK (ssh_enabled IN (0, 1)),
  rdp_enabled INTEGER NOT NULL DEFAULT 0 CHECK (rdp_enabled IN (0, 1))
);
INSERT INTO host_protocols (host_id, ssh_enabled, rdp_enabled)
SELECT h.id,
  EXISTS(SELECT 1 FROM connection_profiles p WHERE p.host_id = h.id AND p.protocol = 'ssh'),
  EXISTS(SELECT 1 FROM connection_profiles p WHERE p.host_id = h.id AND p.protocol = 'rdp')
FROM hosts h;
CREATE TRIGGER host_protocols_after_host_insert AFTER INSERT ON hosts
BEGIN
  INSERT INTO host_protocols (host_id) VALUES (NEW.id);
END;
