import { Hono } from 'hono';
import { and, desc, eq, sql } from 'drizzle-orm';
import { z } from 'zod';
import { foodKbDocuments } from '../../db/schema';
import { parseBody, parseQuery, paginationSchema, page } from '../../lib/http';
import { notFound } from '../../lib/errors';
import { newId } from '../../lib/ids';
import { upsertVector, deleteVectors, vectorId } from '../../services/vectorize';
import { modelConfig } from '../../config/models';
import type { AppEnv } from '../../env';

const app = new Hono<AppEnv>();

const docSchema = z.object({
  title: z.string().min(1).max(200),
  content: z.string().min(1).max(20000),
  foodId: z.string().uuid().nullish(),
  locale: z.enum(['vi', 'en']).default('vi'),
  isActive: z.boolean().default(true),
});

async function reindex(
  env: AppEnv['Bindings'],
  db: AppEnv['Variables']['db'],
  doc: { id: string; title: string; content: string; locale: string },
): Promise<void> {
  const { embedding } = modelConfig(env);
  try {
    const vid = await upsertVector(env, 'kb', doc.id, `${doc.title}\n${doc.content}`, {
      title: doc.title, locale: doc.locale,
    });
    await db.update(foodKbDocuments)
      .set({ vectorizeId: vid, embeddingModel: embedding, embeddingStatus: 'indexed' })
      .where(eq(foodKbDocuments.id, doc.id));
  } catch (err) {
    console.error('kb embedding failed', doc.id, err);
    await db.update(foodKbDocuments).set({ embeddingStatus: 'failed' })
      .where(eq(foodKbDocuments.id, doc.id));
  }
}

app.get('/', async (c) => {
  const q = parseQuery(c, paginationSchema.extend({
    locale: z.enum(['vi', 'en']).optional(),
    status: z.enum(['pending', 'indexed', 'failed']).optional(),
  }));

  const filters = [];
  if (q.locale) filters.push(eq(foodKbDocuments.locale, q.locale));
  if (q.status) filters.push(eq(foodKbDocuments.embeddingStatus, q.status));
  if (q.cursor) filters.push(sql`${foodKbDocuments.id} < ${q.cursor}`);

  const rows = await c.get('db').select().from(foodKbDocuments)
    .where(filters.length ? and(...filters) : undefined)
    .orderBy(desc(foodKbDocuments.id)).limit(q.limit + 1);
  return c.json(page(rows, q.limit));
});

app.get('/:id', async (c) => {
  const rows = await c.get('db').select().from(foodKbDocuments)
    .where(eq(foodKbDocuments.id, c.req.param('id'))).limit(1);
  if (!rows[0]) throw notFound('Document');
  return c.json(rows[0]);
});

app.post('/', async (c) => {
  const body = await parseBody(c, docSchema);
  const db = c.get('db');
  const id = newId();
  const now = Date.now();

  await db.insert(foodKbDocuments).values({
    id,
    title: body.title,
    content: body.content,
    foodId: body.foodId ?? null,
    locale: body.locale,
    isActive: body.isActive,
    embeddingStatus: 'pending',
    uploadedBy: c.get('user').id,
    createdAt: now,
    updatedAt: now,
  });

  c.executionCtx.waitUntil(reindex(c.env, db, { id, ...body }));

  const rows = await db.select().from(foodKbDocuments).where(eq(foodKbDocuments.id, id)).limit(1);
  return c.json(rows[0], 201);
});

app.patch('/:id', async (c) => {
  const body = await parseBody(c, docSchema.partial());
  const db = c.get('db');
  const id = c.req.param('id');

  const existing = await db.select().from(foodKbDocuments)
    .where(eq(foodKbDocuments.id, id)).limit(1);
  const current = existing[0];
  if (!current) throw notFound('Document');

  const textChanged = (body.title !== undefined && body.title !== current.title)
    || (body.content !== undefined && body.content !== current.content);

  await db.update(foodKbDocuments).set({
    ...body,
    ...(textChanged ? { embeddingStatus: 'pending' as const } : {}),
    updatedAt: Date.now(),
  }).where(eq(foodKbDocuments.id, id));

  if (textChanged) {
    const merged = { ...current, ...body };
    c.executionCtx.waitUntil(reindex(c.env, db, {
      id, title: merged.title, content: merged.content, locale: merged.locale,
    }));
  }

  const rows = await db.select().from(foodKbDocuments).where(eq(foodKbDocuments.id, id)).limit(1);
  return c.json(rows[0]);
});

app.delete('/:id', async (c) => {
  const id = c.req.param('id');
  await c.get('db').delete(foodKbDocuments).where(eq(foodKbDocuments.id, id));
  c.executionCtx.waitUntil(
    deleteVectors(c.env, [vectorId('kb', id)]).catch(() => undefined),
  );
  return c.body(null, 204);
});

app.post('/:id/reindex', async (c) => {
  const db = c.get('db');
  const rows = await db.select().from(foodKbDocuments)
    .where(eq(foodKbDocuments.id, c.req.param('id'))).limit(1);
  const doc = rows[0];
  if (!doc) throw notFound('Document');

  await reindex(c.env, db, doc);
  const updated = await db.select().from(foodKbDocuments)
    .where(eq(foodKbDocuments.id, doc.id)).limit(1);
  return c.json(updated[0]);
});

/** Batched so one call cannot blow the Worker CPU limit on a large corpus. */
app.post('/reindex-all', async (c) => {
  const q = parseQuery(c, z.object({
    limit: z.coerce.number().int().min(1).max(100).default(50),
  }));
  const db = c.get('db');

  const rows = await db.select().from(foodKbDocuments)
    .where(and(
      eq(foodKbDocuments.isActive, true),
      sql`(${foodKbDocuments.embeddingStatus} is null or ${foodKbDocuments.embeddingStatus} != 'indexed')`,
    ))
    .limit(q.limit);

  c.executionCtx.waitUntil((async () => {
    for (const doc of rows) await reindex(c.env, db, doc);
  })());

  return c.json({ queued: rows.length }, 202);
});

export default app;
