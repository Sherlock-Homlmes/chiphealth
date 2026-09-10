import { Hono } from 'hono';
import { and, eq, inArray, asc } from 'drizzle-orm';
import { z } from 'zod';
import { activityTypes, workoutExercises, translations } from '../db/schema';
import { parseQuery } from '../lib/http';
import type { AppEnv } from '../env';

const app = new Hono<AppEnv>();

const querySchema = z.object({
  locale: z.enum(['vi', 'en']).default('vi'),
});

/** One query for display names. `translations.entity_id` is text, so ids are stringified. */
async function nameMap(
  db: AppEnv['Variables']['db'], entityType: string, ids: number[], locale: string,
): Promise<Map<string, string>> {
  if (ids.length === 0) return new Map();
  const rows = await db.select({
    entityId: translations.entityId,
    value: translations.value,
  }).from(translations).where(and(
    eq(translations.entityType, entityType),
    eq(translations.locale, locale),
    eq(translations.field, 'name'),
    inArray(translations.entityId, ids.map(String)),
  ));
  return new Map(rows.map((r) => [r.entityId, r.value]));
}

app.get('/activity-types', async (c) => {
  const { locale } = parseQuery(c, querySchema);
  const db = c.get('db');

  const rows = await db.select().from(activityTypes)
    .where(eq(activityTypes.isActive, true))
    .orderBy(asc(activityTypes.sortOrder), asc(activityTypes.id));

  const names = await nameMap(db, 'activity_types', rows.map((r) => r.id), locale);

  c.header('Cache-Control', 'public, max-age=3600');
  return c.json({
    items: rows.map((r) => ({
      id: r.id,
      code: r.code,
      name: names.get(String(r.id)) ?? r.code,
      category: r.category,
      defaultMet: r.defaultMet,
      supportsGps: r.supportsGps,
      supportsSets: r.supportsSets,
      supportsHeartRate: r.supportsHeartRate,
      iconName: r.iconName,
    })),
  });
});

app.get('/exercises', async (c) => {
  const { locale } = parseQuery(c, querySchema);
  const db = c.get('db');

  const rows = await db.select().from(workoutExercises)
    .orderBy(asc(workoutExercises.sortOrder), asc(workoutExercises.id));

  const names = await nameMap(db, 'workout_exercises', rows.map((r) => r.id), locale);

  c.header('Cache-Control', 'public, max-age=3600');
  return c.json({
    items: rows.map((r) => ({
      id: r.id,
      code: r.code,
      name: names.get(String(r.id)) ?? r.code,
      muscleGroup: r.muscleGroup,
      equipment: r.equipment,
      isUnilateral: r.isUnilateral,
    })),
  });
});

export default app;
