# Private saved-version thumbnails

Scope: explicitly requested derived-preview improvement, independent of protection, restore-fidelity acceptance and PhotoKit discovery. No automatic original uploads/downloads or deletion of originals.

Each thumbnail is a metadata-free JPEG, at most 240 pixels per side and 40 KiB, generated only from verified saved-version bytes. The API stores one immutable derivative per asset/version/source checksum privately in PostgreSQL, alongside version metadata. This avoids permanent object URLs or new storage credentials and includes derivatives in existing encrypted database backups. Account budget: 32 MiB of derivatives; creation rate: 600 per hour. This is bounded beta storage, not a replacement for original object storage or a claim of backend pixel-to-original verification. The authenticated owner supplies the derived pixels; original protection/size/checksum are never modified.

Reads and writes retain the existing active account/session/device, ownership, protected-resource, preservation completeness, storage binding and restore/download release gates. Thumbnail bytes get their own SHA256. Privacy soft deletion removes the derivative in the same database transaction; final account deletion and tombstone replay purge it too. Database-derived backup copies follow the existing backup retention policy.

Native app automatically checks the local account/asset/source-checksum cache first, then requests only the small cloud derivative over Wi-Fi, with bounded concurrency and negative-result retry delay. Missing legacy derivatives never trigger an automatic original download. Explicit original fallback remains bounded and verified; it can publish a derivative for future use. New locally captured thumbnails sync opportunistically during backup refresh, retry after failures and cannot block backup completion. A cache hit does not modify saved media. Missing derived bytes are not a protection failure.

No push or hosted migration is implied by implementation. Deployment must include additive migration 016 before enabling hosted use; verify on-device small-download/cache behavior separately.

Native local capture retains its existing 256 MiB original-size safety bound. Originals above that bound and unsupported preservation formats do not gain an automatic full-original fallback. Synchronization covers the currently loaded protected transfer page and retries opportunistically while the app runs; this is not an always-running background migration of all older backups. The current website preview remains its separately bounded, explicit viewing flow.

The lifecycle worker receives DELETE plus SELECT of asset_id/user_id only, so deletion jobs can purge derivatives without reading JPEG bytes. Runtime and independent backup access follow the existing dedicated-role model.
