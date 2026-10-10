-- Additive ACL-005 schema. Retain all existing assets and reservations.
ALTER TABLE upload_sessions ADD COLUMN transfer_mode TEXT NOT NULL DEFAULT 'single' CHECK(transfer_mode IN ('single','multipart'));
ALTER TABLE upload_sessions ADD COLUMN part_size_bytes BIGINT CHECK(part_size_bytes >= 5242880 AND part_size_bytes <= 67108864);
ALTER TABLE upload_sessions ADD COLUMN multipart_upload_id TEXT;
ALTER TABLE upload_sessions ADD COLUMN completed_version_id TEXT;
ALTER TABLE upload_sessions ADD COLUMN cleanup_completed_at TIMESTAMPTZ;
CREATE TABLE upload_parts (
 upload_session_id UUID NOT NULL REFERENCES upload_sessions(id),
 part_number INTEGER NOT NULL CHECK(part_number BETWEEN 1 AND 10000),
 expected_size_bytes BIGINT NOT NULL CHECK(expected_size_bytes > 0 AND expected_size_bytes <= 67108864),
 expected_checksum CHAR(64) NOT NULL CHECK(expected_checksum ~ '^[a-f0-9]{64}$'),
 storage_etag TEXT, completed_at TIMESTAMPTZ,
 PRIMARY KEY(upload_session_id,part_number)
);
CREATE INDEX multipart_cleanup ON upload_sessions(expires_at) WHERE transfer_mode='multipart' AND cleanup_completed_at IS NULL AND status<>'PROTECTED';
