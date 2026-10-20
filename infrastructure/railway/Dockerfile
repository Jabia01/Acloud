# Build from the Acloud repository root, after installing this overlay.
# Reviewed Node 24 Debian image; overrides must also use an immutable digest.
ARG NODE_IMAGE=node:24-bookworm-slim@sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20
FROM ${NODE_IMAGE} AS builder
ARG NODE_IMAGE
RUN node -e "if (!/@sha256:[a-f0-9]{64}$/.test(process.env.NODE_IMAGE || '')) process.exit(1)"
WORKDIR /workspace
COPY package.json package-lock.json tsconfig.base.json ./
COPY apps/api/package.json apps/api/package.json
COPY apps/web/package.json apps/web/package.json
COPY packages/shared/package.json packages/shared/package.json
RUN npm ci --ignore-scripts && npm rebuild argon2
COPY apps/api/src apps/api/src
COPY apps/api/tsconfig.json apps/api/tsconfig.json
COPY apps/api/migrations apps/api/migrations
COPY packages/shared packages/shared
COPY infrastructure/railway/owner-payment-test.cjs infrastructure/railway/owner-payment-test.d.cts infrastructure/railway/
RUN npm run build --workspace @backup/shared && npm run build --workspace @backup/api
RUN npm prune --omit=dev --ignore-scripts
FROM ${NODE_IMAGE} AS runtime
WORKDIR /workspace
ENV NODE_ENV=production
COPY --from=builder --chown=node:node /workspace/package*.json ./
COPY --from=builder --chown=node:node /workspace/node_modules ./node_modules
COPY --from=builder --chown=node:node /workspace/apps/api/dist ./apps/api/dist
COPY --from=builder --chown=node:node /workspace/apps/api/migrations ./apps/api/migrations
COPY --from=builder --chown=node:node /workspace/apps/api/package.json ./apps/api/package.json
COPY --from=builder --chown=node:node /workspace/packages/shared ./packages/shared
COPY --chown=node:node scripts/migrate.mjs scripts/release-migrate.mjs scripts/run-durable-worker.mjs scripts/supervise-worker.mjs ./scripts/
COPY --chown=node:node infrastructure/railway/start.mjs infrastructure/railway/owner-payment-test.cjs ./infrastructure/railway/
USER node
CMD ["node","infrastructure/railway/start.mjs","api"]
