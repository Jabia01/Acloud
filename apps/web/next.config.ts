import type { NextConfig } from 'next';
import {PHASE_DEVELOPMENT_SERVER, PHASE_PRODUCTION_BUILD, PHASE_PRODUCTION_SERVER} from 'next/constants';
import {validateWebConfiguration} from './lib/production-config';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';

// Load the monorepo configuration without forwarding Node --env-file flags to
// Next.js workers (Next converts execArgv to NODE_OPTIONS).
const environmentFile = resolve(process.cwd(), '../../.env');

const config: NextConfig = {
  poweredByHeader: false,
  allowedDevOrigins: ['192.168.1.217','127.0.0.1','localhost'],
  logging: { incomingRequests: false },
  async headers() { return [{ source: '/:path*', headers: [
    ...(process.env.NODE_ENV==='production'?[{key:'Strict-Transport-Security',value:'max-age=31536000; includeSubDomains'}]:[]),
    { key: 'Referrer-Policy', value: 'no-referrer' },
    { key: 'X-Content-Type-Options', value: 'nosniff' },
    { key: 'X-Frame-Options', value: 'DENY' },
    { key: 'Permissions-Policy', value: 'camera=(), microphone=(), geolocation=()' },
  ] }]; },
};
export default function configuration(phase:string){
  if(phase===PHASE_DEVELOPMENT_SERVER && existsSync(environmentFile)) process.loadEnvFile(environmentFile);
  if(phase===PHASE_PRODUCTION_BUILD || phase===PHASE_PRODUCTION_SERVER) validateWebConfiguration();
  return config;
}
