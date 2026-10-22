# Returning to the app

Library keeps accessible visible items while a refreshed PhotoKit page loads, including the number of pages already loaded. An unchanged foreground return keeps the completed discovery summary rather than rescanning. Explicit refresh, PhotoKit changes, access changes and removed visible membership still invalidate the summary and request scanning.

Visible device IDs are checked against current Photos access before retention, including Limited Access changes that retain the same permission enum. Unavailable items are removed and affected viewers dismissed. No new device-thumbnail disk cache or original copy is created. Full process termination can still require rebuilding the screen.

Restore refreshes its current inventory page on reappearance, retains selections that remain in that page, and rejects responses from an invalidated account/device or superseded request. Explicit next-page navigation resets selection. Existing sign-out invalidation, restore admission and server protection checks are unchanged.

Owner acceptance (18 October 2026): the latest update is installed on the iPad; retained-content refresh and updated thumbnail behavior are confirmed working. Local Library thumbnails include Photos modification revision in their request identity, so later device edits refresh without altering a saved backup preview.

Account now shares an in-memory model scoped to the current Keychain credential. Returning to the tab or foreground skips repeat requests within 60 seconds; manual refresh bypasses that interval. A failed network update retains the last account details, while an expired session, credential change or completed sign-out clears them. Concurrent refreshes coalesce, and completions from an invalidated session cannot repopulate the screen. Six model scenarios cover throttling, force refresh, failed-network retention, session expiry, account switching and stale completion after sign-out.

Publication validation (21 October 2026): all 22 HealthClient tests pass, including the six Account refresh cases. Physical iPad acceptance for this new Account behavior is still pending; the earlier 18 October acceptance applies to the Library/Restore changes described above.
