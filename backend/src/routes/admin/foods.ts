import { Hono } from 'hono';
import type { Context } from 'hono';
import { and, desc, eq, like, sql } from 'drizzle-orm';
import { z } from 'zod';
import { foods } from '../../db/schema';
import { parseBody, parseQuery, paginationSchema, page } from '../../lib/http';
import { ApiError, notFound } from '../../lib/errors';
import { newId } from '../../lib/ids';
import { upsertVector, deleteVectors, vectorId } from '../../services/vectorize';
import type { AppEnv } from '../../env';

const app = new Hono<AppEnv>();

const nutritionFields = {
  caloriesKcal: z.number().nonnegative(),
  proteinG: z.number().nonnegative().nullish(),
  carbsG: z.number().nonnegative().nullish(),
  fatG: z.number().nonnegative().nullish(),
  saturatedFatG: z.number().nonnegative().nullish(),
  fiberG: z.number().nonnegative().nullish(),
  sugarG: z.number().nonnegative().nullish(),
  sodiumMg: z.number().nonnegative().nullish(),
  cholesterolMg: z.number().nonnegative().nullish(),
  potassiumMg: z.number().nonnegative().nullish(),
  calciumMg: z.number().nonnegative().nullish(),
  ironMg: z.number().nonnegative().nullish(),
};

export const foodPayloadSchema = z.object({
  barcode: z.string().min(6).max(32).nullish(),
  name: z.string().min(1).max(200),
  brand: z.string().max(120).nullish(),
  category: z.string().max(60).nullish(),
  servingSizeG: z.number().positive().default(100),
  servingLabel: z.string().max(100).nullish(),
  micronutrientsJson: z.string().nullish(),
  isVerified: z.boolean().default(true),
  ...nutritionFields,
});

/** The text that gets embedded — name carries most of the signal. */
export const embedText = (row: { name: string; brand?: string | null; category?: string | null }) =>
  [row.name, row.brand, row.category].filter(Boolean).join(' · ');

/**
 * Embedding runs in waitUntil: a Vectorize outage must never fail an admin's
 * save. `embedding_status` records what happened so it can be retried.
 */
export function queueEmbedding(
  c: Context<AppEnv>,
  id: string,
  text: string,
  metadata: Record<string, string | number | boolean>,
): void {
  const db = c.get('db');
  c.executionCtx.waitUntil((async () => {
    try {
      await upsertVector(c.env, 'food', id, text, metadata);
      await db.update(foods).set({ embeddingStatus: 'indexed' }).where(eq(foods.id, id));
    } catch (err) {
      console.error('food embedding failed', id, err);
      await db.update(foods).set({ embeddingStatus: 'failed' }).where(eq(foods.id, id));
    }
  })());
}

app.get('/', async (c) => {
  const q = parseQuery(c, paginationSchema.extend({
    q: z.string().max(200).optional(),
    source: z.enum(['admin_barcode', 'admin_manual', 'rag_matched', 'web_search', 'ai_estimated']).optional(),
    verified: z.enum(['true', 'false']).optional(),
  }));

  const filters = [];
  if (q.q) filters.push(like(foods.name, `%${q.q}%`));
  if (q.source) filters.push(eq(foods.source, q.source));
  if (q.verified) filters.push(eq(foods.isVerified, q.verified === 'true'));
  if (q.cursor) filters.push(sql`${foods.id} < ${q.cursor}`);

  const rows = await c.get('db').select().from(foods)
    .where(filters.length ? and(...filters) : undefined)
    .orderBy(desc(foods.id)).limit(q.limit + 1);
  return c.json(page(rows, q.limit));
});

/** Prefill source: an existing product for a barcode the admin is about to enter. */
app.get('/by-barcode/:code', async (c) => {
  const rows = await c.get('db').select().from(foods)
    .where(eq(foods.barcode, c.req.param('code'))).limit(1);
  if (!rows[0]) throw notFound('Food');
  return c.json(rows[0]);
});

app.get('/:id', async (c) => {
  const rows = await c.get('db').select().from(foods)
    .where(eq(foods.id, c.req.param('id'))).limit(1);
  if (!rows[0]) throw notFound('Food');
  return c.json(rows[0]);
});

app.post('/', async (c) => {
  const body = await parseBody(c, foodPayloadSchema);
  const db = c.get('db');
  const id = newId();
  const now = Date.now();

  if (body.barcode) {
    const clash = await db.select({ id: foods.id }).from(foods)
      .where(eq(foods.barcode, body.barcode)).limit(1);
    if (clash[0]) throw new ApiError('CONFLICT', 'Barcode already exists');
  }

  await db.insert(foods).values({
    id,
    barcode: body.barcode ?? null,
    name: body.name,
    brand: body.brand ?? null,
    category: body.category ?? null,
    servingSizeG: body.servingSizeG,
    servingLabel: body.servingLabel ?? null,
    caloriesKcal: body.caloriesKcal,
    proteinG: body.proteinG ?? null,
    carbsG: body.carbsG ?? null,
    fatG: body.fatG ?? null,
    saturatedFatG: body.saturatedFatG ?? null,
    fiberG: body.fiberG ?? null,
    sugarG: body.sugarG ?? null,
    sodiumMg: body.sodiumMg ?? null,
    cholesterolMg: body.cholesterolMg ?? null,
    potassiumMg: body.potassiumMg ?? null,
    calciumMg: body.calciumMg ?? null,
    ironMg: body.ironMg ?? null,
    micronutrientsJson: body.micronutrientsJson ?? null,
    // A barcode makes it a packaged product; without one it is a curated dish.
    source: body.barcode ? 'admin_barcode' : 'admin_manual',
    isVerified: body.isVerified,
    embeddingStatus: 'pending',
    createdBy: c.get('user').id,
    createdAt: now,
    updatedAt: now,
  });

  queueEmbedding(c, id, embedText(body), { title: body.name, verified: body.isVerified });

  const rows = await db.select().from(foods).where(eq(foods.id, id)).limit(1);
  return c.json(rows[0], 201);
});

app.patch('/:id', async (c) => {
  const body = await parseBody(c, foodPayloadSchema.partial());
  const db = c.get('db');
  const id = c.req.param('id');

  const existing = await db.select().from(foods).where(eq(foods.id, id)).limit(1);
  const current = existing[0];
  if (!current) throw notFound('Food');

  // Only the embedded fields justify paying for a re-embed.
  const textChanged = (['name', 'brand', 'category'] as const)
    .some((k) => body[k] !== undefined && body[k] !== current[k]);

  await db.update(foods).set({
    ...body,
    ...(textChanged ? { embeddingStatus: 'pending' as const } : {}),
    updatedAt: Date.now(),
  }).where(eq(foods.id, id));

  if (textChanged) {
    const merged = { ...current, ...body };
    queueEmbedding(c, id, embedText(merged), {
      title: merged.name, verified: merged.isVerified ?? false,
    });
  }

  const rows = await db.select().from(foods).where(eq(foods.id, id)).limit(1);
  return c.json(rows[0]);
});

app.post('/:id/verify', async (c) => {
  const body = await parseBody(c, z.object({ isVerified: z.boolean() }));
  const db = c.get('db');

  await db.update(foods).set({ isVerified: body.isVerified, updatedAt: Date.now() })
    .where(eq(foods.id, c.req.param('id')));

  const rows = await db.select().from(foods).where(eq(foods.id, c.req.param('id'))).limit(1);
  if (!rows[0]) throw notFound('Food');
  return c.json(rows[0]);
});

app.delete('/:id', async (c) => {
  const id = c.req.param('id');
  await c.get('db').delete(foods).where(eq(foods.id, id));
  c.executionCtx.waitUntil(
    deleteVectors(c.env, [vectorId('food', id)]).catch(() => undefined),
  );
  return c.body(null, 204);
});

/**
 * Minimal CSV reader: quoted fields, doubled quotes, embedded commas/newlines.
 * A dependency is not worth it for one admin import path.
 */
export function parseCsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = '';
  let inQuotes = false;

  for (let i = 0; i < text.length; i++) {
    const ch = text[i]!;
    if (inQuotes) {
      if (ch === '"') {
        if (text[i + 1] === '"') { field += '"'; i++; } else inQuotes = false;
      } else field += ch;
      continue;
    }
    if (ch === '"') inQuotes = true;
    else if (ch === ',') { row.push(field); field = ''; }
    else if (ch === '\n') { row.push(field); rows.push(row); row = []; field = ''; }
    else if (ch !== '\r') field += ch;
  }
  if (field.length > 0 || row.length > 0) { row.push(field); rows.push(row); }
  return rows.filter((r) => r.some((cell) => cell.trim() !== ''));
}

const NUMERIC_COLUMNS = new Set([
  'servingSizeG', 'caloriesKcal', 'proteinG', 'carbsG', 'fatG', 'saturatedFatG',
  'fiberG', 'sugarG', 'sodiumMg', 'cholesterolMg', 'potassiumMg', 'calciumMg', 'ironMg',
]);

/** CSV is all strings; coerce the known numeric and boolean columns before zod. */
function csvToObjects(text: string): unknown[] {
  const rows = parseCsv(text);
  const header = rows[0];
  if (!header) return [];

  return rows.slice(1).map((cells) => {
    const obj: Record<string, unknown> = {};
    header.forEach((rawKey, i) => {
      const key = rawKey.trim();
      const value = (cells[i] ?? '').trim();
      if (value === '') return;
      if (NUMERIC_COLUMNS.has(key)) {
        const n = Number(value);
        obj[key] = Number.isFinite(n) ? n : value;
      } else if (key === 'isVerified') {
        obj[key] = value === 'true' || value === '1';
      } else {
        obj[key] = value;
      }
    });
    return obj;
  });
}

/** Bulk import returns a per-row report rather than failing the whole batch. */
app.post('/import', async (c) => {
  const body = await parseBody(c, z.object({
    format: z.enum(['csv', 'json']),
    content: z.string().min(1),
  }));

  let items: unknown[];
  if (body.format === 'csv') {
    items = csvToObjects(body.content);
  } else {
    try {
      const parsed: unknown = JSON.parse(body.content);
      items = Array.isArray(parsed) ? parsed : [parsed];
    } catch {
      throw new ApiError('VALIDATION_ERROR', 'content is not valid JSON');
    }
  }

  if (items.length === 0) throw new ApiError('VALIDATION_ERROR', 'No rows found');
  if (items.length > 500) throw new ApiError('VALIDATION_ERROR', 'At most 500 rows per import');

  const db = c.get('db');
  const now = Date.now();
  type RowResult = {
    row: number;
    status: 'created' | 'updated' | 'skipped' | 'failed';
    foodId?: string;
    name?: string;
    message?: string;
  };
  const results: RowResult[] = [];

  for (const [index, raw] of items.entries()) {
    const parsed = foodPayloadSchema.safeParse(raw);
    if (!parsed.success) {
      const issue = parsed.error.issues[0];
      results.push({
        row: index + 1,
        status: 'failed',
        message: issue ? `${issue.path.join('.')}: ${issue.message}` : 'invalid row',
      });
      continue;
    }
    const data = parsed.data;
    try {
      const values = {
        barcode: data.barcode ?? null,
        name: data.name,
        brand: data.brand ?? null,
        category: data.category ?? null,
        servingSizeG: data.servingSizeG,
        servingLabel: data.servingLabel ?? null,
        caloriesKcal: data.caloriesKcal,
        proteinG: data.proteinG ?? null,
        carbsG: data.carbsG ?? null,
        fatG: data.fatG ?? null,
        saturatedFatG: data.saturatedFatG ?? null,
        fiberG: data.fiberG ?? null,
        sugarG: data.sugarG ?? null,
        sodiumMg: data.sodiumMg ?? null,
        cholesterolMg: data.cholesterolMg ?? null,
        potassiumMg: data.potassiumMg ?? null,
        calciumMg: data.calciumMg ?? null,
        ironMg: data.ironMg ?? null,
        source: (data.barcode ? 'admin_barcode' : 'admin_manual') as 'admin_barcode' | 'admin_manual',
        isVerified: data.isVerified,
        embeddingStatus: 'pending' as const,
        updatedAt: now,
      };

      // A row already owning this barcode is the same product: update it rather
      // than dropping the import line, so a re-import is a refresh, not a no-op.
      const existing = data.barcode
        ? await db.select({ id: foods.id }).from(foods)
            .where(eq(foods.barcode, data.barcode)).limit(1)
        : [];

      if (existing[0]) {
        await db.update(foods).set(values).where(eq(foods.id, existing[0].id));
        results.push({
          row: index + 1, status: 'updated', foodId: existing[0].id, name: data.name,
        });
        continue;
      }

      const id = newId();
      await db.insert(foods).values({
        id,
        createdBy: c.get('user').id,
        createdAt: now,
        ...values,
      });
      results.push({ row: index + 1, status: 'created', foodId: id, name: data.name });
    } catch (err) {
      const message = err instanceof Error ? err.message : 'insert failed';
      results.push({
        row: index + 1,
        status: 'failed',
        name: data.name,
        message,
      });
    }
  }

  const count = (status: RowResult['status']) =>
    results.filter((r) => r.status === status).length;

  return c.json({
    total: results.length,
    created: count('created'),
    updated: count('updated'),
    skipped: count('skipped'),
    failed: count('failed'),
    results,
  }, 201);
});

export default app;
