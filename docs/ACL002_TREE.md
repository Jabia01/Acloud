# Relevant ACL-002 source tree

Existing foundation files remain; dependencies/build outputs and .env are ignored.

```text
apps/api/
  migrations/002_accounts.sql
  src/auth/
    auth.module.ts
    auth.controller.ts
    auth.service.ts
    input.ts
    password.service.ts
    session.guard.ts
    rate-limit.ts
    mail.ts
    safe-errors.ts
  src/{app.module,main,database.service}.ts  updated
  test/
    auth.integration.ts
    password.spec.ts
    input.spec.ts
    rate-limit.spec.ts
apps/web/
  app/
    {register,login,account,forgot-password,reset-password,verify-email}/page.tsx
    api/auth/[...segments]/route.ts
  components/{auth-form,account}.tsx
  lib/auth-proxy.ts
  test/auth-proxy.test.ts
  next.config.ts                          security headers updated
apps/ios/
  Sources/{AccountView,ContentView}.swift
  Packages/HealthClient/
    Sources/HealthClient/{AuthAPI,SessionTokenStore}.swift
    Tests/HealthClientTests/AuthAPITests.swift
infrastructure/docker/compose.yml         PostgreSQL + Mailpit
scripts/
  validate-auth-live.mjs
  security-scan.mjs                       expanded checks
  test/migrate.test.mjs                   second migration covered
docs/
  AUTHENTICATION.md
  THREAT_MODEL_AUTH.md
  VALIDATION.md
  ACL002_TREE.md
README.md
AGENTS.md
.env.example
package.json / package-lock.json
```
