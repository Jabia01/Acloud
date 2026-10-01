# Final source tree

This is the ACL-001 baseline tree; see ACL002_TREE.md for the subsequent
authentication/account additions and changed files.

Generated dependencies, build output, Git metadata, .env, npm cache and Xcode
generated artifacts are omitted. They are ignored and are not deliverables.

```text
C:/Acloud/
├── .dockerignore
├── .env.example
├── .github/workflows/ci.yml
├── .gitignore
├── AGENTS.md
├── README.md
├── package.json
├── package-lock.json
├── tsconfig.base.json
├── apps/
│   ├── api/
│   │   ├── package.json
│   │   ├── tsconfig.json
│   │   ├── jest.config.cjs
│   │   ├── migrations/001_foundation.sql
│   │   ├── src/
│   │   │   ├── main.ts
│   │   │   ├── app.module.ts
│   │   │   ├── database.service.ts
│   │   │   └── health.controller.ts
│   │   └── test/
│   │       ├── database.integration.ts
│   │       ├── database.spec.ts
│   │       └── health.spec.ts
│   ├── web/
│   │   ├── package.json
│   │   ├── tsconfig.json
│   │   ├── next-env.d.ts
│   │   ├── next.config.ts
│   │   ├── app/
│   │   │   ├── layout.tsx
│   │   │   ├── page.tsx
│   │   │   ├── styles.css
│   │   │   └── status/
│   │   │       ├── page.tsx
│   │   │       └── loading.tsx
│   │   ├── lib/api-status.ts
│   │   └── test/api-status.test.ts
│   └── ios/
│       ├── README.md
│       ├── project.yml
│       ├── Sources/
│       │   ├── BackupClientApp.swift
│       │   └── ContentView.swift
│       └── Packages/HealthClient/
│           ├── Package.swift
│           ├── Sources/HealthClient/HealthAPI.swift
│           └── Tests/HealthClientTests/HealthAPITests.swift
├── packages/shared/
│   ├── package.json
│   ├── tsconfig.json
│   ├── src/index.ts
│   └── test/health.test.ts
├── infrastructure/docker/
│   ├── compose.yml
│   └── api.Dockerfile
├── scripts/
│   ├── migrate.mjs
│   ├── security-scan.mjs
│   └── test/migrate.test.mjs
└── docs/
    ├── ARCHITECTURE.md
    ├── SECURITY_PRINCIPLES.md
    ├── DATA_LIFECYCLE.md
    ├── VALIDATION.md
    └── REPOSITORY_TREE.md
```
