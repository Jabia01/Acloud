-- Additive generated-file upload foundation. No destructive customer-data changes.
CREATE TABLE development_entitlements (
    user_id UUID PRIMARY KEY REFERENCES users(id),
    plan TEXT NOT NULL DEFAULT 'FREE_DEV' CHECK(plan='FREE_DEV'),
    quota_bytes BIGINT NOT NULL CHECK(quota_bytes >= 0),
    protected_bytes BIGINT NOT NULL DEFAULT 0 CHECK(protected_bytes >= 0),
    reserved_bytes BIGINT NOT NULL DEFAULT 0 CHECK(reserved_bytes >= 0),
    CHECK(protected_bytes + reserved_bytes <= quota_bytes)
);
CREATE TABLE assets (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id),
    device_id UUID,
    media_type TEXT NOT NULL CHECK(media_type IN ('image','video','test')),
    expected_size_bytes BIGINT NOT NULL CHECK(expected_size_bytes > 0),
    expected_checksum CHAR(64) NOT NULL CHECK(expected_checksum ~ '^[a-f0-9]{64}$'),
    storage_object_key TEXT NOT NULL UNIQUE,
    storage_version_id TEXT,
    verified_size_bytes BIGINT,
    status TEXT NOT NULL CHECK(status IN ('QUEUED','UPLOADING','UPLOADED','VERIFYING','PROTECTED','FAILED','CANCELLED','EXPIRED')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now(), protected_at TIMESTAMPTZ,
    UNIQUE(id,user_id),
    FOREIGN KEY(device_id,user_id) REFERENCES devices(id,user_id),
    CHECK((status='PROTECTED') = (protected_at IS NOT NULL)),
    CHECK(status<>'PROTECTED' OR (storage_version_id IS NOT NULL AND verified_size_bytes=expected_size_bytes))
);
CREATE TABLE upload_sessions (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id), asset_id UUID NOT NULL UNIQUE,
    idempotency_key UUID NOT NULL, request_hash CHAR(64) NOT NULL,
    status TEXT NOT NULL CHECK(status IN ('QUEUED','UPLOADING','UPLOADED','VERIFYING','PROTECTED','FAILED','CANCELLED','EXPIRED')),
    expected_size_bytes BIGINT NOT NULL CHECK(expected_size_bytes > 0),
    expected_checksum CHAR(64) NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), completed_at TIMESTAMPTZ,
    verification_lease UUID, verification_lease_until TIMESTAMPTZ,
    last_error_code TEXT,
    reservation_released_at TIMESTAMPTZ,
    UNIQUE(user_id,idempotency_key),
    FOREIGN KEY(asset_id,user_id) REFERENCES assets(id,user_id)
);
CREATE INDEX uploads_expiry ON upload_sessions(user_id,expires_at) WHERE reservation_released_at IS NULL;
CREATE INDEX uploads_abandoned ON upload_sessions(expires_at) WHERE status NOT IN ('PROTECTED','CANCELLED','EXPIRED');
CREATE TABLE asset_verifications (
    id UUID PRIMARY KEY, asset_id UUID NOT NULL REFERENCES assets(id),
    attempt_id UUID NOT NULL UNIQUE, storage_size_bytes BIGINT, storage_checksum CHAR(64),
    verification_status TEXT NOT NULL CHECK(verification_status IN ('SUCCEEDED','FAILED')),
    error_code TEXT, verified_at TIMESTAMPTZ, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK((verification_status='SUCCEEDED') = (verified_at IS NOT NULL))
);
CREATE TABLE upload_audit_events (
    id UUID PRIMARY KEY, user_id UUID NOT NULL REFERENCES users(id),
    upload_session_id UUID NOT NULL REFERENCES upload_sessions(id),
    event TEXT NOT NULL, error_code TEXT, created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
