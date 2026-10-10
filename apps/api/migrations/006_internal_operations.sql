-- Separate staff identity/session boundary. Additive only; no media changes.
CREATE TABLE internal_admins (
 id UUID PRIMARY KEY, email TEXT NOT NULL, email_normalized TEXT NOT NULL UNIQUE,
 password_hash TEXT NOT NULL, role TEXT NOT NULL CHECK(role IN ('SUPERADMIN','SUPPORT','READ_ONLY_OPS')),
 status TEXT NOT NULL DEFAULT 'ACTIVE' CHECK(status IN ('ACTIVE','DISABLED')),
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE internal_admin_sessions (
 id UUID PRIMARY KEY, admin_id UUID NOT NULL REFERENCES internal_admins(id), token_hash CHAR(64) NOT NULL UNIQUE,
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(), last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 expires_at TIMESTAMPTZ NOT NULL, revoked_at TIMESTAMPTZ
);
CREATE INDEX internal_sessions_active ON internal_admin_sessions(admin_id) WHERE revoked_at IS NULL;
CREATE TABLE internal_admin_control(id BOOLEAN PRIMARY KEY CHECK(id));
INSERT INTO internal_admin_control VALUES(true);
CREATE TABLE internal_admin_audit (
 id UUID PRIMARY KEY, admin_id UUID NOT NULL REFERENCES internal_admins(id), role TEXT NOT NULL,
 action TEXT NOT NULL, target_type TEXT NOT NULL, target_id UUID NOT NULL, reason TEXT NOT NULL,
 correlation_id UUID NOT NULL, request_hash CHAR(64) NOT NULL, before_summary JSONB NOT NULL,
 after_summary JSONB NOT NULL, result JSONB NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 UNIQUE(admin_id,correlation_id)
);
CREATE INDEX internal_audit_order ON internal_admin_audit(created_at DESC,id DESC);
CREATE INDEX internal_audit_actor_order ON internal_admin_audit(admin_id,created_at DESC,id DESC);
CREATE FUNCTION reject_internal_audit_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'Internal audit is append only'; END $$;
CREATE TRIGGER internal_audit_immutable BEFORE UPDATE OR DELETE ON internal_admin_audit FOR EACH ROW EXECUTE FUNCTION reject_internal_audit_change();
CREATE TABLE operational_security_events (
 id UUID PRIMARY KEY, code TEXT NOT NULL, user_id UUID REFERENCES users(id), admin_id UUID REFERENCES internal_admins(id),
 created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX operations_security_order ON operational_security_events(created_at DESC,id DESC);
CREATE TABLE internal_upload_jobs (
 id UUID PRIMARY KEY, admin_id UUID NOT NULL REFERENCES internal_admins(id), admin_session_id UUID NOT NULL REFERENCES internal_admin_sessions(id),
 upload_session_id UUID NOT NULL REFERENCES upload_sessions(id), reason TEXT NOT NULL,
 kind TEXT NOT NULL CHECK(kind IN ('VERIFY','ABORT')), claimed_at TIMESTAMPTZ,
 state TEXT NOT NULL DEFAULT 'PENDING' CHECK(state IN ('PENDING','RUNNING','SUCCEEDED','FAILED','DENIED')),
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(), finished_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX internal_jobs_active ON internal_upload_jobs(upload_session_id) WHERE state IN ('PENDING','RUNNING');
CREATE INDEX internal_jobs_pending ON internal_upload_jobs(created_at,id) WHERE state='PENDING';
CREATE INDEX users_operations_order ON users(created_at DESC,id DESC);
CREATE INDEX upload_operations_order ON upload_sessions(created_at DESC,id DESC);
CREATE INDEX device_operations_order ON devices(user_id,created_at DESC,id DESC);
CREATE INDEX internal_jobs_upload_order ON internal_upload_jobs(upload_session_id,created_at DESC,id DESC);
