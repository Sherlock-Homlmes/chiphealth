import { sign, verify } from 'hono/jwt';
import type { AuthUser } from '../env';

export interface AccessTokenPayload {
  /** hono's JWTPayload is an open record, so the index signature is required. */
  [key: string]: unknown;
  sub: string;
  email: string;
  role: 'user' | 'admin';
  tz: string;
  locale: string;
  exp: number;
  iat: number;
}

export async function signAccessToken(
  user: AuthUser, secret: string, ttlSeconds: number,
): Promise<{ token: string; expiresAt: number }> {
  const nowSec = Math.floor(Date.now() / 1000);
  const payload: AccessTokenPayload = {
    sub: user.id,
    email: user.email,
    role: user.role,
    tz: user.timezone,
    locale: user.locale,
    iat: nowSec,
    exp: nowSec + ttlSeconds,
  };
  return { token: await sign(payload, secret), expiresAt: (nowSec + ttlSeconds) * 1000 };
}

export async function verifyAccessToken(
  token: string, secret: string,
): Promise<AccessTokenPayload> {
  return (await verify(token, secret, 'HS256')) as unknown as AccessTokenPayload;
}
