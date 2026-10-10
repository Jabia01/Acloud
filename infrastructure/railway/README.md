# Railway staging backend

Build from the repository root with `infrastructure/railway/Dockerfile`. The default Node 24 Debian base is digest-pinned. The image builds only the API and shared library, runs as UID 1000, and includes no credentials. Migrations are never run automatically.

Create separate API and worker services using this Dockerfile. Start commands are `node infrastructure/railway/start.mjs api` and `node infrastructure/railway/start.mjs worker`. Give each one replica and a separate persistent `/data` volume with private ledger/audit directories owned by UID 1000. Expose only the API over HTTPS, using `/health` and the Railway-assigned `PORT`. Keep the worker private and monitor its heartbeat. Review European region selection, budget controls, volume permissions and restart settings before deploying.

Use protected variables based on environment.example. Supply separate restricted runtime and worker database identities, a staging-only B2 key and authenticated TLS SMTP credentials. Supply the public database certificate through DATABASE_CA_PEM or DATABASE_CA_PEM_BASE64. The wrapper enforces certificate verification and rejects the production media bucket and enabled exposure, payment or deletion flags. BETA_ENABLED=false keeps uploads closed until reviewed beta admission.

The existing staging Supabase private schema has all 15 migrations applied; restricted runtime, worker and migrator login checks passed with verified TLS. A local Linux container build and API/worker startup checks passed against staging dependencies. SMTP delivery was separately confirmed. These checks do not establish Railway-hosted acceptance.

For future reviewed migrations use a separate job and migrator identity with `node infrastructure/railway/start.mjs migrate`. Do not add migrator credentials to API/worker services. Review roles and grants after migrations.

API and worker volumes are separate; they do not establish a shared, independently backed-up deletion ledger. Keep deletion disabled until recovery and replay are designed and verified. Before beta admission, verify Railway ingress/TLS, volume ownership, worker heartbeat, alerts, backups and restore, and generated-object staging acceptance. Proposed useacloud.com staging hostnames still require DNS and origin configuration.

Validation: 22 wrapper guard checks, 28 API unit tests and 210 storage/hardening/beta/lifecycle tests passed. Production B2 acceptance used only a generated object and removed its exact recorded version. No Railway deployment or registry publication has occurred. Credentials and local acceptance manifests are deliberately excluded from Git.
