// Generate local secrets in ignored .env only; preserve existing configuration.
import { randomBytes } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
let content = await readFile('.env', 'utf8');
const secret = () => randomBytes(32).toString('hex');
const settings = {
  MINIO_ROOT_USER: `root${randomBytes(8).toString('hex')}`, MINIO_ROOT_PASSWORD: secret(),
  S3_ACCESS_KEY_ID: `app${randomBytes(8).toString('hex')}`, S3_SECRET_ACCESS_KEY: secret(),
  S3_ENDPOINT: 'http://127.0.0.1:9000', S3_REGION: 'us-east-1', S3_BUCKET: 'backup-dev-objects',
  UPLOAD_MAX_BYTES: '5242880', FREE_DEV_QUOTA_BYTES: '20971520', UPLOAD_TTL_SECONDS: '300', DOWNLOAD_TTL_SECONDS: '60',
};
for (const [name,value] of Object.entries(settings)) {
  const line = new RegExp(`^${name}=(.*)$`, 'm');
  const existing = content.match(line);
  if (!existing) content += `\n${name}=${value}\n`;
  else if (!existing[1].trim()) content = content.replace(line, `${name}=${value}`);
}
await writeFile('.env', content, { mode: 0o600 });
console.info('Local storage settings ready in ignored .env; no credentials printed.');
