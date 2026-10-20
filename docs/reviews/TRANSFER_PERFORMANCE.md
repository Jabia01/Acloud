# Transfer performance improvements — 20 October 2026

## Implementation

- Ordinary backup queue: at most two scheduled files in flight, with two multipart parts per file. Each part gets fresh scoped authorization; batches reconcile against storage before completion. A failed batch drains before temporary-file cleanup. Existing manual pause, network policy, durable retry and server protection checks remain enforced.
- Parallel part requests share a lock-initialized URLSession; maximum connections per storage host is four. This avoids concurrent initialization of the same background-session identifier.
- Configured S3/B2 providers reuse their clients by endpoint purpose and retry budget for the lifetime of the provider. Shutdown closes them. Environment-only legacy clients retain their old lifecycle. Every operation still checks private-bucket policy; version pinning and full server SHA-256 verification are retained.
- Native restore streams bytes to private partial files. Transient network errors receive up to two immediate retries. Range requests reuse a partial only for the same origin, exact object path, immutable version and expected length. Refreshed capabilities can resume across downloader instances. No signed URL or credentials are persisted. HTTP 206 content ranges and byte counts must match; HTTP 200 replaces rather than appends. Unversioned URLs restart. Integrity failures clear the partial; explicit restore cancellation clears partials and binding files. Final size/SHA-256 verification and server authorization checks still precede saving to Photos.
- Live Photo/compound restore downloads at most two resources concurrently. On retry, previously completed resources are reused only after renewed server authorization and a fresh checksum check. Resources are still validated and saved together as one explicit restore.
- Native diagnostics distinguish preparation, part-byte upload, server verification and download duration. API diagnostics contain storage operation duration and full verification duration, without keys, URLs, filenames, asset IDs, credentials or media content. Existing Upload / Verify / Protected UI stages remain in use.

## Validation

Generated fixtures only; no customer original or payment was mutated.

- BackupEngine: 115 tests passed, including bounded file and part concurrency, interrupted multipart recovery, manual controls and background-session regressions.
- RestoreEngine: 111 tests passed, including streamed network interruption/range recovery, refreshed authorization, version changes, ignored/invalid ranges, oversized bodies, symlinks, partial cleanup and compound-resource reuse.
- Storage-provider contract suite: 59 tests passed; client lifecycle/retry isolation and private-bucket recheck included.
- API Jest: 7 suites / 28 tests passed. Initial restricted run could not open the local test server; rerun with local-server permission passed.
- API TypeScript build passed.
- Full unsigned Debug iPad app build for the iOS simulator passed.
- Secret heuristic: 459 Git-visible files, zero unexpected findings. The pre-existing untracked node_modules directory symlink was excluded from this source scan.

## Limits / deployment

These are local improvements, not an on-device bandwidth benchmark. Wi-Fi/iCloud preparation, actual uplink/downlink capacity, storage distance, iOS scheduling and full-object verification can still affect elapsed time. Per-device performance acceptance remains pending after installation.

No push, hosted deployment, device installation or migration was performed for this task. There is also an earlier local downgrade/export commit with migration 018; publishing the combined branch requires that migration to be applied first, per DOWNGRADE_EXPORT_IMPLEMENTATION.md.
