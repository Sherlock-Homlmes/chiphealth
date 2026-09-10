/**
 * Mints a local dev session so the admin panel can be opened without a real
 * Google OAuth client. Touches the LOCAL D1 file only — it is not a backdoor in
 * the Worker: the refresh token is inserted the same way /v1/auth/google would.
 *
 *   node scripts/dev-session.mjs [email]
 */
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

const email = process.argv[2] ?? defaultEmail();
const now = Date.now();
const refreshToken = randomBytes(32).toString('base64url');
const refreshHash = createHash('sha256').update(refreshToken).digest('hex');
const userId = uuidv7();
const sessionId = uuidv7();

function defaultEmail() {
  try {
    const vars = readFileSync(new URL('../.dev.vars', import.meta.url), 'utf8');
    const match = vars.match(/^BOOTSTRAP_ADMIN_EMAILS=(.+)$/m);
    return match?.[1].split(',')[0].trim() || 'dev@chiphealth.test';
  } catch {
    return 'dev@chiphealth.test';
  }
}

function uuidv7() {
  const bytes = Buffer.from(randomUUID().replace(/-/g, ''), 'hex');
  bytes.writeUIntBE(Date.now(), 0, 6);
  bytes[6] = (bytes[6] & 0x0f) | 0x70;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

const sql = `
INSERT INTO users (id, google_sub, email, email_verified, display_name, role, locale, unit_system, timezone, created_at, updated_at)
VALUES ('${userId}', 'dev-${email}', '${email}', 1, 'Dev Admin', 'admin', 'vi', 'metric', 'Asia/Ho_Chi_Minh', ${now}, ${now})
ON CONFLICT(email) DO UPDATE SET role = 'admin', updated_at = ${now};

INSERT INTO user_profiles (user_id, activity_level, target_sleep_minutes, created_at, updated_at)
SELECT id, 'moderate', 480, ${now}, ${now} FROM users WHERE email = '${email}'
ON CONFLICT(user_id) DO NOTHING;

INSERT INTO auth_sessions (id, user_id, refresh_token_hash, device_name, platform, expires_at, created_at)
SELECT '${sessionId}', id, '${refreshHash}', 'dev script', 'web-admin', ${now + 30 * 86400000}, ${now}
FROM users WHERE email = '${email}';
`;

execFileSync(
  'npx',
  ['wrangler', 'd1', 'execute', 'chiphealth', '--local', '--command', sql],
  { stdio: ['ignore', 'ignore', 'inherit'] },
);

console.log(`
Dev admin session ready for ${email}

Open the admin panel, then paste this in the browser console once:

  localStorage.setItem('chiphealth.admin.refreshToken', '${refreshToken}'); location.href = '/'

The refresh token rotates on first use, exactly like a real session.
`);
