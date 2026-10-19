-- Apply only after migrations 001–012 with migration role/search_path=backup_beta.

GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA backup_beta TO backup_beta_runtime;
REVOKE INSERT,UPDATE,DELETE ON backup_beta.schema_migrations,backup_beta.beta_environment,backup_beta.beta_acceptance FROM backup_beta_runtime;
REVOKE UPDATE,DELETE ON backup_beta.security_audit,backup_beta.internal_admin_audit,backup_beta.beta_admission_audit,backup_beta.auth_audit_events,backup_beta.upload_audit_events,backup_beta.billing_audit,backup_beta.local_cleanup_audit FROM backup_beta_runtime;
GRANT SELECT ON ALL TABLES IN SCHEMA backup_beta TO backup_beta_operator;
GRANT INSERT,UPDATE ON backup_beta.beta_environment,backup_beta.beta_acceptance,backup_beta.staff_credentials,backup_beta.internal_admin_sessions TO backup_beta_operator;
GRANT INSERT ON backup_beta.security_audit TO backup_beta_operator;
GRANT SELECT ON backup_beta.security_audit,backup_beta.internal_admin_audit,backup_beta.beta_admission_audit TO backup_beta_auditreader;
-- Reapply reviewed grants after additive migrations; do not grant ownership/BYPASSRLS
-- or blanket operator UPDATE on user/assets/object state. External IAM review required.
-- Derivative image bytes are customer data, not staff-console metadata.
DO $$ BEGIN
 IF to_regclass('backup_beta.saved_thumbnails') IS NOT NULL THEN
  REVOKE ALL ON backup_beta.saved_thumbnails FROM backup_beta_operator,backup_beta_auditreader;
  REVOKE UPDATE ON backup_beta.saved_thumbnails FROM backup_beta_runtime;
 END IF;
END $$;
