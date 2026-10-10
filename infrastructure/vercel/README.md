# Closed staging web on Vercel

Import Jabia01/Acloud as a separate Vercel project named acloud-web-staging, using main. This frontend requires the pending web changes; the earlier backend-only commit is insufficient.

- Framework: Next.js
- Root directory: apps/web
- Include source files outside the root directory: enabled (shared workspace).
- Node: 24.x
- Install command: cd ../.. && npm ci
- Build command: cd ../.. && npm run build --workspace @backup/shared && npm run build --workspace @backup/web
- Output directory: Next.js default (.next).
- Assign staging.useacloud.com after reviewing Vercel's generated DNS instructions.

Add only the non-secret settings in staging.env.example to the intended staging deployment environment, available during build and runtime. Do not import Railway api.env or worker.env. Vercel does not need database, B2, SMTP, MFA encryption or ledger credentials. API_BASE_URL is server-side configuration; do not prefix it NEXT_PUBLIC_. Keep preview deployments protected; fixed Origin checks intentionally reject mutations from arbitrary preview hostnames.

The Vercel deployment environment named Production can host this staging app: APP_ENV remains staging. Public account registration, billing and data deletion remain disabled in the backend; web deployment does not authorize beta admission. Keep staff access disabled until separate staff-host/MFA acceptance. The independent API and worker ledgers still require a reviewed recovery design before deletion can be enabled.

Acceptance before use: custom API DNS and certificate verification; frontend certificate; /status reports Connected; anonymous dashboard redirects to login; registration remains invitation-only; server cookies stay Secure/HttpOnly; foreign-origin mutations are denied. No real customer media is needed for this acceptance. Do not treat a passing local build as hosted acceptance.

Local validation: 61 web tests; isolated optimized build; nonce CSP/security headers; invitation-only registration; anonymous dashboard and API protection; foreign-origin mutation denial. Production builds validate required HTTPS origins and security settings, and no longer load the repository's development .env.

Reference: https://vercel.com/docs/monorepos/monorepo-faq
