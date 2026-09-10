import type { MiddlewareHandler } from 'hono';
import { forbidden } from '../lib/errors';
import type { AppEnv } from '../env';

/** Must run after requireAuth. */
export const requireAdmin: MiddlewareHandler<AppEnv> = async (c, next) => {
  if (c.get('user')?.role !== 'admin') throw forbidden();
  await next();
};
