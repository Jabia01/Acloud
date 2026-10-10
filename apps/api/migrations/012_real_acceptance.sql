-- Additive release admission evidence. Derived acceptance cannot be client-written.
CREATE TABLE beta_admission_audit(
 id uuid PRIMARY KEY,environment_id uuid NOT NULL REFERENCES beta_environment(id),
 release_id uuid NOT NULL,admission text NOT NULL CHECK(admission IN('REAL_MEDIA','PAYMENTS','FREE_UP_SPACE')),
 accepted boolean NOT NULL,evidence_digest char(64) NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(environment_id,release_id,admission,evidence_digest)
);
CREATE INDEX beta_admission_release ON beta_admission_audit(environment_id,release_id,created_at);
CREATE FUNCTION immutable_beta_admission() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'Admission evidence is append-only'; END $$;
CREATE TRIGGER beta_admission_immutable BEFORE UPDATE OR DELETE ON beta_admission_audit FOR EACH ROW EXECUTE FUNCTION immutable_beta_admission();
