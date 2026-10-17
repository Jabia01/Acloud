# Verified media previews and edited-photo preservation

Preview loading uses `/restore/assets/:id/preview`, `/preview/authorize` and `/preview/recheck`. Existing full restore endpoints and complex fidelity gates are unchanged. Preview proofs have `VERIFIED_PREVIEW_RESOURCE` policy; the native restore planner and queue reject that policy for Photos saves.

The server requires the authenticated device/session, existing owner-test or beta download gates, private storage binding and successful size/checksum verification. Originals must be at most 32 MiB. A manifest-backed resource must belong to complete, unchanged, non-degraded preservation with no review flag. Only ordinary/legacy, Live Photo or edited manifests and primary still/video or edited-render roles qualify. Adjustment recipes, paired motion and unknown/RAW bundles cannot be downloaded through this route. Authorization pins the immutable version and checks current storage size/version; recheck repeats the preservation checks.

PhotoKit capture sorts public resource descriptors by type/UTI consistently for snapshots and streaming; ambiguous duplicate identities are rejected. This prevents enumeration-order changes from being treated as source edits. Modification dates, dimensions, resource membership and exact byte checks still detect real changes. Existing source-changed attempts must be selected again explicitly; they are not silently rehabilitated.

The app explicitly downloads over an unmetered connection, checks size/SHA-256 and current proof, creates a private reduced-resolution JPEG, and removes the temporary original. It never saves to Photos, reconstructs a Live Photo or asserts full complex restore acceptance. Cellular, expensive and constrained downloads remain disabled. Photos and videos have saved-version thumbnails; a Live Photo thumbnail is a still, not motion playback. Existing local thumbnail capture from protected staged bytes remains available without a network download.

Edited-media acceptance has separate layers:

| Check | Evidence |
| --- | --- |
| Original + rendered edit + adjustment data all required | Generated native and API tests |
| Missing adjustment bytes cannot grant full protection | Generated native and database integration tests |
| Captured hashes cannot be replaced on the same resource | API and native manifest tests |
| Later source edit cannot invalidate an already-protected complex backup | Native reconcile fix + server database regression |
| Later device edit cannot replace cached saved-version thumbnail | Generated immutable-thumbnail test |
| Preview cannot mutate assets, required resources or quota | Authenticated database integration test |
| Edited iPad photo visibly preserves both color original and black-and-white rendered edit | Pending physical acceptance |
| Full edit-history reconstruction / complex Photos restore | Separate gated feature; not approved by preview tests |

For physical acceptance, use a disposable color photo: back up and wait for protection, edit the source to black and white, confirm the earlier saved version stays color, then explicitly back up the edited version. Confirm its complete resource preservation and black-and-white saved preview. Do not delete device originals. Report the outcomes separately from automated tests.
