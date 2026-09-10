import { and, eq } from 'drizzle-orm';
import { pushTokens } from '../db/schema';
import { base64url } from '../lib/crypto';
import type { Db } from '../db/client';
import type { Bindings } from '../env';

interface ServiceAccount {
  client_email: string;
  private_key: string;
  project_id: string;
}

/** Cached per isolate; FCM access tokens live an hour. */
let tokenCache: { token: string; expiresAt: number } | null = null;

function pemToPkcs8(pem: string): ArrayBuffer {
  const body = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, '')
    .replace(/-----END PRIVATE KEY-----/, '')
    .replace(/\s+/g, '');
  const bin = atob(body);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes.buffer;
}

/**
 * Mints a Google OAuth access token from the service account with a signed JWT
 * assertion (RS256 via WebCrypto) — the googleapis SDK does not run on Workers.
 */
async function getAccessToken(sa: ServiceAccount): Promise<string> {
  if (tokenCache && tokenCache.expiresAt > Date.now() + 60_000) return tokenCache.token;

  const nowSec = Math.floor(Date.now() / 1000);
  const header = base64url(new TextEncoder().encode(
    JSON.stringify({ alg: 'RS256', typ: 'JWT' }),
  ));
  const payload = base64url(new TextEncoder().encode(JSON.stringify({
    iss: sa.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: nowSec,
    exp: nowSec + 3600,
  })));

  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToPkcs8(sa.private_key),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const signature = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(`${header}.${payload}`),
  );
  const assertion = `${header}.${payload}.${base64url(new Uint8Array(signature))}`;

  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion,
    }),
  });
  if (!res.ok) throw new Error(`FCM token exchange failed: ${res.status}`);

  const body = await res.json() as { access_token: string; expires_in: number };
  tokenCache = { token: body.access_token, expiresAt: Date.now() + body.expires_in * 1000 };
  return body.access_token;
}

export interface PushMessage {
  title: string;
  body: string;
  data?: Record<string, string>;
}

/**
 * Sends to every active device of a user. Local dev has no credentials, so a
 * missing service account is a no-op warning rather than a thrown error.
 */
export async function sendPush(
  db: Db, env: Bindings, userId: string, message: PushMessage,
): Promise<number> {
  if (!env.FCM_SERVICE_ACCOUNT_JSON || !env.FCM_PROJECT_ID) {
    console.warn('push skipped: FCM credentials not configured');
    return 0;
  }

  const tokens = await db.select({ token: pushTokens.token }).from(pushTokens)
    .where(and(eq(pushTokens.userId, userId), eq(pushTokens.isActive, true)));
  if (tokens.length === 0) return 0;

  const sa = JSON.parse(env.FCM_SERVICE_ACCOUNT_JSON) as ServiceAccount;
  const accessToken = await getAccessToken(sa);
  const url = `https://fcm.googleapis.com/v1/projects/${env.FCM_PROJECT_ID}/messages:send`;

  let sent = 0;
  for (const { token } of tokens) {
    const res = await fetch(url, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        message: {
          token,
          notification: { title: message.title, body: message.body },
          ...(message.data ? { data: message.data } : {}),
        },
      }),
    });

    if (res.ok) {
      sent++;
      continue;
    }
    // 404/403 means the device unregistered; stop targeting it.
    if (res.status === 404 || res.status === 403) {
      await db.update(pushTokens).set({ isActive: false, updatedAt: Date.now() })
        .where(eq(pushTokens.token, token));
    }
  }
  return sent;
}
