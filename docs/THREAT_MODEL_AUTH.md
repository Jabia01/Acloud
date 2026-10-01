# Account threat model (ACL-002)

Assets: password hashes, session bearers, single-use recovery links, account
identity, device/session metadata and audit records. Boundaries: untrusted
browser/iOS -> API -> PostgreSQL; browser -> same-origin Next.js cookie proxy;
API -> development-only SMTP sink. Protecting accounts is necessary for future
media protection; no media/storage/payment functionality exists in this phase.

| Threat | Current mitigation | Deferred work / residual risk |
| --- | --- | --- |
| Credential stuffing | Argon2id, IP/account throttles, generic failed-login response, hashing memory budget | Breach corpus, bot/distributed abuse controls, MFA/passkeys, anomaly detection |
| Brute force | Random 256-bit bearer/recovery tokens; expiration; public auth rate guards | Multi-instance shared limiter and operational tuning |
| Account enumeration | Duplicate register and recovery/resend use generic 202; dummy password verification for unknown login; disabled/unknown/wrong generic 401 | Delivery/DB timing differences remain; no perfect timing guarantee |
| Stolen bearer | Hash-only database storage, fixed expiry, per-request status checks, session/device revocation and reset-wide revocation | A stolen active bearer grants access until revocation/expiry; no device binding, MFA or continuous risk scoring |
| Stolen device | ThisDeviceOnly Keychain with unlocked access, ephemeral networking, remotely revocable device sessions | Unlocked/compromised devices may act as user; no jailbreak detection or biometric step-up |
| Database leak | Argon2id salts/work factor; no plaintext password or raw random tokens; public API field allowlists | Password cracking risk remains; production least-privilege roles, TLS, at-rest encryption and secret-management rollout deferred |
| Reset-token interception | High entropy, hash-only storage, short expiry, single use, fragment links, no-referrer, no token logging | Email compromise, local mail-sink access or compromised browser can expose raw links; production email/TLS verification needed |
| Session fixation | Fresh random server session on each login; user-supplied session IDs ignored; no cookie-to-API auth | Same-origin XSS can act through cookie even though bearer is HttpOnly |
| CSRF / login CSRF | Fixed Origin+JSON checks on browser mutations; HttpOnly Strict host cookie, Secure in production; bearer-only API | Exact production origin, TLS and deployment CSP/proxy configuration still required; no permissive CORS allowed |
| Token replay / races | Conditional used_at/expiry check plus per-user locks; concurrent verification/reset tests; revocation checked every request | Raw active session tokens are reusable until revoked; no per-request nonce system |
| Email compromise | Reset invalidates all sessions; verification status explicit; initial audit of reset/revocation | Email-only recovery trusts mailbox owner. MFA recovery, security notifications and recovery policies deferred |
| Cross-account access | Server principal controls all queries; user-scoped session/device updates; composite device/user foreign key; UUID IDs; tenant-isolation tests | Every future endpoint must maintain the same ownership checks |
| Resource exhaustion | Argon2 budget of 2 active + 16 waiting jobs, bounded rate map, request/body limits and DB timeouts | Edge body/connection limits and distributed protection are deployment concerns |
| Sensitive logs / infrastructure errors | Generic global error filter; no credential/link console logging; no-store responses, link fragments; expanded source scanner | Dedicated secret scanner, log redaction policy and monitoring before production |
| Mail delivery failure | Stored tokens remain recoverable by a new request/resend; no existence-revealing delivery errors | No durable outbox/provider; cannot claim email delivery guarantees |

Disabled accounts cannot log in or use existing sessions. Device IDs describe
clients and are never credentials; revoking one is not a hardware ban against
someone who still knows the password. Manual SQL status changes are local tests
only; no admin workflow is implemented.

Security tests validate authorization, hash-only token persistence, password
verification, expiry, replay, single-use races, reset-wide revocation, tenant
isolation, abuse guards, sanitized errors and browser cookie/Origin boundaries.
The live test runs actual SMTP/Mailpit and HTTP flows against PostgreSQL. XCTest
and Keychain tests are authored but require macOS execution; this Windows task
does not establish iOS runtime security. No claim of production readiness is made.
