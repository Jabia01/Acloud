# Staging owner console preview

This opt-in mode lets the initial owner inspect the console while full STAFF_MFA acceptance remains pending. It does not record PASS evidence or replace independent staff approval.

## Scope

- Staging production-runtime only, with beta-cohort mode off, internal admin access enabled and MFA mandatory.
- Bound to one active SUPERADMIN identity and an explicit UTC expiry (at most 30 days ahead when configured). An expired window denies staff access while customer services can still start.
- Normal password/TOTP or enrolled passkey verification, rate limits, session expiry/idle limits, credential revocation and audit records remain authoritative.
- Allows overview, users/account detail, uploads, storage, devices, security, system and audit metadata. Customer media download, staff management, billing, lifecycle and beta controls are excluded.
- Business mutations are denied by the global request guard and service permission checks, including quota/status changes, customer session/device revocation, upload retry/abort and staff creation. Sign-in, challenge, sign-out and their session/audit housekeeping remain allowed.
- Browser navigation hides unavailable sections and mutation controls, and identifies owner preview as read-only. This UI is supplementary to server enforcement.

## Enablement

After publishing and verifying the update, add these variables **only to the Railway Acloud API service**:

```
STAFF_OWNER_READ_ONLY_ENABLED=true
STAFF_OWNER_READ_ONLY_ADMIN_ID=<the existing enrolled owner staff UUID>
STAFF_OWNER_READ_ONLY_EXPIRES_AT=<explicit UTC timestamp>
```

Keep `ADMIN_MFA_REQUIRED=true`, `INTERNAL_ADMIN_ENABLED=true`, `APP_ENV=staging`, `NODE_ENV=production` and `BETA_ENABLED=false`. Use the existing trusted staff HTTPS origin and RP configuration. Preserve every other hosting variable. No web-side mode flag is needed; the server's staff identity projection supplies the read-only state.

The mode defaults off. Invalid enablement fails configuration validation. Disabling it restores the ordinary staff-readiness gate; it does not itself grant full administration. Enabling a customer beta cohort requires disabling this initial-owner mode and completing its normal acceptance process.

## Evidence

Generated unit and real HTTP/PostgreSQL tests cover password/MFA/replay behavior, owner isolation, expiry/idle/revoked sessions, revoked authenticator, disabled/downgraded account, hidden controls, blocked business mutations, service-level authorization, unchanged customer admission and absence of fabricated staff PASS records. Real owner login after deployment remains an additional user acceptance check.
