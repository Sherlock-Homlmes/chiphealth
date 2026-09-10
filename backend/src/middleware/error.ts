import type { ErrorHandler } from 'hono';
import { ApiError } from '../lib/errors';
import type { AppEnv } from '../env';

/**
 * Registered with app.onError. A try/catch middleware around next() does not
 * reliably intercept errors thrown by downstream handlers in Hono, so the
 * framework's own error hook is the only place that sees all of them.
 */
export const onError: ErrorHandler<AppEnv> = (err, c) => {
  if (err instanceof ApiError) {
    return c.json(err.toJSON(), err.status as 400);
  }

  console.error('unhandled', c.get('requestId'), err);
  const message = c.env.ENVIRONMENT === 'production'
    ? 'Internal error'
    : String(err instanceof Error ? err.stack ?? err.message : err);
  return c.json({ error: { code: 'INTERNAL', message } }, 500);
};
