import { Hono } from 'hono';
import { z } from 'zod';
import { and, eq, isNull } from 'drizzle-orm';
import { authSessions, userProfiles, users } from '../db/schema';
import { newId } from '../lib/ids';
import { parseBody } from '../lib/http';
import { ApiError } from '../lib/errors';
import { randomToken, sha256Hex } from '../lib/crypto';
import { signAccessToken } from '../lib/jwt';
import { verifyGoogleIdToken } from '../lib/google';
import { requireAuth } from '../middleware/auth';
import type { AppEnv, AuthUser, Bindings } from '../env';

const auth = new Hono<AppEnv>();

const DEFAULT_ACCESS_TTL_S = 3600;
const DEFAULT_REFRESH_TTL_S = 30 * 24 * 3600;

const ttl = (raw: string | undefined, fallback: number): number => {
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? n : fallback;
};

// Commas, semicolons and whitespace all separate entries, so a list pasted one
// id per line into a GitHub variable still parses.
const csv = (raw: string | undefined): string[] =>
  (raw ?? '').split(/[\s,;]+/).filter((s) => s.length > 0);

const deviceSchema = {
  deviceName: z.string().max(120).optional(),
  platform: z.string().max(32).optional(),
  appVersion: z.string().max(32).optional(),
};

const googleSchema = z.object({
  idToken: z.string().min(1),
  ...deviceSchema,
});

const refreshSchema = z.object({ refreshToken: z.string().min(1), ...deviceSchema });
const logoutSchema = z.object({ refreshToken: z.string().min(1) });

interface DeviceInfo {
  deviceName?: string | undefined;
  platform?: string | undefined;
  appVersion?: string | undefined;
}

/**
 * Issues an access JWT plus a fresh opaque refresh token. Only sha256(token) is
 * persisted, so a database dump can never be replayed as a session. The
 * plaintext exists exactly once: in the response body returned to the caller.
 */
async function issueSession(
  db: AppEnv['Variables']['db'],
  env: Bindings,
  user: AuthUser,
  device: DeviceInfo,
  ipAddress: string | undefined,
) {
  const accessTtl = ttl(env.ACCESS_TOKEN_TTL_SECONDS, DEFAULT_ACCESS_TTL_S);
  const refreshTtl = ttl(env.REFRESH_TOKEN_TTL_SECONDS, DEFAULT_REFRESH_TTL_S);

  const refreshToken = randomToken(32);
  const now = Date.now();
  const sessionId = newId();

  await db.insert(authSessions).values({
    id: sessionId,
    userId: user.id,
    refreshTokenHash: await sha256Hex(refreshToken),
    deviceName: device.deviceName ?? null,
    platform: device.platform ?? null,
    appVersion: device.appVersion ?? null,
    ipAddress: ipAddress ?? null,
    expiresAt: now + refreshTtl * 1000,
    revokedAt: null,
    lastUsedAt: now,
    createdAt: now,
  });

  const { token, expiresAt } = await signAccessToken(user, env.JWT_SECRET, accessTtl);
  return { sessionId, accessToken: token, refreshToken, expiresAt };
}

const clientIp = (header: string | undefined): string | undefined =>
  header?.split(',')[0]?.trim() || undefined;

/* -------------------------------------------------------------------------- */
/* POST /v1/auth/google                                                        */
/* -------------------------------------------------------------------------- */

auth.post('/google', async (c) => {
  const body = await parseBody(c, googleSchema);
  const db = c.get('db');

  const audiences = csv(c.env.GOOGLE_CLIENT_IDS);
  if (audiences.length === 0) {
    throw new ApiError('INTERNAL', 'GOOGLE_CLIENT_IDS is not configured');
  }
  const claims = await verifyGoogleIdToken(body.idToken, audiences);
  if (!claims.email) throw new ApiError('UNAUTHENTICATED', 'id_token carries no email');

  const email = claims.email.toLowerCase();
  const shouldBeAdmin = csv(c.env.BOOTSTRAP_ADMIN_EMAILS)
    .map((e) => e.toLowerCase())
    .includes(email);

  const bySub = await db.select().from(users).where(eq(users.googleSub, claims.sub)).limit(1);
  let row = bySub[0];

  // Google is the only sign-in method and the email is verified by Google, so an
  // existing row with the same email is the same person re-linking a client.
  if (!row) {
    const byEmail = await db.select().from(users).where(eq(users.email, email)).limit(1);
    row = byEmail[0];
  }

  const now = Date.now();

  if (!row) {
    const id = newId();
    await db.insert(users).values({
      id,
      googleSub: claims.sub,
      email,
      emailVerified: claims.email_verified !== false,
      displayName: claims.name ?? null,
      avatarRemoteUrl: claims.picture ?? null,
      role: shouldBeAdmin ? 'admin' : 'user',
      createdAt: now,
      updatedAt: now,
    });
    await db.insert(userProfiles).values({ userId: id, createdAt: now, updatedAt: now });
    const created = await db.select().from(users).where(eq(users.id, id)).limit(1);
    row = created[0];
    if (!row) throw new ApiError('INTERNAL', 'User row disappeared right after insert');
  } else {
    // Signing in reactivates a soft-deleted account; the account is only really
    // gone once the retention sweep removes it.
    await db.update(users).set({
      googleSub: claims.sub,
      email,
      emailVerified: claims.email_verified !== false,
      displayName: row.displayName ?? claims.name ?? null,
      avatarRemoteUrl: claims.picture ?? row.avatarRemoteUrl ?? null,
      ...(shouldBeAdmin ? { role: 'admin' as const } : {}),
      deletedAt: null,
      updatedAt: now,
    }).where(eq(users.id, row.id));

    // The profile row is created lazily for accounts predating this endpoint.
    const profile = await db.select({ userId: userProfiles.userId })
      .from(userProfiles).where(eq(userProfiles.userId, row.id)).limit(1);
    if (!profile[0]) {
      await db.insert(userProfiles).values({ userId: row.id, createdAt: now, updatedAt: now });
    }

    row = {
      ...row,
      email,
      googleSub: claims.sub,
      role: shouldBeAdmin ? 'admin' : row.role,
      deletedAt: null,
    };
  }

  const authUser: AuthUser = {
    id: row.id,
    email: row.email,
    role: row.role,
    timezone: row.timezone,
    locale: row.locale,
  };

  const session = await issueSession(
    db, c.env, authUser, body, clientIp(c.req.header('CF-Connecting-IP')),
  );

  return c.json({
    accessToken: session.accessToken,
    refreshToken: session.refreshToken,
    expiresAt: session.expiresAt,
    user: {
      id: row.id,
      email: row.email,
      displayName: row.displayName,
      avatarAssetId: row.avatarAssetId,
      avatarRemoteUrl: row.avatarRemoteUrl,
      role: row.role,
      locale: row.locale,
      unitSystem: row.unitSystem,
      timezone: row.timezone,
      createdAt: row.createdAt,
    },
  });
});

/* -------------------------------------------------------------------------- */
/* POST /v1/auth/refresh — rotation                                            */
/* -------------------------------------------------------------------------- */

auth.post('/refresh', async (c) => {
  const body = await parseBody(c, refreshSchema);
  const db = c.get('db');
  const hash = await sha256Hex(body.refreshToken);

  const found = await db.select()
    .from(authSessions)
    .where(eq(authSessions.refreshTokenHash, hash))
    .limit(1);
  const session = found[0];
  // One generic message for every failure mode — an attacker learns nothing
  // about whether the token existed, was revoked, or merely expired.
  if (!session) throw new ApiError('UNAUTHENTICATED', 'Refresh token is not valid');
  if (session.revokedAt !== null) {
    throw new ApiError('UNAUTHENTICATED', 'Refresh token is not valid');
  }
  if (session.expiresAt <= Date.now()) {
    throw new ApiError('UNAUTHENTICATED', 'Refresh token is not valid');
  }

  const userRows = await db.select().from(users)
    .where(and(eq(users.id, session.userId), isNull(users.deletedAt)))
    .limit(1);
  const user = userRows[0];
  if (!user) throw new ApiError('UNAUTHENTICATED', 'Refresh token is not valid');

  const now = Date.now();
  // Rotate: the presented token dies here, whatever happens next.
  await db.update(authSessions)
    .set({ revokedAt: now, lastUsedAt: now })
    .where(eq(authSessions.id, session.id));

  const issued = await issueSession(
    db,
    c.env,
    {
      id: user.id,
      email: user.email,
      role: user.role,
      timezone: user.timezone,
      locale: user.locale,
    },
    {
      deviceName: body.deviceName ?? session.deviceName ?? undefined,
      platform: body.platform ?? session.platform ?? undefined,
      appVersion: body.appVersion ?? session.appVersion ?? undefined,
    },
    clientIp(c.req.header('CF-Connecting-IP')) ?? session.ipAddress ?? undefined,
  );

  return c.json({
    accessToken: issued.accessToken,
    refreshToken: issued.refreshToken,
    expiresAt: issued.expiresAt,
  });
});

/* -------------------------------------------------------------------------- */
/* POST /v1/auth/logout — revoke one session                                   */
/* -------------------------------------------------------------------------- */

auth.post('/logout', async (c) => {
  const body = await parseBody(c, logoutSchema);
  const db = c.get('db');
  const hash = await sha256Hex(body.refreshToken);
  const now = Date.now();

  // Unconditional 204: logout never reveals whether the token was real.
  await db.update(authSessions)
    .set({ revokedAt: now, lastUsedAt: now })
    .where(and(eq(authSessions.refreshTokenHash, hash), isNull(authSessions.revokedAt)));

  return c.body(null, 204);
});

/* -------------------------------------------------------------------------- */
/* DELETE /v1/auth/sessions — revoke every session of the caller               */
/* /v1/auth is mounted without auth, so requireAuth is applied to this route    */
/* alone.                                                                      */
/* -------------------------------------------------------------------------- */

auth.delete('/sessions', requireAuth, async (c) => {
  const db = c.get('db');
  const user = c.get('user');
  const now = Date.now();

  await db.update(authSessions)
    .set({ revokedAt: now })
    .where(and(eq(authSessions.userId, user.id), isNull(authSessions.revokedAt)));

  return c.body(null, 204);
});

export default auth;
