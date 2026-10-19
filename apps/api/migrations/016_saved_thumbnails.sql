-- Small private derivatives only; no original/protection/quota mutation.
CREATE TABLE saved_thumbnails (
 asset_id uuid PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE,
 user_id uuid NOT NULL REFERENCES users(id),
 cloud_version_id text NOT NULL CHECK(cloud_version_id ~ '^[a-f0-9]{64}$'),
 source_sha256 text NOT NULL CHECK(source_sha256 ~ '^[a-f0-9]{64}$'),
 thumbnail_sha256 text NOT NULL CHECK(thumbnail_sha256 ~ '^[a-f0-9]{64}$'),
 jpeg bytea NOT NULL CHECK(octet_length(jpeg) BETWEEN 4 AND 40960),
 width integer NOT NULL CHECK(width BETWEEN 1 AND 240),
 height integer NOT NULL CHECK(height BETWEEN 1 AND 240),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX saved_thumbnails_account ON saved_thumbnails(user_id,created_at);
CREATE FUNCTION remove_private_thumbnail() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.privacy_deleted_at IS NOT NULL THEN DELETE FROM saved_thumbnails WHERE asset_id=NEW.id; END IF;
 RETURN NEW;
END;
$$;
CREATE TRIGGER asset_private_thumbnail_deletion AFTER UPDATE OF privacy_deleted_at ON assets
FOR EACH ROW EXECUTE FUNCTION remove_private_thumbnail();
REVOKE ALL ON saved_thumbnails FROM PUBLIC;
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='backup_beta_runtime') THEN
  GRANT SELECT,INSERT,DELETE ON saved_thumbnails TO backup_beta_runtime;
 END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='backup_beta_worker') THEN
  GRANT DELETE ON saved_thumbnails TO backup_beta_worker;
  GRANT SELECT(asset_id,user_id) ON saved_thumbnails TO backup_beta_worker;
 END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='backup_beta_operator') THEN
  REVOKE ALL ON saved_thumbnails FROM backup_beta_operator;
 END IF;
END $$;
