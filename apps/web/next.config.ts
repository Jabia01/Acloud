import type { NextConfig } from 'next';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';

// Load the monorepo configuration without forwarding Node --env-file flags to
// Next.js workers (Next converts execArgv to NODE_OPTIONS).
const environmentFile = resolve(process.cwd(), '../../.env');
if (existsSync(environmentFile)) process.loadEnvFile(environmentFile);
const config: NextConfig = {
  poweredByHeader: false,
  logging: { incomingRequests: false },
  async headers() { return [{ source: '/:path*', headers: [
    { key: 'Referrer-Policy', value: 'no-referrer' },
    { key: 'X-Content-Type-Options', value: 'nosniff' },
    { key: 'X-Frame-Options', value: 'DENY' },
  ] }]; },
};
export default config;
