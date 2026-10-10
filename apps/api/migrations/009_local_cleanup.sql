-- Additive local-cleanup approval metadata. No cloud objects, assets or quota deleted.
ALTER TABLE assets ADD COLUMN source_library_id uuid;
ALTER TABLE assets ADD COLUMN cleanup_integrity_state text NOT NULL DEFAULT 'UNKNOWN' CHECK(cleanup_integrity_state IN ('UNKNOWN','VERIFIED','INVALID'));
ALTER TABLE assets ADD COLUMN cleanup_integrity_checked_at timestamptz;
CREATE TABLE local_cleanup_proofs (
 id uuid PRIMARY KEY, user_id uuid NOT NULL REFERENCES users(id), session_id uuid NOT NULL REFERENCES sessions(id),
 device_id uuid NOT NULL REFERENCES devices(id), library_id uuid NOT NULL,
 token_hash char(64) NOT NULL UNIQUE, asset_ids uuid[] NOT NULL CHECK(cardinality(asset_ids) BETWEEN 1 AND 10),
 snapshot_hash char(64) NOT NULL, state text NOT NULL CHECK(state IN('PREPARING','PREPARED','CONSUMING','CONSUMED','REJECTED')),
 expires_at timestamptz NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), consumed_at timestamptz,
 reported_result text CHECK(reported_result IN('REMOVED','CANCELLED','FAILED','RECONCILE_REQUIRED'))
);
CREATE UNIQUE INDEX local_cleanup_one_active ON local_cleanup_proofs(user_id) WHERE state IN('PREPARING','PREPARED','CONSUMING');
CREATE INDEX local_cleanup_owner ON local_cleanup_proofs(user_id,created_at);
CREATE TABLE local_cleanup_audit (
 id uuid PRIMARY KEY,user_id uuid NOT NULL REFERENCES users(id),proof_id uuid REFERENCES local_cleanup_proofs(id),
 event text NOT NULL CHECK(event IN('PREPARING','PREPARED','CONSUMING','APPROVED','REJECTED','CLIENT_REPORTED')),
 item_count integer NOT NULL CHECK(item_count BETWEEN 1 AND 10),created_at timestamptz NOT NULL DEFAULT now()
);
CREATE OR REPLACE FUNCTION local_cleanup_audit_immutable() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'Cleanup audit is append-only'; END $$;
CREATE TRIGGER local_cleanup_audit_no_update BEFORE UPDATE OR DELETE ON local_cleanup_audit FOR EACH ROW EXECUTE FUNCTION local_cleanup_audit_immutable();
