-- Additive hardening. Existing protected media/quotas and historical migrations are preserved.
ALTER TABLE internal_admin_sessions ADD COLUMN mfa_verified_at timestamptz;
ALTER TABLE internal_admin_sessions ADD COLUMN mfa_credential_id uuid;
CREATE TABLE staff_credentials (
 id uuid PRIMARY KEY,admin_id uuid NOT NULL REFERENCES internal_admins(id),
 kind text NOT NULL CHECK(kind IN('TOTP','PASSKEY')),credential_key text UNIQUE,public_key jsonb,
 encrypted_secret text,last_step bigint NOT NULL DEFAULT -1,sign_count bigint NOT NULL DEFAULT 0,
 created_at timestamptz NOT NULL DEFAULT now(),revoked_at timestamptz,
 CHECK((kind='TOTP' AND encrypted_secret IS NOT NULL) OR (kind='PASSKEY' AND public_key IS NOT NULL AND credential_key IS NOT NULL))
);
ALTER TABLE internal_admin_sessions ADD CONSTRAINT staff_session_credential FOREIGN KEY(mfa_credential_id) REFERENCES staff_credentials(id);
CREATE TABLE staff_challenges(id uuid PRIMARY KEY,admin_id uuid NOT NULL REFERENCES internal_admins(id),challenge_hash char(64) NOT NULL,expires_at timestamptz NOT NULL,used_at timestamptz);
CREATE INDEX staff_challenge_expiry ON staff_challenges(expires_at);
CREATE TABLE distributed_limits(key_hash char(64) PRIMARY KEY,count integer NOT NULL,expires_at timestamptz NOT NULL);
CREATE INDEX distributed_limit_expiry ON distributed_limits(expires_at);
CREATE TABLE durable_jobs (
 id uuid PRIMARY KEY,kind text NOT NULL,dedupe_key char(64) NOT NULL UNIQUE,payload jsonb NOT NULL,
 state text NOT NULL DEFAULT 'PENDING' CHECK(state IN('PENDING','RUNNING','SUCCEEDED','DEAD')),
 attempts integer NOT NULL DEFAULT 0,max_attempts integer NOT NULL DEFAULT 8 CHECK(max_attempts BETWEEN 1 AND 20),
 available_at timestamptz NOT NULL DEFAULT now(),lease_id uuid,lease_until timestamptz,
 last_error_code text,created_at timestamptz NOT NULL DEFAULT now(),finished_at timestamptz
);
CREATE INDEX durable_jobs_ready ON durable_jobs(available_at,id) WHERE state IN('PENDING','RUNNING');
CREATE TABLE durable_schedules(name text PRIMARY KEY,kind text NOT NULL,interval_seconds integer NOT NULL CHECK(interval_seconds BETWEEN 30 AND 86400),next_at timestamptz NOT NULL DEFAULT now(),enabled boolean NOT NULL DEFAULT false);
INSERT INTO durable_schedules(name,kind,interval_seconds) VALUES
 ('maintenance','MAINTENANCE',300),('billing','BILLING_RECONCILE',300),('staff_uploads','ADMIN_UPLOAD_JOBS',60),('integrity_sample','INTEGRITY_SAMPLE',3600),('audit_forward','AUDIT_FORWARD',60),('observability','OBSERVABILITY',60),('privacy_deletion','DELETION_SWEEP',300);
CREATE TABLE security_audit (
 id uuid PRIMARY KEY,actor_type text NOT NULL,actor_id uuid,role text,action text NOT NULL,target_type text NOT NULL,target_id uuid,
 correlation_id uuid NOT NULL,outcome text NOT NULL,summary jsonb NOT NULL DEFAULT '{}',created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX security_audit_order ON security_audit(created_at DESC,id DESC);
CREATE TABLE audit_outbox(id uuid PRIMARY KEY REFERENCES security_audit(id),attempts integer NOT NULL DEFAULT 0,available_at timestamptz NOT NULL DEFAULT now(),delivered_at timestamptz,last_error_code text);
CREATE INDEX audit_outbox_pending ON audit_outbox(available_at,id) WHERE delivered_at IS NULL;
CREATE FUNCTION append_security_outbox() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN INSERT INTO audit_outbox(id) VALUES(NEW.id);RETURN NEW;END $$;
CREATE TRIGGER security_audit_forward AFTER INSERT ON security_audit FOR EACH ROW EXECUTE FUNCTION append_security_outbox();
CREATE FUNCTION forbid_hardening_audit_change() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'Audit is append only';END $$;
CREATE TRIGGER security_audit_immutable BEFORE UPDATE OR DELETE ON security_audit FOR EACH ROW EXECUTE FUNCTION forbid_hardening_audit_change();
CREATE TRIGGER auth_audit_immutable BEFORE UPDATE OR DELETE ON auth_audit_events FOR EACH ROW EXECUTE FUNCTION forbid_hardening_audit_change();
CREATE TRIGGER operational_security_immutable BEFORE UPDATE OR DELETE ON operational_security_events FOR EACH ROW EXECUTE FUNCTION forbid_hardening_audit_change();
CREATE TABLE alert_events(id uuid PRIMARY KEY,code text NOT NULL,severity text NOT NULL CHECK(severity IN('WARNING','CRITICAL')),window_key text NOT NULL,summary jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),delivered_at timestamptz,UNIQUE(code,window_key));
CREATE TABLE metric_events(id uuid PRIMARY KEY,code text NOT NULL,value bigint NOT NULL DEFAULT 1,duration_ms integer,created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX metric_event_window ON metric_events(created_at,code);
ALTER TABLE users ADD COLUMN privacy_state text NOT NULL DEFAULT 'ACTIVE' CHECK(privacy_state IN('ACTIVE','DELETION_COOLDOWN','DELETION_IN_PROGRESS','DELETED','DELETION_FAILED_REVIEW'));
ALTER TABLE users ADD COLUMN abuse_review boolean NOT NULL DEFAULT false;
CREATE TABLE deletion_requests(id uuid PRIMARY KEY,user_id uuid NOT NULL REFERENCES users(id),state text NOT NULL CHECK(state IN('COOLDOWN','IN_PROGRESS','CANCELLED','DELETED','FAILED_REVIEW')),cancel_hash char(64),not_before timestamptz NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),finished_at timestamptz,requested_session_id uuid NOT NULL REFERENCES sessions(id),billing_cancelled boolean NOT NULL DEFAULT false);
CREATE UNIQUE INDEX deletion_active ON deletion_requests(user_id) WHERE state IN('COOLDOWN','IN_PROGRESS','FAILED_REVIEW');
CREATE TABLE deletion_objects(request_id uuid NOT NULL REFERENCES deletion_requests(id),asset_id uuid NOT NULL REFERENCES assets(id),version_id text NOT NULL,state text NOT NULL DEFAULT 'PENDING' CHECK(state IN('PENDING','DELETED')),PRIMARY KEY(request_id,asset_id,version_id));
CREATE TABLE privacy_exports(id uuid PRIMARY KEY,user_id uuid NOT NULL REFERENCES users(id),state text NOT NULL DEFAULT 'PENDING' CHECK(state IN('PENDING','READY','EXPIRED','FAILED')),created_at timestamptz NOT NULL DEFAULT now(),expires_at timestamptz NOT NULL,payload jsonb);
CREATE INDEX privacy_export_owner ON privacy_exports(user_id,created_at DESC);
CREATE FUNCTION mirror_existing_audit() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE e jsonb:=to_jsonb(NEW); actor uuid; role_value text; action_value text; target uuid;
BEGIN
 actor:=COALESCE((e->>'admin_id')::uuid,(e->>'user_id')::uuid);role_value:=e->>'role';
 action_value:=COALESCE(e->>'action',e->>'event',e->>'code','AUDIT_EVENT');
 target:=COALESCE((e->>'target_id')::uuid,(e->>'upload_session_id')::uuid,(e->>'user_id')::uuid);
 INSERT INTO security_audit(id,actor_type,actor_id,role,action,target_type,target_id,correlation_id,outcome,summary,created_at)
 VALUES(NEW.id,CASE WHEN e->>'admin_id' IS NOT NULL THEN 'STAFF' ELSE 'ACCOUNT' END,actor,role_value,action_value,TG_TABLE_NAME,target,CASE WHEN e->>'correlation_id' ~* '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$' THEN (e->>'correlation_id')::uuid ELSE NEW.id END,'RECORDED',jsonb_build_object('source',TG_TABLE_NAME,'before',jsonb_strip_nulls(jsonb_build_object('status',e->'before_summary'->'status','role',e->'before_summary'->'role','quotaBytes',e->'before_summary'->'quotaBytes')),'after',jsonb_strip_nulls(jsonb_build_object('status',e->'after_summary'->'status','role',e->'after_summary'->'role','quotaBytes',e->'after_summary'->'quotaBytes'))),NEW.created_at);
 RETURN NEW;
END $$;
CREATE TRIGGER mirror_staff_audit AFTER INSERT ON internal_admin_audit FOR EACH ROW EXECUTE FUNCTION mirror_existing_audit();
CREATE TRIGGER mirror_billing_audit AFTER INSERT ON billing_audit FOR EACH ROW EXECUTE FUNCTION mirror_existing_audit();
CREATE TRIGGER mirror_auth_audit AFTER INSERT ON auth_audit_events FOR EACH ROW EXECUTE FUNCTION mirror_existing_audit();
CREATE TRIGGER mirror_security_event AFTER INSERT ON operational_security_events FOR EACH ROW EXECUTE FUNCTION mirror_existing_audit();
CREATE TRIGGER upload_audit_immutable BEFORE UPDATE OR DELETE ON upload_audit_events FOR EACH ROW EXECUTE FUNCTION forbid_hardening_audit_change();
CREATE TRIGGER mirror_upload_audit AFTER INSERT ON upload_audit_events FOR EACH ROW EXECUTE FUNCTION mirror_existing_audit();
CREATE TABLE durable_email(id uuid PRIMARY KEY,user_id uuid REFERENCES users(id),kind text NOT NULL,encrypted_payload text NOT NULL,state text NOT NULL DEFAULT 'PENDING' CHECK(state IN('PENDING','SENT','DEAD')),created_at timestamptz NOT NULL DEFAULT now(),sent_at timestamptz);
ALTER TABLE durable_schedules ADD COLUMN cursor_id uuid;
ALTER TABLE deletion_requests ADD COLUMN manifest_complete boolean NOT NULL DEFAULT false;
ALTER TABLE deletion_requests ADD COLUMN manifest_cursor uuid;
-- Historical verification stays immutable in meaning; explicit account deletion is a separate tombstone.
ALTER TABLE assets ADD COLUMN privacy_deleted_at timestamptz;
CREATE INDEX assets_integrity_sample ON assets(cleanup_integrity_checked_at,id) WHERE status='PROTECTED' AND privacy_deleted_at IS NULL;
CREATE INDEX cleanup_jobs_owner_binding ON local_cleanup_proofs(user_id,device_id,library_id);

-- Bound general metadata pagination used by internal operations.
CREATE INDEX assets_owner_created_order ON assets(user_id,created_at DESC,id DESC) INCLUDE(status,expected_size_bytes);

ALTER TABLE deletion_requests ADD COLUMN final_scan_cursor uuid;
