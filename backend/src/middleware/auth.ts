import type { MiddlewareHandler } from 'hono';
import { verifyAccessToken } from '../lib/jwt';
import { unauthenticated } from '../lib/errors';
import type { AppEnv } from '../env';

/** Requires a valid access token; populates c.get('user'). */
export const requireAuth: MiddlewareHandler<AppEnv> = async (c, next) => {
  const header = c.req.header('Authorization');
  // EventSource cannot set headers, so the SSE stream — and only the stream —
  // also takes the access token from the query string. Tokens in URLs end up in
  // logs and referrers, so no other route is allowed to authenticate this way.
  const token = header?.startsWith('Bearer ')
    ? header.slice(7)
    : (c.req.path.endsWith('/stream') ? c.req.query('access_token') : undefined);
  if (!token) throw unauthenticated();

  let payload;
  try {
    payload = await verifyAccessToken(token, c.env.JWT_SECRET);
  } catch {
    throw unauthenticated('Access token invalid or expired');
  }

  c.set('user', {
    id: payload.sub,
    email: payload.email,
    role: payload.role,
    timezone: payload.tz,
    locale: payload.locale,
  });
  await next();
};
