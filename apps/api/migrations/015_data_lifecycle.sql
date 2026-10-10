-- Additive lifecycle control. No historical migration or media record is rewritten.
CREATE TABLE account_lifecycle(user_id uuid PRIMARY KEY REFERENCES users(id),state text NOT NULL DEFAULT 'ACTIVE' CHECK(state IN('ACTIVE','PAYMENT_PAST_DUE','GRACE_PERIOD','OVER_QUOTA','CANCELED_SUBSCRIPTION','DELETION_REQUESTED','DELETION_COOLDOWN','DELETION_IN_PROGRESS','DELETION_PARTIAL','DELETED','LEGAL_HOLD','SECURITY_HOLD','RECOVERY_REVIEW')),version integer NOT NULL DEFAULT 1,updated_at timestamptz NOT NULL DEFAULT now());
INSERT INTO account_lifecycle(user_id,state) SELECT id,CASE privacy_state WHEN 'DELETED' THEN 'DELETED' WHEN 'DELETION_IN_PROGRESS' THEN 'DELETION_IN_PROGRESS' WHEN 'DELETION_FAILED_REVIEW' THEN 'RECOVERY_REVIEW' WHEN 'DELETION_COOLDOWN' THEN 'DELETION_COOLDOWN' ELSE 'ACTIVE' END FROM users;
CREATE TABLE data_holds(id uuid PRIMARY KEY,user_id uuid NOT NULL REFERENCES users(id),kind text NOT NULL CHECK(kind IN('LEGAL_HOLD','SECURITY_HOLD')),reason_code text NOT NULL,created_by uuid NOT NULL REFERENCES internal_admins(id),created_at timestamptz NOT NULL DEFAULT now(),released_at timestamptz,released_by uuid REFERENCES internal_admins(id));
CREATE INDEX lifecycle_holds_active ON data_holds(user_id) WHERE released_at IS NULL;
ALTER TABLE deletion_requests ADD COLUMN lifecycle_version integer NOT NULL DEFAULT 2;
ALTER TABLE deletion_requests ADD COLUMN idempotency_key uuid;
ALTER TABLE deletion_requests ADD COLUMN reauthenticated_at timestamptz;
ALTER TABLE deletion_requests ADD COLUMN execution_started_at timestamptz;
CREATE UNIQUE INDEX deletion_request_idempotency ON deletion_requests(user_id,idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE TABLE account_deletion_manifest(request_id uuid PRIMARY KEY REFERENCES deletion_requests(id),user_id uuid NOT NULL REFERENCES users(id),version integer NOT NULL DEFAULT 1 CHECK(version=1),state text NOT NULL DEFAULT 'BUILDING' CHECK(state IN('BUILDING','REVIEW','FINALIZED','EXECUTING','COMPLETE')),cursor_id uuid,final_cursor_id uuid,asset_count bigint NOT NULL DEFAULT 0,object_count bigint NOT NULL DEFAULT 0,expected_bytes bigint NOT NULL DEFAULT 0,digest char(64) NOT NULL DEFAULT repeat('0',64),created_at timestamptz NOT NULL DEFAULT now(),finalized_at timestamptz,completed_at timestamptz,UNIQUE(request_id,user_id));
CREATE TABLE account_deletion_manifest_items(id uuid PRIMARY KEY,request_id uuid NOT NULL,user_id uuid NOT NULL,asset_id uuid NOT NULL REFERENCES assets(id),resource_id uuid REFERENCES media_manifest_resources(id),kind text NOT NULL CHECK(kind IN('OBJECT','MULTIPART','REVIEW')),provider text NOT NULL,binding char(64),object_key text NOT NULL,provider_version_id text NOT NULL,state text NOT NULL DEFAULT 'PENDING' CHECK(state IN('PENDING','ATTEMPTING','DELETED','REVIEW','RETAINED')),attempts integer NOT NULL DEFAULT 0,last_error_code text,lease_id uuid,lease_until timestamptz,deleted_at timestamptz,created_at timestamptz NOT NULL DEFAULT now(),FOREIGN KEY(request_id,user_id) REFERENCES account_deletion_manifest(request_id,user_id),UNIQUE(request_id,asset_id,kind,provider_version_id));
CREATE INDEX lifecycle_item_claim ON account_deletion_manifest_items(request_id,id) WHERE state IN('PENDING','ATTEMPTING');
CREATE INDEX lifecycle_item_owner ON account_deletion_manifest_items(user_id,asset_id);
CREATE TABLE deletion_events(id uuid PRIMARY KEY,user_id uuid NOT NULL,request_id uuid,event text NOT NULL,item_id uuid,attempt integer,actor_id uuid,created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX lifecycle_events_request ON deletion_events(request_id,created_at,id);
CREATE TRIGGER lifecycle_events_immutable BEFORE UPDATE OR DELETE ON deletion_events FOR EACH ROW EXECUTE FUNCTION forbid_hardening_audit_change();
CREATE TABLE account_deletion_tombstones(user_id uuid PRIMARY KEY,deletion_id uuid NOT NULL UNIQUE,completed_at timestamptz NOT NULL,manifest_digest char(64) NOT NULL,lifecycle_version integer NOT NULL CHECK(lifecycle_version=2),identity_hmac char(64),identity_expires_at timestamptz,archive_digest char(64) NOT NULL,created_at timestamptz NOT NULL DEFAULT now());
CREATE TRIGGER lifecycle_tombstones_immutable BEFORE UPDATE OR DELETE ON account_deletion_tombstones FOR EACH ROW EXECUTE FUNCTION forbid_hardening_audit_change();
CREATE TABLE lifecycle_replays(id uuid PRIMARY KEY,user_id uuid NOT NULL,tombstone_digest char(64) NOT NULL,state text NOT NULL CHECK(state IN('SUPPRESSED','REDELETION_QUEUED','REVIEW')),created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE privacy_export_jobs(id uuid PRIMARY KEY REFERENCES privacy_exports(id),user_id uuid NOT NULL REFERENCES users(id),schema_version integer NOT NULL DEFAULT 2,category integer NOT NULL DEFAULT 0,cursor_id uuid,item_count bigint NOT NULL DEFAULT 0,state text NOT NULL DEFAULT 'BUILDING' CHECK(state IN('BUILDING','READY','EXPIRED','FAILED')),generated_at timestamptz,expires_at timestamptz NOT NULL,manifest jsonb);
CREATE TABLE privacy_export_chunks(export_id uuid NOT NULL REFERENCES privacy_export_jobs(id),sequence integer NOT NULL,category text NOT NULL,item_count integer NOT NULL CHECK(item_count BETWEEN 0 AND 500),sha256 char(64) NOT NULL,encrypted_payload text NOT NULL,PRIMARY KEY(export_id,sequence));
CREATE INDEX lifecycle_exports_owner ON privacy_export_jobs(user_id,id);
CREATE TABLE retention_policies(category text PRIMARY KEY,retention_class text NOT NULL CHECK(retention_class IN('DELETE','ANONYMIZE','RETAIN','TOMBSTONE')),duration_seconds bigint,legal_approval text NOT NULL DEFAULT 'PENDING',security_override boolean NOT NULL DEFAULT true,enabled boolean NOT NULL DEFAULT false);
INSERT INTO retention_policies(category,retention_class) VALUES ('upload_sessions','RETAIN'),('multipart_sessions','RETAIN'),('failed_jobs','RETAIN'),('audit_logs','RETAIN'),('auth_events','RETAIN'),('security_events','RETAIN'),('billing_records','RETAIN'),('deletion_records','RETAIN'),('tombstones','TOMBSTONE'),('privacy_exports','DELETE'),('temporary_artifacts','RETAIN'),('restore_temp_files','RETAIN'),('cleanup_proofs','RETAIN'),('support_logs','RETAIN'),('invites','RETAIN');
CREATE TABLE retention_runs(id uuid PRIMARY KEY,mode text NOT NULL CHECK(mode IN('DRY_RUN','APPLY')),state text NOT NULL CHECK(state IN('PLANNED','COMPLETE','FAILED')),policy_digest char(64) NOT NULL,candidates integer NOT NULL DEFAULT 0,processed integer NOT NULL DEFAULT 0,summary jsonb NOT NULL DEFAULT '{}',created_at timestamptz NOT NULL DEFAULT now(),finished_at timestamptz);
CREATE FUNCTION lifecycle_prevent_resurrection() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.status='ACTIVE' AND EXISTS(SELECT 1 FROM account_deletion_tombstones t WHERE t.user_id=NEW.id) THEN RAISE EXCEPTION 'Tombstoned account cannot activate';END IF;RETURN NEW;END $$;
CREATE TRIGGER lifecycle_account_fence BEFORE INSERT OR UPDATE ON users FOR EACH ROW EXECUTE FUNCTION lifecycle_prevent_resurrection();
CREATE FUNCTION lifecycle_suppress_tombstone() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
 UPDATE users SET status='DISABLED',privacy_state='DELETED',beta_state='EXITED_BETA' WHERE id=NEW.user_id;
 UPDATE sessions SET revoked_at=COALESCE(revoked_at,now()) WHERE user_id=NEW.user_id;
 UPDATE assets SET privacy_deleted_at=COALESCE(privacy_deleted_at,now()) WHERE user_id=NEW.user_id;
 UPDATE upload_sessions SET reservation_released_at=COALESCE(reservation_released_at,now()) WHERE user_id=NEW.user_id;
 UPDATE development_entitlements SET protected_bytes=0,reserved_bytes=0 WHERE user_id=NEW.user_id;
 UPDATE subscriptions SET status='CANCELED',cancel_at_period_end=true WHERE user_id=NEW.user_id;
 RETURN NEW;END $$;
CREATE TRIGGER lifecycle_tombstone_suppression AFTER INSERT ON account_deletion_tombstones FOR EACH ROW EXECUTE FUNCTION lifecycle_suppress_tombstone();

CREATE FUNCTION lifecycle_initialize_account() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN INSERT INTO account_lifecycle(user_id,state) VALUES(NEW.id,'ACTIVE') ON CONFLICT DO NOTHING;RETURN NEW;END $$;
CREATE TRIGGER lifecycle_new_account AFTER INSERT ON users FOR EACH ROW EXECUTE FUNCTION lifecycle_initialize_account();
ALTER TABLE account_deletion_manifest ADD COLUMN archive_ready boolean NOT NULL DEFAULT false;
CREATE TABLE lifecycle_redelete_items(id uuid PRIMARY KEY,user_id uuid NOT NULL,deletion_id uuid NOT NULL,asset_id uuid NOT NULL,kind text NOT NULL CHECK(kind IN('OBJECT','MULTIPART')),provider text NOT NULL,binding char(64),object_key text NOT NULL,provider_version_id text NOT NULL,state text NOT NULL DEFAULT 'PENDING' CHECK(state IN('PENDING','DELETED','REVIEW')),attempts integer NOT NULL DEFAULT 0,created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(deletion_id,asset_id,kind,provider_version_id));
CREATE INDEX lifecycle_redelete_claim ON lifecycle_redelete_items(state,id);
ALTER TABLE lifecycle_replays ADD COLUMN inventory_verified boolean NOT NULL DEFAULT false;
CREATE UNIQUE INDEX lifecycle_replay_identity ON lifecycle_replays(user_id,tombstone_digest);
CREATE TABLE lifecycle_notifications(request_id uuid NOT NULL REFERENCES deletion_requests(id),event text NOT NULL CHECK(event IN('REQUESTED','CANCELLED','PARTIAL','COMPLETED')),email_id uuid NOT NULL UNIQUE REFERENCES durable_email(id),created_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(request_id,event));
INSERT INTO durable_schedules(name,kind,interval_seconds) VALUES('lifecycle-retention','RETENTION',86400);
-- Billing/quota projections never create deletion work or authorize object deletion.
CREATE FUNCTION lifecycle_refresh_state(target uuid) RETURNS void LANGUAGE plpgsql AS $$ DECLARE s text; BEGIN
 IF NOT EXISTS(SELECT 1 FROM users WHERE id=target AND privacy_state='ACTIVE') THEN RETURN;END IF;
 SELECT kind INTO s FROM data_holds WHERE user_id=target AND released_at IS NULL ORDER BY CASE kind WHEN 'LEGAL_HOLD' THEN 0 ELSE 1 END LIMIT 1;
 IF s IS NULL THEN
  IF EXISTS(SELECT 1 FROM development_entitlements WHERE user_id=target AND protected_bytes+reserved_bytes>quota_bytes) THEN s:='OVER_QUOTA';
  ELSIF EXISTS(SELECT 1 FROM subscriptions WHERE user_id=target AND status='GRACE_PERIOD') THEN s:='GRACE_PERIOD';
  ELSIF EXISTS(SELECT 1 FROM subscriptions WHERE user_id=target AND status='PAST_DUE') THEN s:='PAYMENT_PAST_DUE';
  ELSIF EXISTS(SELECT 1 FROM subscriptions WHERE user_id=target AND status IN('CANCELED','EXPIRED')) THEN s:='CANCELED_SUBSCRIPTION';
  ELSE s:='ACTIVE';END IF;
 END IF;
 INSERT INTO account_lifecycle(user_id,state) VALUES(target,s) ON CONFLICT(user_id) DO UPDATE SET state=EXCLUDED.state,version=account_lifecycle.version+1,updated_at=now() WHERE account_lifecycle.state IS DISTINCT FROM EXCLUDED.state;
END $$;
CREATE FUNCTION lifecycle_subscription_projection() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM lifecycle_refresh_state(NEW.user_id);RETURN NEW;END $$;
CREATE TRIGGER lifecycle_subscription_state AFTER INSERT OR UPDATE ON subscriptions FOR EACH ROW EXECUTE FUNCTION lifecycle_subscription_projection();
CREATE TRIGGER lifecycle_quota_state AFTER INSERT OR UPDATE ON development_entitlements FOR EACH ROW EXECUTE FUNCTION lifecycle_subscription_projection();
CREATE INDEX lifecycle_inventory_page ON account_deletion_manifest_items(request_id,id);
CREATE INDEX lifecycle_export_expiry ON privacy_export_jobs(expires_at,id) WHERE state<>'EXPIRED';
ALTER TABLE retention_policies ADD CONSTRAINT retention_duration_safe CHECK(duration_seconds IS NULL OR duration_seconds BETWEEN 3600 AND 315576000);
ALTER TABLE retention_policies ADD CONSTRAINT retention_approval_safe CHECK(legal_approval IN('PENDING','APPROVED','REJECTED'));
UPDATE retention_policies SET duration_seconds=86400 WHERE category='privacy_exports';
ALTER TABLE retention_policies ADD CONSTRAINT retention_enable_safe CHECK(NOT enabled OR legal_approval='APPROVED' AND (retention_class NOT IN('DELETE','ANONYMIZE') OR duration_seconds IS NOT NULL));
ALTER TABLE users ADD COLUMN lifecycle_pii_version integer NOT NULL DEFAULT 0 CHECK(lifecycle_pii_version IN(0,2));
CREATE FUNCTION lifecycle_hold_immutable() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Hold evidence is retained';END IF;
 IF ROW(NEW.id,NEW.user_id,NEW.kind,NEW.reason_code,NEW.created_by,NEW.created_at) IS DISTINCT FROM ROW(OLD.id,OLD.user_id,OLD.kind,OLD.reason_code,OLD.created_by,OLD.created_at) OR OLD.released_at IS NOT NULL OR NEW.released_at IS NULL OR NEW.released_by IS NULL THEN RAISE EXCEPTION 'Hold history cannot be rewritten';END IF;
 RETURN NEW;END $$;
CREATE TRIGGER lifecycle_hold_evidence BEFORE UPDATE OR DELETE ON data_holds FOR EACH ROW EXECUTE FUNCTION lifecycle_hold_immutable();
