# Authentication and account foundation (ACL-002)

This is a development account foundation, not a production deployment. The API
owns users, credentials, sessions, devices and token consumption. All customer
endpoints require a revocable opaque bearer session. Email verification is
visible but deliberately not required for initial login. Future sensitive actions
must explicitly require email_verified_at; health remains public and unchanged.

## Passwords and account identity

PasswordService centralizes Argon2id: 64 MiB, three iterations, one lane, random
salt and a 32-byte output. This exceeds the current
[OWASP Argon2id minimum](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html).
Two hash/verify operations run concurrently per service instance, with at most
16 waiting jobs, bounding native hashing memory. Unknown accounts verify a
random dummy Argon2id hash. Wrong, nonexistent and disabled-account login all
return HTTP 401 and `Invalid credentials`. Database failures are sanitized.

New passwords require 12–1024 Unicode code points and at most 4096 UTF-8 bytes.
Any character composition is accepted, including whitespace; passwords are
never normalized, trimmed or silently truncated. Login verifies the supplied
string exactly. No common-password/breach corpus integration exists yet.

Email display values are trimmed. Account identity lowercases the **entire ASCII
address**, including the local part, to avoid case-dependent duplicate accounts.
The domain is therefore also lowercased. Local-part case sensitivity is
intentionally unsupported. No plus removal, Gmail dot removal or provider rules
are applied. Internationalized addresses/quoted local parts are deferred. Unique
email_normalized enforces duplicate suppression, including concurrent attempts.
Duplicate valid registration returns the same 202 message as a new account,
creates no replacement account and sends no second verification link.

## API contract

All auth responses are no-store. API cookies are **not** authentication inputs;
only `Authorization: Bearer <opaque token>` is accepted on protected endpoints.

| Method | Endpoint | Input / behavior |
| --- | --- | --- |
| POST | /auth/register | {email,password}; generic 202; creates account and verification mail |
| POST | /auth/login | {email,password,device?}; issues {sessionToken,sessionId,expiresAt,user} |
| POST | /auth/logout | Authenticated; revoke current session |
| POST | /auth/email/verify | {token}; single-use email verification |
| POST | /auth/email/resend | {email}; generic 202; invalidates previous verification links |
| POST | /auth/password/forgot | {email}; generic 202 for existing/missing/disabled account |
| POST | /auth/password/reset | {token,password}; resets password and revokes every session |
| GET | /me | Safe {id,email,emailVerified,status}; no hashes/internal normalized email |
| GET | /sessions | At most 100 active unexpired sessions; metadata and current flag, no token hashes |
| DELETE | /sessions/:id | Revoke owned session; same response for unowned/missing IDs |
| DELETE | /sessions | Revoke all sessions except current |
| GET | /devices | At most 100 non-revoked device metadata records |
| POST | /devices | Authenticated device input; register/associate current session |
| DELETE | /devices/:id | Revoke owned device and all related sessions |

Device input is {identifier,displayName,platform,appVersion?,osVersion?}; platform
is ios, web or other. Identifiers are client-generated, stable, non-secret
metadata and never authenticate a user. UUID v4 public IDs are server-generated.
Revoked identifiers are not automatically reactivated on login; password holders
can register a new identifier. Revocation is not a hardware/device ban.

## Tokens, sessions and atomic transitions

Session, verification and reset tokens are independently generated from 32
cryptographically random bytes and encoded as 43-character base64url strings.
Only SHA-256 token hashes are stored. High entropy makes a slow password hash
unnecessary for these random tokens. Sessions expire after 30 days, verification
tokens after 24 hours, reset tokens after 30 minutes. Token values must never be
logged or returned by list/current-user/registration/recovery responses.

Direct API login returns the raw session token once because native clients need
the credential. This is the intentional issuance-time exception to the no-raw-
tokens response rule. The web proxy removes it before returning browser JSON.

Each authentication checks expiry, revocation, ACTIVE user status and device
revocation. A revoked/expired/disabled session never works just because the token
is otherwise valid. last_seen updates are throttled to once per minute. There is
no refresh token, sliding expiry, background cleanup or cookie-only logout.

Login rechecks the password hash after acquiring a user row lock so a concurrent
reset cannot create a session using an old password. User row locks serialize
login, reset, verification, device and session mutations. Token consumption uses
conditional expiry/used_at updates within the same transaction. Concurrent token
consumption has exactly one winner. A successful reset replaces password_hash,
consumes all pending reset tokens, revokes all sessions and records an audit event
atomically. Email verification consumes pending verification links atomically.

auth_audit_events contains account IDs, action, optional target ID and time for
login, logout, session/device revocation, verification and reset. It stores no
passwords, raw tokens, mail links or sensitive content. It is an initial audit
foundation; restricted production roles, immutable audit storage and centralized
security monitoring remain deferred. No account deletion endpoint exists.

## Browser and iOS boundaries

Next.js exposes a strict route allowlist under /api/auth/* and forwards requests
server-side. The session is stored in an HttpOnly, host-only, SameSite=Strict
cookie. Production mode uses Secure and the __Host-backup_session name with
Path=/ and no Domain. Local next dev uses backup_session without Secure on HTTP.
Set WEB_ORIGIN to the exact trusted browser origin and WEB_BASE_URL to the link
origin. Mutations require matching Origin; POST also requires JSON. Host and
X-Forwarded-Host are not used to derive the trusted origin. This rejects
cross-origin/login CSRF; the API itself uses bearer auth, not ambient cookies.
Do not enable permissive CORS or trust arbitrary forwarded client IPs.

The six minimal pages are /register, /login, /account, /forgot-password,
/reset-password and /verify-email. Account shows verification, sessions and
devices, and offers logout/revocation/resend. Browser JavaScript never receives
or stores the bearer. Only a non-secret device ID uses localStorage. Origin
checks/cookies do not protect against same-origin XSS: React escapes display
values, pages have no third-party scripts, and no-referrer/nosniff/frame-deny
headers are configured. A deployment CSP remains deferred.

SwiftUI has Sign In, Create Account and Signed In/Account Status scaffolding.
AuthAPI supports register/login/logout/me. KeychainSessionStore uses generic
password items with WhenUnlockedThisDeviceOnly, no synchronization, no UserDefaults
tokens and no shared access group. The UI never exposes the session string.
Only a non-secret device identifier is stored in UserDefaults. Keychain failure
after login triggers best-effort server revocation. Authenticated 401 clears the
local credential; network-failed logout retains it for a retry and does not claim
server revocation. Sessions remain revocable remotely if the device is lost.
Default networking is ephemeral, disables cookies/cache, rejects redirects, and
permits HTTP only on local development hosts; remote auth requires HTTPS.

## Development mail and recovery

AccountMailer abstracts delivery. LocalAccountMailer uses SMTP to loopback (or
the internal Compose mail host) only when DEV_MAIL_ENABLED=true and NODE_ENV is
not production. Mailpit runs locally at SMTP 1025 and web/API 8025, with both
host ports bound to loopback; messages contain sensitive single-use links and
must stay local. There is no provider integration and no mail-token API endpoint.
MemoryAccountMailer is injected only by tests. No links are printed to console.

Links use a URL **fragment**, not a query string, so the token is not transmitted
in page requests/access logs. The form reads it in memory and removes it from
browser history before POSTing it to the API. Verification requires a user click,
not a GET side effect. no-referrer headers provide additional protection. Token
responses are generic and consumption/expiry follow
[OWASP reset guidance](https://cheatsheetseries.owasp.org/cheatsheets/Forgot_Password_Cheat_Sheet.html).
Email compromise still gives an attacker the password-reset capability.

Delivery occurs after database commit. Failed delivery is not surfaced as an
account-existence oracle; users can resend/request another link. This phase has
no durable outbox or delivery guarantees. Production requires a verified provider,
durable delivery/retry design, monitoring and controlled link origins before use.

## Rate limits, tests and limitations

Per-process, bounded (10000 buckets) fixed ten-minute windows limit login to 30
per source IP / 15 per normalized account; other public auth actions to 10 per
IP / 5 per account or token-entry action/IP. Counters do not log plaintext email;
account keys are SHA-256. 429 includes Retry-After. Register, login, forgot and
resend are covered; verify/reset are also guarded. Unauthenticated invalid input
still consumes the IP bucket. Headers supplied by clients cannot override IP.

This is not distributed abuse prevention. Next.js traffic shares the proxy's IP
bucket; multi-instance deployments, trusted proxy attribution, mail flooding,
bot controls and breach checks require a later design. Limits reset on process
restart and can be a denial-of-service target. No permanent account lockout is
implemented. Auth responses are generic but perfect timing indistinguishability
is not claimed: delivery and database work differ for existing accounts.

Run npm test, npm run test:integration, npm run build, npm run security:scan.
The PostgreSQL security suite applies migrations in a unique disposable fixture
schema and drops only that generated schema afterward; never run against
production. npm run test:auth:live additionally exercises running API/web and
real Mailpit, creates random .invalid accounts in the local development schema,
and leaves them with all sessions revoked. No production/customer rows are reset.
See VALIDATION.md for executed checks. Swift tests/Keychain/simulator builds need
macOS and Xcode. MFA, passkeys, Apple/social sign-in and production deployment
are deliberately absent; add new methods without bypassing server revocation.
