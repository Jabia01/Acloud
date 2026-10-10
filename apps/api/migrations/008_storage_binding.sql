-- Provider identity binds assets to a deployment, independent of credential rotation.
ALTER TABLE assets ADD COLUMN storage_provider text NOT NULL DEFAULT 'minio' CHECK(storage_provider IN('minio','backblaze_b2'));
ALTER TABLE assets ADD COLUMN storage_binding char(64) CHECK(storage_binding IS NULL OR storage_binding ~ '^[a-f0-9]{64}$');
ALTER TABLE assets ADD CONSTRAINT assets_storage_binding_required CHECK(storage_provider='minio' OR storage_binding IS NOT NULL);
CREATE INDEX assets_provider_status ON assets(storage_provider,status);
-- Legacy rows remain MinIO with unknown binding; only MinIO may access them.
