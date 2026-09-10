import { Hono } from 'hono';
import { and, asc, eq } from 'drizzle-orm';
import { z } from 'zod';
import { activityTypes, workoutExercises, translations } from '../../db/schema';
import { parseBody, parseQuery } from '../../lib/http';
import { notFound } from '../../lib/errors';
import type { AppEnv } from '../../env';

const app = new Hono<AppEnv>();

const activitySchema = z.object({
  code: z.string().min(1).max(60),
  category: z.enum(['cardio_gps', 'cardio_indoor', 'strength', 'sport', 'mind_body', 'other']),
  defaultMet: z.number().positive(),
  supportsGps: z.boolean().default(false),
  supportsSets: z.boolean().default(false),
  supportsHeartRate: z.boolean().default(true),
  iconName: z.string().max(60).nullish(),
  sortOrder: z.number().int().default(0),
  isActive: z.boolean().default(true),
});

app.get('/activity-types', async (c) => {
  const rows = await c.get('db').select().from(activityTypes)
    .orderBy(asc(activityTypes.sortOrder), asc(activityTypes.id));
  return c.json({ items: rows });
});

app.post('/activity-types', async (c) => {
  const body = await parseBody(c, activitySchema);
  const inserted = await c.get('db').insert(activityTypes).values(body).returning();
  return c.json(inserted[0], 201);
});

app.patch('/activity-types/:id', async (c) => {
  const body = await parseBody(c, activitySchema.partial());
  const db = c.get('db');
  const id = Number(c.req.param('id'));

  await db.update(activityTypes).set(body).where(eq(activityTypes.id, id));
  const rows = await db.select().from(activityTypes).where(eq(activityTypes.id, id)).limit(1);
  if (!rows[0]) throw notFound('Activity type');
  return c.json(rows[0]);
});

const exerciseSchema = z.object({
  code: z.string().min(1).max(60),
  muscleGroup: z.string().min(1).max(60),
  equipment: z.string().max(60).nullish(),
  isUnilateral: z.boolean().default(false),
  sortOrder: z.number().int().default(0),
});

app.get('/exercises', async (c) => {
  const rows = await c.get('db').select().from(workoutExercises)
    .orderBy(asc(workoutExercises.sortOrder), asc(workoutExercises.id));
  return c.json({ items: rows });
});

app.post('/exercises', async (c) => {
  const body = await parseBody(c, exerciseSchema);
  const inserted = await c.get('db').insert(workoutExercises).values(body).returning();
  return c.json(inserted[0], 201);
});

app.patch('/exercises/:id', async (c) => {
  const body = await parseBody(c, exerciseSchema.partial());
  const db = c.get('db');
  const id = Number(c.req.param('id'));

  await db.update(workoutExercises).set(body).where(eq(workoutExercises.id, id));
  const rows = await db.select().from(workoutExercises).where(eq(workoutExercises.id, id)).limit(1);
  if (!rows[0]) throw notFound('Exercise');
  return c.json(rows[0]);
});

// -------------------------------------------------------------- i18n

app.get('/translations', async (c) => {
  const q = parseQuery(c, z.object({
    entityType: z.string().min(1),
    entityId: z.string().min(1).optional(),
  }));

  const filters = [eq(translations.entityType, q.entityType)];
  if (q.entityId) filters.push(eq(translations.entityId, q.entityId));

  const rows = await c.get('db').select().from(translations).where(and(...filters));
  return c.json({ items: rows });
});

/**
 * Batch upsert for one entity: the editor saves vi and en together, so a partial
 * failure would leave the two languages out of sync.
 */
app.put('/translations', async (c) => {
  const q = parseQuery(c, z.object({
    entityType: z.string().min(1).max(60),
    entityId: z.string().min(1).max(60),
  }));
  const body = await parseBody(c, z.object({
    translations: z.array(z.object({
      locale: z.enum(['vi', 'en']),
      field: z.string().min(1).max(60).default('name'),
      value: z.string().min(1).max(500),
    })).min(1).max(20),
  }));

  const db = c.get('db');
  for (const t of body.translations) {
    await db.insert(translations).values({
      entityType: q.entityType, entityId: q.entityId, ...t,
    }).onConflictDoUpdate({
      target: [
        translations.entityType, translations.entityId, translations.locale, translations.field,
      ],
      set: { value: t.value },
    });
  }

  const rows = await db.select().from(translations).where(and(
    eq(translations.entityType, q.entityType),
    eq(translations.entityId, q.entityId),
  ));
  return c.json({ items: rows });
});

export default app;
