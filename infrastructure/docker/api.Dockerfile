# Local development image only; production infrastructure is outside ACL-001.
FROM node:24-alpine
WORKDIR /workspace
COPY package.json package-lock.json ./
COPY apps/api/package.json apps/api/package.json
COPY apps/web/package.json apps/web/package.json
COPY packages/shared/package.json packages/shared/package.json
RUN npm ci
COPY tsconfig.base.json ./
COPY packages/shared packages/shared
COPY apps/api apps/api
COPY scripts scripts
RUN npm run build --workspace @backup/shared && npm run build --workspace @backup/api
USER node
EXPOSE 3001
CMD ["node", "apps/api/dist/main.js"]
