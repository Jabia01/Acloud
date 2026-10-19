# Website thumbnail investigation — 2026-10-19

Read-only staging diagnostic over certificate-verified TLS, using the existing restricted runtime login: 41 protected assets, 3 saved cloud derivatives. Only aggregate counts and session platforms were emitted; no originals or derivative pixels were read. Web and iOS sessions exist separately.

Two independent limitations explain the observed placeholders:

1. Most older items have no saved cloud derivative. Native thumbnails can be local cached previews, while cloud synchronization is opportunistic and limited to loaded protected transfers; it does not migrate all historical backups. An iPad preview success is not proof that its small JPEG has reached the server.
2. The website proxy uses /restore/assets/:id/thumbnail-evidence and /thumbnail. Those routes call previewAsset → gate → ownerTestAsset in restricted owner mode. ownerTestIdentity requires the specifically bound iPad device ID. A browser has its own device/session identity, so this read route is denied even for the same account. This is a policy mismatch, not evidence of failed backup integrity.

Existing access controls have NOT been weakened, and missing derivatives have NOT been backfilled by downloading originals.

Recommended next implementation: introduce a separately specified read-only saved-thumbnail authorization policy for the intended website session, retaining active session/account, exact ownership, privacy state, protected version/source binding, preservation checks, small JPEG integrity and no-store responses. For restricted testing, authorize only the named owner's browser/asset scope with explicit acceptance rather than removing device gates globally. Keep thumbnail writes and full restore/download permissions separate.

Then verify an existing derivative loads on the website. For missing legacy derivatives, use a bounded, explicit native regeneration/sync workflow from verified saved-version bytes, with clear consent before any original download. Do not create “saved backup” thumbnails from current mutable Photos edits. Missing previews never change PROTECTED status or imply originals are missing.

Live browser observation before this investigation: the new Photos/Videos grids render, but visible thumbnails show Preview unavailable. No live website thumbnail success is claimed.
