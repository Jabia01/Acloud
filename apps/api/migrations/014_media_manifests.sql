-- Additive preservation metadata. Existing assets, quota and verification stay authoritative.
CREATE TABLE media_manifest_limits(user_id uuid PRIMARY KEY REFERENCES users(id),created_count integer NOT NULL CHECK(created_count BETWEEN 0 AND 1000000));
CREATE TABLE media_manifests (
 id uuid PRIMARY KEY,user_id uuid NOT NULL REFERENCES users(id),device_id uuid,library_id uuid,
 source_token uuid NOT NULL,source_fingerprint char(64) NOT NULL CHECK(source_fingerprint ~ '^[a-f0-9]{64}$'),
 manifest_version integer NOT NULL CHECK(manifest_version=1),
 media_type text NOT NULL CHECK(media_type IN('image','video','test')),
 kind text NOT NULL CHECK(kind IN('ORDINARY','LIVE_PHOTO','RAW','RAW_JPEG','EDITED','COMPLEX','LEGACY_SINGLE')),
 policy text NOT NULL CHECK(policy='PRESERVE_ALL_AVAILABLE'),
 source_changed boolean NOT NULL DEFAULT false,review_required boolean NOT NULL DEFAULT false,
 legacy boolean NOT NULL DEFAULT false,creation_time timestamptz,modification_time timestamptz,
 pixel_width integer NOT NULL CHECK(pixel_width>=0),pixel_height integer NOT NULL CHECK(pixel_height>=0),
 duration_seconds double precision CHECK(duration_seconds>=0 AND duration_seconds<864000),
 created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(id,user_id),UNIQUE(user_id,device_id,library_id,source_token,source_fingerprint),
 FOREIGN KEY(device_id,user_id) REFERENCES devices(id,user_id)
);
CREATE TABLE media_manifest_resources (
 id uuid PRIMARY KEY,manifest_id uuid NOT NULL,user_id uuid NOT NULL,
 ordinal integer NOT NULL CHECK(ordinal BETWEEN 0 AND 15),role text NOT NULL CHECK(role IN('PRIMARY_STILL','PRIMARY_VIDEO','PAIRED_VIDEO','RAW_ORIGINAL','JPEG_COMPANION','EDITED_RENDER','ADJUSTMENT_DATA','ADJUSTMENT_BASE','DEPTH_DATA','AUXILIARY','UNKNOWN_REQUIRED','UNKNOWN_OPTIONAL','DERIVED_PREVIEW')),
 resource_type integer NOT NULL CHECK(resource_type BETWEEN 1 AND 65535),uti varchar(128) NOT NULL,
 required boolean NOT NULL,class text NOT NULL CHECK(class IN('ORIGINAL','EDITED','AUXILIARY','DERIVED','UNKNOWN')),
 expected_size bigint CHECK(expected_size BETWEEN 1 AND 10737418240),expected_sha256 char(64) CHECK(expected_sha256 ~ '^[a-f0-9]{64}$'),
 asset_id uuid UNIQUE,created_at timestamptz NOT NULL DEFAULT now(),
 CHECK((expected_size IS NULL)=(expected_sha256 IS NULL)),
 UNIQUE(manifest_id,ordinal),FOREIGN KEY(manifest_id,user_id) REFERENCES media_manifests(id,user_id),
 FOREIGN KEY(asset_id,user_id) REFERENCES assets(id,user_id)
);
CREATE INDEX media_manifest_page ON media_manifests(user_id,id);
CREATE INDEX media_manifest_source ON media_manifests(user_id,device_id,library_id,source_token);
CREATE INDEX media_resource_parent ON media_manifest_resources(manifest_id,ordinal);
CREATE VIEW media_manifest_summary AS
 SELECT m.*,q.resource_count,q.required_count,q.protected_count,q.verified_bytes,q.integrity_degraded,
 CASE WHEN m.source_changed THEN 'SOURCE_CHANGED' WHEN m.review_required THEN 'UNSUPPORTED'
 WHEN q.integrity_degraded THEN 'INCOMPLETE'
 WHEN q.required_count>0 AND q.protected_count=q.required_count THEN 'FULLY_PROTECTED'
 WHEN q.protected_count>0 THEN 'PARTIALLY_PROTECTED' ELSE 'NOT_PROTECTED' END AS protection_state
 FROM media_manifests m CROSS JOIN LATERAL (
 SELECT count(*)::int resource_count,count(*) FILTER(WHERE r.required)::int required_count,
 count(*) FILTER(WHERE r.required AND a.status='PROTECTED' AND a.privacy_deleted_at IS NULL
 AND a.expected_checksum=r.expected_sha256 AND a.verified_size_bytes=r.expected_size
 AND a.storage_version_id IS NOT NULL AND a.storage_version_id<>'null'
 AND (a.cleanup_integrity_state<>'INVALID') AND NOT(a.cleanup_integrity_state='UNKNOWN' AND a.cleanup_integrity_checked_at IS NOT NULL)
 AND EXISTS(SELECT 1 FROM asset_verifications v WHERE v.asset_id=a.id AND v.verification_status='SUCCEEDED'
 AND v.storage_size_bytes=r.expected_size AND v.storage_checksum=r.expected_sha256))::int protected_count,
 COALESCE(sum(a.verified_size_bytes) FILTER(WHERE a.status='PROTECTED' AND a.privacy_deleted_at IS NULL),0)::text verified_bytes,
 COALESCE(bool_or(r.required AND (a.cleanup_integrity_state='INVALID' OR a.cleanup_integrity_state='UNKNOWN' AND a.cleanup_integrity_checked_at IS NOT NULL)),false) integrity_degraded
 FROM media_manifest_resources r LEFT JOIN assets a ON a.id=r.asset_id AND a.user_id=r.user_id WHERE r.manifest_id=m.id
 ) q;
-- Legacy single-object evidence is retained as such, not asserted to prove complex PhotoKit completeness.
INSERT INTO media_manifests(id,user_id,device_id,library_id,source_token,source_fingerprint,manifest_version,media_type,kind,policy,legacy,pixel_width,pixel_height)
 SELECT id,user_id,device_id,source_library_id,id,expected_checksum,1,media_type,'LEGACY_SINGLE','PRESERVE_ALL_AVAILABLE',true,0,0 FROM assets;
INSERT INTO media_manifest_resources(id,manifest_id,user_id,ordinal,role,resource_type,uti,required,class,expected_size,expected_sha256,asset_id)
 SELECT id,id,user_id,0,CASE WHEN media_type='video' THEN 'PRIMARY_VIDEO' ELSE 'PRIMARY_STILL' END,
 CASE WHEN media_type='video' THEN 2 ELSE 1 END,'public.data',true,'ORIGINAL',expected_size_bytes,expected_checksum,id FROM assets;
