# Session recovery and offline browsing — 21 October 2026

## Sign-in and checkout return

Browser login first checks its HttpOnly session through /api/auth/me. A valid existing session returns to the allowlisted requested page without issuing another session. The server proxy supplies the return path rather than trusting a client-supplied header. Billing success/cancel paths survive a sign-in redirect when Strict SameSite cookies are withheld on the initial cross-site checkout navigation. No payment status is trusted from that navigation.

A real session-limit response offers existing-device session management or an explicit unchecked sign-out-other-sessions consent. The next login request rechecks the password, locks the account, revokes only that account's active sessions, audits each revocation and issues one session. It does not silently rotate other devices. Invalid passwords, non-boolean recovery flags and device-registration failure do not revoke sessions. Other devices need to sign in again; their active transfers may stop. Server quotas, session limits, password checks and rate limits remain enabled. Expired/revoked sessions already do not count toward the limit. A failed server logout no longer discards the browser cookie, so the user can retry revocation instead of orphaning an active session.

## Cached library state

Photos/Videos retain the last successful bounded inventory in an account-scoped memory cache (300 items per page, two media collections, 30-minute maximum age). Cached results remain visible on a failed refresh; the UI reports previous results instead of showing an empty library. Reconnection triggers a refresh. Authentication failure clears the snapshots. Account provider disposal and a change of account create a fresh cache. This is not persistent offline storage or a service worker: a fresh browser launch still requires a connection and authentication. Cached metadata does not authorize downloads or prove current protection.

The native Saved library retains its existing shared contents after network failure and distinguishes unavailable inventory from a successfully empty filter. This change does not add persistent media storage or change restore authorization.

## Verification and limits

API compilation, production website build, 143 website tests, 28 API unit tests, secret scan and clean-source unsigned iOS simulator build passed. Generated PostgreSQL checks passed for explicit recovery, wrong-password rejection, account isolation, rollback, expired-session exclusion, browser rotation, session-cap concurrency and logout. The broader database suite was interrupted when Docker Desktop stopped; its full rerun is unavailable because the local Docker engine cannot start. Do not report that full suite as passed.

Local browser acceptance with generated data passed: explicit session-limit consent, successful recovery, allowlisted return navigation, reuse of an existing session without another login, and retained photo tiles during a simulated failed refresh. No real account was signed out and no customer files were downloaded. The native UI change has not been installed or checked on a physical iPad in this task.

Changes are local pending a separately authorized publication. No migration or environment changes are required. Existing unrelated native AccountView refresh edits were preserved and excluded.
