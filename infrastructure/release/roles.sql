-- Operator-reviewed example for dedicated beta DB only, executed by its owner.
-- Never store passwords here. Map real login/IAM principals to these NOLOGIN roles.
CREATE ROLE backup_beta_migrator NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
CREATE ROLE backup_beta_runtime NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
CREATE ROLE backup_beta_operator NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
CREATE ROLE backup_beta_auditreader NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
CREATE SCHEMA backup_beta AUTHORIZATION backup_beta_migrator;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA backup_beta TO backup_beta_runtime,backup_beta_operator,backup_beta_auditreader;
