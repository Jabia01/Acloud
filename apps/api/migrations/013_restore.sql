-- Additive restore controls/telemetry. No protected asset, quota or verification mutation.
INSERT INTO beta_switches(name,blocked) VALUES('restore',true);
ALTER TABLE beta_admission_audit DROP CONSTRAINT beta_admission_audit_admission_check;
ALTER TABLE beta_admission_audit ADD CONSTRAINT beta_admission_audit_admission_check CHECK(admission IN('REAL_MEDIA','PAYMENTS','FREE_UP_SPACE','RESTORE'));
CREATE TABLE restore_events(
 id uuid PRIMARY KEY,user_id uuid NOT NULL REFERENCES users(id),
 code text NOT NULL CHECK(code IN('REQUESTED','DOWNLOAD_OK','DOWNLOAD_FAILED','CHECKSUM_FAILED','SAVE_FAILED','COMPLETED','CLEANUP_FAILED')),
 duration_ms integer CHECK(duration_ms BETWEEN 0 AND 86400000),retry_count integer NOT NULL CHECK(retry_count BETWEEN 0 AND 100),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX restore_event_window ON restore_events(created_at,code);
CREATE INDEX restore_event_account_window ON restore_events(user_id,created_at);
