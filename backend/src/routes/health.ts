import { Hono } from 'hono';
import { and, eq, sql } from 'drizzle-orm';
import { z } from 'zod';
import {
  healthConnections, healthSyncCursors, dailyActivitySummaries,
  workoutSessions, sleepSessions, bodyMetricsLogs,
} from '../db/schema';
import { parseBody } from '../lib/http';
import { newId } from '../lib/ids';
import { localDate } from '../lib/time';
import { recomputeSleepDebt } from '../services/sleepDebt';
import { recomputeDailyNutritionSummary } from '../services/nutritionMath';
import { insertMany } from '../db/client';
import type { AppEnv } from '../env';

const app = new Hono<AppEnv>();

const PLATFORMS = ['apple_health', 'health_connect'] as const;

/**
 * Apple Health / Health Connect are read on-device by the app. No OAuth token is
 * stored server-side — this only records that permission was granted, so the
 * backend can tell a wearable user from an estimate-only one.
 */
app.get('/connection', async (c) => {
  const rows = await c.get('db').select().from(healthConnections)
    .where(eq(healthConnections.userId, c.get('user').id));
  return c.json({ items: rows });
});

app.put('/connection', async (c) => {
  const body = await parseBody(c, z.object({
    platform: z.enum(PLATFORMS),
    isEnabled: z.boolean().default(true),
    grantedScopes: z.array(z.string()).default([]),
  }));
  const db = c.get('db');
  const user = c.get('user');
  const now = Date.now();

  await db.insert(healthConnections).values({
    id: newId(),
    userId: user.id,
    platform: body.platform,
    isEnabled: body.isEnabled,
    grantedScopes: JSON.stringify(body.grantedScopes),
    createdAt: now,
    updatedAt: now,
  }).onConflictDoUpdate({
    target: [healthConnections.userId, healthConnections.platform],
    set: {
      isEnabled: body.isEnabled,
      grantedScopes: JSON.stringify(body.grantedScopes),
      updatedAt: now,
    },
  });

  const rows = await db.select().from(healthConnections).where(and(
    eq(healthConnections.userId, user.id),
    eq(healthConnections.platform, body.platform),
  )).limit(1);
  return c.json(rows[0]);
});

app.get('/cursors', async (c) => {
  const rows = await c.get('db').select().from(healthSyncCursors)
    .where(eq(healthSyncCursors.userId, c.get('user').id));
  return c.json({ items: rows });
});

const syncSchema = z.object({
  platform: z.enum(PLATFORMS),
  workouts: z.array(z.object({
    externalId: z.string(),
    activityTypeId: z.number().int().positive(),
    startedAt: z.number().int().positive(),
    endedAt: z.number().int().positive(),
    distanceM: z.number().nonnegative().nullish(),
    avgHeartRate: z.number().int().nullish(),
    maxHeartRate: z.number().int().nullish(),
    caloriesBurnedKcal: z.number().nonnegative().nullish(),
    elevationGainM: z.number().nullish(),
  })).default([]),
  sleep: z.array(z.object({
    externalId: z.string(),
    startedAt: z.number().int().positive(),
    endedAt: z.number().int().positive(),
    totalSleepSeconds: z.number().int().nonnegative(),
    awakeSeconds: z.number().int().nonnegative().default(0),
    lightSeconds: z.number().int().nonnegative().default(0),
    deepSeconds: z.number().int().nonnegative().default(0),
    remSeconds: z.number().int().nonnegative().default(0),
    avgHeartRate: z.number().int().nullish(),
  })).default([]),
  bodyMetrics: z.array(z.object({
    recordedAt: z.number().int().positive(),
    weightKg: z.number().positive().nullish(),
    heightCm: z.number().positive().nullish(),
    bodyFatPercent: z.number().nonnegative().nullish(),
    muscleMassKg: z.number().nonnegative().nullish(),
  })).default([]),
  dailyActivity: z.array(z.object({
    localDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
    steps: z.number().int().nonnegative().nullish(),
    activeCaloriesKcal: z.number().nonnegative().nullish(),
    restingCaloriesKcal: z.number().nonnegative().nullish(),
    exerciseMinutes: z.number().int().nonnegative().nullish(),
    avgRestingHr: z.number().int().nullish(),
  })).default([]),
});

/** Batch upload. Dedup is by (source, external_id); cursors advance per data type. */
app.post('/sync', async (c) => {
  const body = await parseBody(c, syncSchema);
  const db = c.get('db');
  const user = c.get('user');
  const now = Date.now();
  const touchedDays = new Set<string>();
  const touchedSleepDays = new Set<string>();

  for (const w of body.workouts) {
    const day = localDate(w.startedAt, user.timezone);
    touchedDays.add(day);
    await db.insert(workoutSessions).values({
      id: newId(),
      userId: user.id,
      activityTypeId: w.activityTypeId,
      source: 'health_sync',
      externalId: w.externalId,
      startedAt: w.startedAt,
      endedAt: w.endedAt,
      localDate: day,
      durationSeconds: Math.round((w.endedAt - w.startedAt) / 1000),
      distanceM: w.distanceM ?? null,
      avgHeartRate: w.avgHeartRate ?? null,
      maxHeartRate: w.maxHeartRate ?? null,
      elevationGainM: w.elevationGainM ?? null,
      caloriesBurnedKcal: w.caloriesBurnedKcal ?? null,
      // Straight from the wearable, so not an estimate.
      caloriesAreEstimated: w.caloriesBurnedKcal == null,
      createdAt: now,
      updatedAt: now,
    }).onConflictDoNothing();
  }

  for (const s of body.sleep) {
    const day = localDate(s.endedAt, user.timezone);
    touchedSleepDays.add(day);
    const inBed = Math.round((s.endedAt - s.startedAt) / 1000);
    await db.insert(sleepSessions).values({
      id: newId(),
      userId: user.id,
      source: 'health_sync',
      externalId: s.externalId,
      startedAt: s.startedAt,
      endedAt: s.endedAt,
      localDate: day,
      inBedSeconds: inBed,
      totalSleepSeconds: s.totalSleepSeconds,
      awakeSeconds: s.awakeSeconds,
      lightSeconds: s.lightSeconds,
      deepSeconds: s.deepSeconds,
      remSeconds: s.remSeconds,
      sleepEfficiency: inBed > 0 ? Math.round((s.totalSleepSeconds / inBed) * 1000) / 1000 : null,
      avgHeartRate: s.avgHeartRate ?? null,
      stagesAreEstimated: false,
      createdAt: now,
      updatedAt: now,
    }).onConflictDoNothing();
  }

  if (body.bodyMetrics.length > 0) {
    await insertMany(
      (chunk) => db.insert(bodyMetricsLogs).values(chunk),
      body.bodyMetrics.map((m) => ({
        userId: user.id,
        recordedAt: m.recordedAt,
        localDate: localDate(m.recordedAt, user.timezone),
        weightKg: m.weightKg ?? null,
        heightCm: m.heightCm ?? null,
        bodyFatPercent: m.bodyFatPercent ?? null,
        muscleMassKg: m.muscleMassKg ?? null,
        source: 'health_sync' as const,
        createdAt: now,
      })),
    );
  }

  for (const d of body.dailyActivity) {
    await db.insert(dailyActivitySummaries).values({
      userId: user.id,
      localDate: d.localDate,
      steps: d.steps ?? null,
      activeCaloriesKcal: d.activeCaloriesKcal ?? null,
      restingCaloriesKcal: d.restingCaloriesKcal ?? null,
      exerciseMinutes: d.exerciseMinutes ?? null,
      avgRestingHr: d.avgRestingHr ?? null,
      isEstimated: false,
      source: body.platform,
      createdAt: now,
      updatedAt: now,
    }).onConflictDoUpdate({
      target: [dailyActivitySummaries.userId, dailyActivitySummaries.localDate],
      set: {
        steps: d.steps ?? null,
        activeCaloriesKcal: d.activeCaloriesKcal ?? null,
        restingCaloriesKcal: d.restingCaloriesKcal ?? null,
        exerciseMinutes: d.exerciseMinutes ?? null,
        avgRestingHr: d.avgRestingHr ?? null,
        isEstimated: false,
        source: body.platform,
        updatedAt: now,
      },
    });
  }

  const cursors: Array<[string, number]> = [
    ['workouts', Math.max(0, ...body.workouts.map((w) => w.endedAt))],
    ['sleep', Math.max(0, ...body.sleep.map((s) => s.endedAt))],
    ['body_mass', Math.max(0, ...body.bodyMetrics.map((m) => m.recordedAt))],
  ];
  for (const [dataType, high] of cursors) {
    if (high <= 0) continue;
    await db.insert(healthSyncCursors).values({
      userId: user.id, dataType, lastRecordAt: high, updatedAt: now,
    }).onConflictDoUpdate({
      target: [healthSyncCursors.userId, healthSyncCursors.dataType],
      // Never move a watermark backwards on an out-of-order batch.
      set: { lastRecordAt: sql`max(${healthSyncCursors.lastRecordAt}, ${high})`, updatedAt: now },
    });
  }

  await db.update(healthConnections).set({ lastSyncedAt: now, updatedAt: now })
    .where(and(
      eq(healthConnections.userId, user.id),
      eq(healthConnections.platform, body.platform),
    ));

  for (const day of touchedDays) {
    await recomputeDailyNutritionSummary(db, c.env, user.id, day);
  }
  for (const day of touchedSleepDays) {
    await recomputeSleepDebt(db, c.env, user.id, day);
  }

  return c.json({
    workouts: body.workouts.length,
    sleep: body.sleep.length,
    bodyMetrics: body.bodyMetrics.length,
    dailyActivity: body.dailyActivity.length,
  });
});

export default app;
