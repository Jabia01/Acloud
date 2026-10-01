import { execFileSync } from 'node:child_process';
import { readFile } from 'node:fs/promises';

// Reviewable heuristic, not a substitute for a dedicated secret scanner/history audit.
const files = execFileSync('git', ['ls-files', '--cached', '--others', '--exclude-standard', '-z'], { encoding: 'utf8' }).split('\0').filter(Boolean);
const patterns = [
  /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/,
  /\bAKIA[0-9A-Z]{16}\b/,
  /\b(?:ghp|github_pat|sk_live|pk_live)[_-][A-Za-z0-9_]{16,}\b/,
  /(?:password|secret|api[_-]?key|token)\s*[:=]\s*["'](?!local_dev_only_change_me["']|test_secret["']|\$)[A-Za-z0-9/+_-]{12,}["']/i,
  /postgres(?:ql)?:\/\/[^\s:@/]+:[^\s@]+@/i,
  /Bearer\s+[A-Za-z0-9_-]{32,}/,
  /(?:localStorage|sessionStorage)\.setItem\s*\(\s*['"][^'"]*(?:auth|session|token)/i,
  /(?:UserDefaults|defaults)\.(?:set|string)[^\n]*['"][^'"]*(?:auth[_-]?token|session[_-]?token)/i,
  /console\.(?:log|info|warn|error)\s*\([^\n]*(?:message\.token|\.sessionToken|\.password_hash|\.token_hash|process\.env\.[A-Z_]*(?:PASSWORD|SECRET)|url\.href)/,
];
let findings = 0;
let localDefaults = 0;
for (const file of files) {
  if (file === 'package-lock.json' || file === 'scripts/security-scan.mjs') continue;
  const content = await readFile(file, 'utf8');
  content.split(/\r?\n/).forEach((line, index) => {
    if (!patterns.some(pattern => pattern.test(line))) return;
    if (line.includes('local_dev_only_change_me') || line.includes('test_user:test_secret') || line.includes('${POSTGRES_USER}:${POSTGRES_PASSWORD}')) {
      localDefaults++;
      console.info(`Reviewed local/example credential: ${file}:${index + 1}`);
    } else {
      findings++;
      // Deliberately print the location only, never the suspected secret.
      console.error(`Review possible secret: ${file}:${index + 1}`);
    }
  });
}
console.info(`Scanned ${files.length} Git-visible files; ${findings} unexpected findings; ${localDefaults} local/test examples.`);
process.exitCode = findings ? 1 : 0;
