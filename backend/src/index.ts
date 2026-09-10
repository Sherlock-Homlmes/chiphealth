import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { createDb } from './db/client';
import { onError } from './middleware/error';
import { requireAuth } from './middleware/auth';
import { requireAdmin } from './middleware/admin';
import type { AppEnv } from './env';

import authRoutes from './routes/auth';
import meRoutes from './routes/me';
import catalogRoutes from './routes/catalog';
import mediaRoutes from './routes/media';
import nutritionRoutes from './routes/nutrition';
import trainingRoutes from './routes/training';
import sleepRoutes from './routes/sleep';
import healthRoutes from './routes/health';
import coachRoutes from './routes/coach';
import socialRoutes from './routes/social';
import adminRoutes from './routes/admin';
import { runScheduled } from './cron';

const app = new Hono<AppEnv>();

app.use('*', async (c, next) => {
  c.set('requestId', crypto.randomUUID());
  c.set('db', createDb(c.env.DB));
  await next();
});

app.onError(onError);

// ADMIN_ORIGIN is a comma-separated list: dev runs on more than one host/port
// (127.0.0.1 and localhost are different origins to the browser), and a blocked
// preflight looks exactly like a broken session from inside the panel.
app.use('/v1/*', (c, next) =>
  cors({
    origin: (c.env.ADMIN_ORIGIN ?? '').split(',').map((o) => o.trim()).filter(Boolean),
    allowMethods: ['GET', 'POST', 'PATCH', 'PUT', 'DELETE', 'OPTIONS'],
    allowHeaders: ['Authorization', 'Content-Type'],
    maxAge: 86400,
  })(c, next));

app.get('/health', (c) => c.json({ ok: true, env: c.env.ENVIRONMENT }));

// Public
app.route('/v1/auth', authRoutes);
app.route('/v1/catalog', catalogRoutes);

/**
 * Auth is applied per prefix rather than with a catch-all on /v1, so an unknown
 * path falls through to notFound and answers 404 instead of 401. A blanket
 * `use('/v1/*')` makes every typo look like an auth failure, which is a poor
 * REST contract and confusing to debug.
 *
 * Hono patterns do not match the bare prefix, so each entry is registered twice:
 * `/v1/meals` and `/v1/meals/*`.
 */
const PROTECTED_PREFIXES = [
  '/v1/me', '/v1/media', '/v1/meals', '/v1/foods', '/v1/nutrition', '/v1/meal-plans',
  '/v1/workouts', '/v1/training', '/v1/sleep', '/v1/health', '/v1/coach',
  '/v1/friends', '/v1/moments', '/v1/messages',
];

for (const prefix of PROTECTED_PREFIXES) {
  app.use(prefix, requireAuth);
  app.use(`${prefix}/*`, requireAuth);
}
app.use('/v1/admin', requireAuth, requireAdmin);
app.use('/v1/admin/*', requireAuth, requireAdmin);

const authed = new Hono<AppEnv>();
authed.route('/me', meRoutes);
authed.route('/media', mediaRoutes);
authed.route('/', nutritionRoutes);   // /meals, /foods, /nutrition, /meal-plans
authed.route('/', trainingRoutes);    // /workouts, /training
authed.route('/sleep', sleepRoutes);
authed.route('/health', healthRoutes);
authed.route('/coach', coachRoutes);
authed.route('/', socialRoutes);      // /friends, /moments
app.route('/v1', authed);

app.route('/v1/admin', adminRoutes);

app.notFound((c) =>
  c.json({ error: { code: 'NOT_FOUND', message: `No route for ${c.req.path}` } }, 404));

export default {
  fetch: app.fetch,
  scheduled: runScheduled,
} satisfies ExportedHandler<AppEnv['Bindings']>;
