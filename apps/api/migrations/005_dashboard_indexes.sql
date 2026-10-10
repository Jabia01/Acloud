-- Additive metadata inventory indexes; no customer data changes.
CREATE INDEX assets_protected_order ON assets(user_id,protected_at DESC,id DESC) INCLUDE(media_type,verified_size_bytes,device_id) WHERE status='PROTECTED';
CREATE INDEX assets_protected_media_order ON assets(user_id,media_type,protected_at DESC,id DESC) INCLUDE(verified_size_bytes,device_id) WHERE status='PROTECTED';
