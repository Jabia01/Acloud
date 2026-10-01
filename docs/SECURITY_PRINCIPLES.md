# Security principles

These are intended production requirements, not a claim that ACL-001 is ready
to protect customer media. No real customer data belongs in this scaffold.

- **Least privilege:** isolate runtime, migrations, workers and storage roles.
  The local PostgreSQL owner is a convenience only; production needs separate
  narrowly scoped roles, service identities and network policies.
- **Private object storage:** deny public ACLs and bucket access, enforce tenant
  isolation, and never return permanent object URLs or embed storage keys in iOS.
- **Encryption in transit:** require TLS for APIs, databases and object transfer
  in deployed environments. Local HTTP and local PostgreSQL are development only.
- **Encryption at rest:** encrypt objects, database volumes and backups with
  managed, rotated keys and restricted access. No end-to-end encryption promise
  is made here; a future threat model must define key custody and recovery.
- **Short-lived upload authorization:** bind each grant to an authenticated
  user, one intended object, size/content restrictions and expiry. Validate
  ownership again on completion and verification; avoid logging grant URLs.
- **Server-side quotas:** atomically reserve capacity before grants, reconcile
  abandoned reservations, and enforce entitlements independently of clients.
- **Audit logging:** record who authorized destructive operations, their scope,
  outcome and correlation ID. Keep audit records access-controlled and durable.
  Do not log media, tokens, encryption keys, passwords or signed URLs. The
  foundation suppresses database exception details and response internals.
- **Secret management:** ignored .env files are local only. Use a secret manager
  and rotation in deployment; commit examples only. Scan code and history before
  publishing, and rotate any leaked credential rather than merely deleting it.
- **Authentication boundaries:** health is deliberately unauthenticated and
  minimal. All future customer APIs must authenticate and authorize tenant/object
  ownership server-side. The web and iOS client are untrusted. No auth exists yet.
- **Data deletion safety:** never automatically delete device originals. Every
  destructive customer operation needs explicit authorization and an audit trail.
  Plan grace periods, tombstones, recoverability and legal retention rules.
  Failed subscriptions never trigger immediate deletion of customer data.
- **Backup/recovery philosophy:** define recovery point and recovery time targets
  before production; preserve immutable originals and metadata where possible.
  Verify restores and exercise disaster recovery, including keys. Replication is
  not a backup. Docker volume persistence is not a production backup strategy.

Security-sensitive functionality requires automated tests. Destructive migrations
need explicit documentation, approved authorization and a tested recovery plan.
Development and production accounts, storage, networks and keys must remain
logically separated. Payment status and entitlement changes must originate from
verified, idempotent server payment events; there is no payment code in iOS.
