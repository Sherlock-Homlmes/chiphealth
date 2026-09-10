import { Hono } from 'hono';
import { and, desc, eq } from 'drizzle-orm';
import { z } from 'zod';
import { barcodeScanMisses, foods, mediaAssets } from '../../db/schema';
import { parseBody, parseQuery, paginationSchema } from '../../lib/http';
import { ApiError, notFound } from '../../lib/errors';
import { newId } from '../../lib/ids';
import { foodPayloadSchema, embedText, queueEmbedding } from './foods';
import type { AppEnv } from '../../env';

const app = new Hono<AppEnv>();

/**
 * The admin work queue. Users scanning an unknown barcode land here, aggregated
 * by barcode, so `scan_count` says which product to enter next.
 */
app.get('/', async (c) => {
  const q = parseQuery(c, paginationSchema.extend({
    status: z.enum(['pending', 'resolved', 'rejected']).default('pending'),
  }));

  const rows = await c.get('db').select({
    miss: barcodeScanMisses,
    r2Key: mediaAssets.r2Key,
  }).from(barcodeScanMisses)
    .leftJoin(mediaAssets, eq(barcodeScanMisses.photoAssetId, mediaAssets.id))
    .where(eq(barcodeScanMisses.status, q.status))
    .orderBy(desc(barcodeScanMisses.scanCount), desc(barcodeScanMisses.lastScannedAt))
    .limit(q.limit);

  // The packaging photo lets the admin type the label without owning the product.
  const base = c.env.R2_PUBLIC_URL ?? c.env.R2_PUBLIC_BASE_URL;
  return c.json({
    items: rows.map(({ miss, r2Key }) => ({
      ...miss,
      photoUrl: base && r2Key ? `${base}/${r2Key}` : null,
    })),
    nextCursor: null,
  });
});

app.get('/:id', async (c) => {
  const rows = await c.get('db').select().from(barcodeScanMisses)
    .where(eq(barcodeScanMisses.id, c.req.param('id'))).limit(1);
  if (!rows[0]) throw notFound('Barcode miss');
  return c.json(rows[0]);
});

/** Creates the product and closes the queue item in one step. */
app.post('/:id/resolve', async (c) => {
  const body = await parseBody(c, foodPayloadSchema.omit({ barcode: true }));
  const db = c.get('db');
  const admin = c.get('user').id;

  const missRows = await db.select().from(barcodeScanMisses)
    .where(eq(barcodeScanMisses.id, c.req.param('id'))).limit(1);
  const miss = missRows[0];
  if (!miss) throw notFound('Barcode miss');
  if (miss.status !== 'pending') throw new ApiError('CONFLICT', 'Already handled');

  const clash = await db.select({ id: foods.id }).from(foods)
    .where(eq(foods.barcode, miss.barcode)).limit(1);
  if (clash[0]) throw new ApiError('CONFLICT', 'A food already owns this barcode');

  const foodId = newId();
  const now = Date.now();

  await db.insert(foods).values({
    id: foodId,
    barcode: miss.barcode,
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
    source: 'admin_barcode',
    isVerified: true,
    embeddingStatus: 'pending',
    createdBy: admin,
    createdAt: now,
    updatedAt: now,
  });

  await db.update(barcodeScanMisses).set({
    status: 'resolved',
    resolvedFoodId: foodId,
    resolvedBy: admin,
    resolvedAt: now,
  }).where(eq(barcodeScanMisses.id, miss.id));

  queueEmbedding(c, foodId, embedText(body), { title: body.name, verified: true });

  const [foodRows, missRow] = await Promise.all([
    db.select().from(foods).where(eq(foods.id, foodId)).limit(1),
    db.select().from(barcodeScanMisses).where(eq(barcodeScanMisses.id, miss.id)).limit(1),
  ]);
  return c.json({ food: foodRows[0], miss: { ...missRow[0], photoUrl: null } }, 201);
});

app.post('/:id/reject', async (c) => {
  const body = await parseBody(c, z.object({ adminNote: z.string().max(500) }));
  const db = c.get('db');

  await db.update(barcodeScanMisses).set({
    status: 'rejected',
    adminNote: body.adminNote,
    resolvedBy: c.get('user').id,
    resolvedAt: Date.now(),
  }).where(and(
    eq(barcodeScanMisses.id, c.req.param('id')),
    eq(barcodeScanMisses.status, 'pending'),
  ));

  const rows = await db.select().from(barcodeScanMisses)
    .where(eq(barcodeScanMisses.id, c.req.param('id'))).limit(1);
  if (!rows[0]) throw notFound('Barcode miss');
  return c.json(rows[0]);
});

export default app;
