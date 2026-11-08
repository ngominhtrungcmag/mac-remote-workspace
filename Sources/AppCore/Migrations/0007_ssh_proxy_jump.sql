-- Version 0007: optional single-hop ProxyJump setting.
ALTER TABLE host_connection_settings ADD COLUMN proxy_jump TEXT;
