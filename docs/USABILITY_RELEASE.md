# Cross-surface usability update

## Customer website

- Mobile menu, collection-aware detail links and direct back-to-collection actions.
- Card selection with selected count/size; existing five-item/500 MiB selection bounds retained. Individual downloads remain individual downloads, not a ZIP.
- Search and date sorting apply to the currently loaded bounded page, explicitly labelled.
- Refresh preserves the current authenticated view and shows its last-refresh time; session expiry still redirects.
- On-demand saved-media previews: no automatic original downloads. Supports verified raster formats and supported MP4/QuickTime files up to 32 MiB. Browser image previews are reduced to 1280px; video playback depends on browser codec support. HEIC and other unsupported formats explain the original-download/app alternative.
- Preview BFF uses the existing restore preview evidence/authorization/recheck flow. Ownership, session, device and release gates are unchanged. It verifies size/SHA-256 and pinned version, permits only the configured exact HTTPS storage origin (default: current staging B2 origin), rejects redirects and active-document formats, serves private/no-store bytes and never sends storage grants to the browser. Two simultaneous preview requests per server instance. `PREVIEW_STORAGE_ORIGIN` can be explicitly set for another reviewed binding.
- Object URLs are confined to the page and revoked on unmount. No permanent media cache, public object URL or new storage objects are created.

## Staff console

- Six primary metrics, with supporting account/resource/job details expandable.
- Resource-file totals explicitly distinguished from customer media-item totals.
- Essential table columns, expandable record details, copy references and account links; role and exact-lookup boundaries unchanged.
- Refresh retains current-view results; optional health/security failures are reported separately from the primary metrics.
- Owner read-only expiry is visible. No staff acceptance or access window is changed by this release.

## Native app

- Original muted-blue tint retained; On device and Saved tab labels; recent transfer saves link to the protected library.
- Direct recovery link and password visibility toggle.
- Binary storage units and resource-file explanation.
- Saved-preview byte/stage progress, cancellation and zoom/pan/reset controls for photos.
- Banners retained. Native saved-video viewing still uses the existing restore-to-Photos workflow for full playback; no new native streaming capability is claimed.

## Acceptance limits

Generated tests and simulator compilation do not replace physical-device checks for pinch/pan, Dynamic Type, VoiceOver and older media formats. Protected-library sources/pagination remain bounded and separate; this is navigation clarification, not a database merge. Preview access can remain unavailable where existing server/device acceptance forbids it. No gates should be weakened to obtain a thumbnail.
