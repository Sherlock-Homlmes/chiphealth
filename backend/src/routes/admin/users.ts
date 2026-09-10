import { Hono } from 'hono';
import { and, desc, eq, like, or, sql } from 'drizzle-orm';
import { z } from 'zod';
import { users } from '../../db/schema';
import { parseBody, parseQuery, paginationSchema, page } from '../../lib/http';
import { ApiError, notFound } from '../../lib/errors';
import type { AppEnv } from '../../env';

const app = new Hono<AppEnv>();

app.get('/', async (c) => {
  const q = parseQuery(c, paginationSchema.extend({ q: z.string().max(200).optional() }));

  const filters = [];
  if (q.q) {
    filters.push(or(like(users.email, `%${q.q}%`), like(users.displayName, `%${q.q}%`)));
  }
  if (q.cursor) filters.push(sql`${users.id} < ${q.cursor}`);

  const rows = await c.get('db').select({
    id: users.id,
    email: users.email,
    displayName: users.displayName,
    role: users.role,
    locale: users.locale,
    timezone: users.timezone,
    createdAt: users.createdAt,
    deletedAt: users.deletedAt,
  }).from(users)
    .where(filters.length ? and(...filters) : undefined)
    .orderBy(desc(users.id)).limit(q.limit + 1);

  return c.json(page(rows, q.limit));
});

app.patch('/:id/role', async (c) => {
  const body = await parseBody(c, z.object({ role: z.enum(['user', 'admin']) }));
  const db = c.get('db');
  const targetId = c.req.param('id');

  // Losing your own admin rights mid-session locks you out of this panel.
  if (targetId === c.get('user').id && body.role !== 'admin') {
    throw new ApiError('CONFLICT', 'You cannot demote yourself');
  }

  await db.update(users).set({ role: body.role, updatedAt: Date.now() })
    .where(eq(users.id, targetId));

  const rows = await db.select({
    id: users.id, email: users.email, role: users.role,
  }).from(users).where(eq(users.id, targetId)).limit(1);

  if (!rows[0]) throw notFound('User');
  return c.json(rows[0]);
});

export default app;
