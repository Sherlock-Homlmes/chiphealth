import { Hono } from 'hono';
import { and, asc, desc, eq, gte, lte, sql } from 'drizzle-orm';
import { z } from 'zod';
import {
  workoutSessions, workoutStreams, workoutSplits, workoutStrengthSets,
  workoutZoneSummaries, heartRateZones, personalRecords, mediaAssets, activityTypes,
} from '../db/schema';
import { parseBody, parseQuery, paginationSchema, page, isoDateSchema } from '../lib/http';
import { ApiError, notFound } from '../lib/errors';
import { newId } from '../lib/ids';
import { localDate } from '../lib/time';
import {
  parseSampleStream, normaliseSamples, deriveFromSamples,
  insertZoneSet, zoneSetEffectiveAt, currentZoneSet,
} from '../services/workoutStream';
import { detectPersonalRecords } from '../services/personalRecords';
import { recomputeDailyNutritionSummary } from '../services/nutritionMath';
import { insertMany } from '../db/client';
import type { AppEnv } from '../env';

const app = new Hono<AppEnv>();

const workoutSchema = z.object({
  id: z.string().uuid().optional(),
  activityTypeId: z.number().int().positive(),
  source: z.enum(['in_app', 'health_sync', 'manual_entry']).default('in_app'),
  externalId: z.string().max(200).nullish(),
  title: z.string().max(200).nullish(),
  startedAt: z.number().int().positive(),
  endedAt: z.number().int().positive().nullish(),
  durationSeconds: z.number().int().nonnegative().nullish(),
  movingSeconds: z.number().int().nonnegative().nullish(),
  distanceM: z.number().nonnegative().nullish(),
  avgHeartRate: z.number().int().nullish(),
  maxHeartRate: z.number().int().nullish(),
  elevationGainM: z.number().nullish(),
  caloriesBurnedKcal: z.number().nonnegative().nullish(),
  caloriesAreEstimated: z.boolean().default(true),
  perceivedExertion: z.number().int().min(1).max(10).nullish(),
  notes: z.string().max(1000).nullish(),
});

/** MET x kg x hours — the fallback when no wearable reported energy. */
async function estimateCalories(
  db: AppEnv['Variables']['db'], activityTypeId: number, seconds: number, weightKg: number | null,
): Promise<number | null> {
  if (!weightKg || seconds <= 0) return null;
  const rows = await db.select({ met: activityTypes.defaultMet })
    .from(activityTypes).where(eq(activityTypes.id, activityTypeId)).limit(1);
  const met = rows[0]?.met;
  if (!met) return null;
  return Math.round(met * weightKg * (seconds / 3600));
}

app.post('/workouts', async (c) => {
  const body = await parseBody(c, workoutSchema);
  const user = c.get('user');
  const db = c.get('db');
  const id = body.id ?? newId();
  const now = Date.now();
  const day = localDate(body.startedAt, user.timezone);

  const duration = body.durationSeconds
    ?? (body.endedAt ? Math.round((body.endedAt - body.startedAt) / 1000) : null);

  const values = {
    userId: user.id,
    activityTypeId: body.activityTypeId,
    source: body.source,
    externalId: body.externalId ?? null,
    title: body.title ?? null,
    startedAt: body.startedAt,
    endedAt: body.endedAt ?? null,
    localDate: day,
    durationSeconds: duration,
    movingSeconds: body.movingSeconds ?? null,
    distanceM: body.distanceM ?? null,
    avgHeartRate: body.avgHeartRate ?? null,
    maxHeartRate: body.maxHeartRate ?? null,
    elevationGainM: body.elevationGainM ?? null,
    caloriesBurnedKcal: body.caloriesBurnedKcal ?? null,
    caloriesAreEstimated: body.caloriesBurnedKcal == null ? true : body.caloriesAreEstimated,
    perceivedExertion: body.perceivedExertion ?? null,
    notes: body.notes ?? null,
    updatedAt: now,
  };

  await db.insert(workoutSessions).values({ id, createdAt: now, ...values })
    .onConflictDoUpdate({
      target: workoutSessions.id,
      set: values,
      where: eq(workoutSessions.userId, user.id),
    });

  await recomputeDailyNutritionSummary(db, c.env, user.id, day);

  const rows = await db.select().from(workoutSessions).where(eq(workoutSessions.id, id)).limit(1);
  return c.json(rows[0], 201);
});

app.get('/workouts', async (c) => {
  const q = parseQuery(c, paginationSchema.extend({
    from: isoDateSchema.optional(),
    to: isoDateSchema.optional(),
    activityTypeId: z.coerce.number().int().positive().optional(),
  }));
  const filters = [
    eq(workoutSessions.userId, c.get('user').id),
    eq(workoutSessions.isDeleted, false),
  ];
  if (q.from) filters.push(gte(workoutSessions.localDate, q.from));
  if (q.to) filters.push(lte(workoutSessions.localDate, q.to));
  if (q.activityTypeId) filters.push(eq(workoutSessions.activityTypeId, q.activityTypeId));
  if (q.cursor) filters.push(sql`${workoutSessions.id} < ${q.cursor}`);

  const rows = await c.get('db').select().from(workoutSessions)
    .where(and(...filters)).orderBy(desc(workoutSessions.id)).limit(q.limit + 1);
  return c.json(page(rows, q.limit));
});

async function ownedWorkout(db: AppEnv['Variables']['db'], userId: string, id: string) {
  const rows = await db.select().from(workoutSessions)
    .where(and(eq(workoutSessions.id, id), eq(workoutSessions.userId, userId))).limit(1);
  const session = rows[0];
  if (!session) throw notFound('Workout');
  return session;
}

app.get('/workouts/:id', async (c) => {
  const db = c.get('db');
  const session = await ownedWorkout(db, c.get('user').id, c.req.param('id'));

  const [stream, splits, zones, sets] = await Promise.all([
    db.select().from(workoutStreams)
      .where(eq(workoutStreams.workoutSessionId, session.id)).limit(1),
    db.select().from(workoutSplits)
      .where(eq(workoutSplits.workoutSessionId, session.id))
      .orderBy(asc(workoutSplits.splitIndex)),
    db.select().from(workoutZoneSummaries)
      .where(eq(workoutZoneSummaries.workoutSessionId, session.id))
      .orderBy(asc(workoutZoneSummaries.zoneNumber)),
    db.select().from(workoutStrengthSets)
      .where(eq(workoutStrengthSets.workoutSessionId, session.id))
      .orderBy(asc(workoutStrengthSets.exerciseId), asc(workoutStrengthSets.setIndex)),
  ]);

  return c.json({ ...session, stream: stream[0] ?? null, splits, zones, sets });
});

app.patch('/workouts/:id', async (c) => {
  const body = await parseBody(c, workoutSchema.partial().extend({
    isDeleted: z.boolean().optional(),
  }));
  const db = c.get('db');
  const user = c.get('user');
  const session = await ownedWorkout(db, user.id, c.req.param('id'));

  const patch: Record<string, unknown> = { updatedAt: Date.now() };
  for (const key of [
    'title', 'endedAt', 'durationSeconds', 'movingSeconds', 'distanceM', 'avgHeartRate',
    'maxHeartRate', 'elevationGainM', 'caloriesBurnedKcal', 'perceivedExertion', 'notes',
    'isDeleted',
  ] as const) {
    if (body[key as keyof typeof body] !== undefined) patch[key] = body[key as keyof typeof body];
  }

  await db.update(workoutSessions).set(patch).where(eq(workoutSessions.id, session.id));
  await recomputeDailyNutritionSummary(db, c.env, user.id, session.localDate);

  const rows = await db.select().from(workoutSessions)
    .where(eq(workoutSessions.id, session.id)).limit(1);
  return c.json(rows[0]);
});

/**
 * The heart of the D1-friendly design: the client uploads raw samples to R2, and
 * this derives everything queryable (polyline, splits, time-in-zone, PRs) so no
 * per-point rows ever land in the database.
 */
app.put('/workouts/:id/stream', async (c) => {
  const body = await parseBody(c, z.object({
    assetId: z.string().uuid(),
    sampleIntervalS: z.number().positive().nullish(),
  }));
  const db = c.get('db');
  const user = c.get('user');
  const session = await ownedWorkout(db, user.id, c.req.param('id'));

  const assetRows = await db.select().from(mediaAssets)
    .where(and(eq(mediaAssets.id, body.assetId), eq(mediaAssets.userId, user.id))).limit(1);
  const asset = assetRows[0];
  if (!asset) throw notFound('Stream asset');

  const object = await c.env.MEDIA.get(asset.r2Key);
  if (!object) throw new ApiError('CONFLICT', 'Stream object has not been uploaded yet');

  const derivation = deriveFromSamples(normaliseSamples(parseSampleStream(await object.text())));
  const zoneSet = await zoneSetEffectiveAt(db, user.id, session.startedAt)
    ?? await insertZoneSet(db, user.id, session.startedAt);

  const now = Date.now();
  await db.update(mediaAssets).set({ isOrphan: false }).where(eq(mediaAssets.id, asset.id));

  await db.insert(workoutStreams).values({
    workoutSessionId: session.id,
    r2AssetId: asset.id,
    sampleCount: derivation.sampleCount,
    sampleIntervalS: body.sampleIntervalS ?? derivation.sampleIntervalS,
    encodedPolyline: derivation.encodedPolyline,
    downsampledJson: JSON.stringify(derivation.downsampled),
    startLatitude: derivation.startLatitude,
    startLongitude: derivation.startLongitude,
    boundsJson: derivation.bounds ? JSON.stringify(derivation.bounds) : null,
    hasGps: derivation.hasGps,
    hasHeartRate: derivation.hasHeartRate,
    createdAt: now,
  }).onConflictDoUpdate({
    target: workoutStreams.workoutSessionId,
    set: {
      r2AssetId: asset.id,
      sampleCount: derivation.sampleCount,
      sampleIntervalS: body.sampleIntervalS ?? derivation.sampleIntervalS,
      encodedPolyline: derivation.encodedPolyline,
      downsampledJson: JSON.stringify(derivation.downsampled),
      startLatitude: derivation.startLatitude,
      startLongitude: derivation.startLongitude,
      boundsJson: derivation.bounds ? JSON.stringify(derivation.bounds) : null,
      hasGps: derivation.hasGps,
      hasHeartRate: derivation.hasHeartRate,
    },
  });

  await db.delete(workoutSplits).where(eq(workoutSplits.workoutSessionId, session.id));
  if (derivation.splits.length > 0) {
    await insertMany(
      (chunk) => db.insert(workoutSplits).values(chunk),
      derivation.splits.map((s) => ({
        workoutSessionId: session.id,
        splitIndex: s.splitIndex,
        splitDistanceM: s.splitDistanceM,
        elapsedSeconds: s.elapsedSeconds,
        movingSeconds: s.movingSeconds,
        avgHeartRate: s.avgHeartRate,
        elevationGainM: s.elevationGainM,
        avgPaceSecPerKm: s.avgPaceSecPerKm,
      })),
    );
  }

  await db.delete(workoutZoneSummaries)
    .where(eq(workoutZoneSummaries.workoutSessionId, session.id));
  const zoneTimes = derivation.hasHeartRate
    ? computeZoneTimes(derivation.downsampled, zoneSet.zones, derivation.totals.durationSeconds)
    : [];
  if (zoneTimes.length > 0) {
    await insertMany(
      (chunk) => db.insert(workoutZoneSummaries).values(chunk),
      zoneTimes.map((z) => ({
        workoutSessionId: session.id,
        zoneNumber: z.zoneNumber,
        secondsInZone: z.seconds,
        percentOfSession: z.percent,
      })),
    );
  }

  const totals = derivation.totals;
  await db.update(workoutSessions).set({
    distanceM: totals.distanceM || session.distanceM,
    durationSeconds: totals.durationSeconds || session.durationSeconds,
    movingSeconds: totals.movingSeconds || session.movingSeconds,
    avgHeartRate: totals.avgHeartRate ?? session.avgHeartRate,
    maxHeartRate: totals.maxHeartRate ?? session.maxHeartRate,
    avgPaceSecPerKm: totals.avgPaceSecPerKm,
    bestPaceSecPerKm: totals.bestPaceSecPerKm,
    elevationGainM: totals.elevationGainM || session.elevationGainM,
    updatedAt: now,
  }).where(eq(workoutSessions.id, session.id));

  const records = await detectPersonalRecords(db, user.id, session.id);

  return c.json({
    sampleCount: derivation.sampleCount,
    splits: derivation.splits.length,
    zones: zoneTimes.length,
    newRecords: records,
  });
});

/** Time-in-zone from the downsampled series; exact enough for a 5-bucket chart. */
function computeZoneTimes(
  points: Array<{ t: number; hr: number | null }>,
  zones: Array<{ zoneNumber: number; minBpm: number; maxBpm: number }>,
  durationSeconds: number,
): Array<{ zoneNumber: number; seconds: number; percent: number }> {
  if (points.length < 2) return [];
  const totals = new Map<number, number>();

  for (let i = 1; i < points.length; i++) {
    const prev = points[i - 1]!;
    const cur = points[i]!;
    const hr = cur.hr ?? prev.hr;
    if (hr == null) continue;
    const dt = Math.max(0, cur.t - prev.t);
    const zone = zones.find((z) => hr >= z.minBpm && hr <= z.maxBpm);
    if (!zone) continue;
    totals.set(zone.zoneNumber, (totals.get(zone.zoneNumber) ?? 0) + dt);
  }

  const denominator = durationSeconds > 0 ? durationSeconds : 1;
  return [...totals.entries()]
    .map(([zoneNumber, seconds]) => ({
      zoneNumber,
      seconds: Math.round(seconds),
      percent: Math.round((seconds / denominator) * 1000) / 10,
    }))
    .sort((a, b) => a.zoneNumber - b.zoneNumber);
}

// ------------------------------------------------------------- strength

const setsSchema = z.object({
  sets: z.array(z.object({
    exerciseId: z.number().int().positive(),
    setIndex: z.number().int().positive(),
    reps: z.number().int().nonnegative().nullish(),
    weightKg: z.number().nonnegative().nullish(),
    durationSeconds: z.number().int().nonnegative().nullish(),
    distanceM: z.number().nonnegative().nullish(),
    rpe: z.number().min(1).max(10).nullish(),
    isWarmup: z.boolean().default(false),
    restSeconds: z.number().int().nonnegative().nullish(),
  })),
});

/** Bulk replace: the app edits the whole session table at once. */
app.put('/workouts/:id/sets', async (c) => {
  const body = await parseBody(c, setsSchema);
  const db = c.get('db');
  const user = c.get('user');
  const session = await ownedWorkout(db, user.id, c.req.param('id'));

  await db.delete(workoutStrengthSets)
    .where(eq(workoutStrengthSets.workoutSessionId, session.id));
  if (body.sets.length > 0) {
    await insertMany(
      (chunk) => db.insert(workoutStrengthSets).values(chunk),
      body.sets.map((s) => ({
        workoutSessionId: session.id,
        exerciseId: s.exerciseId,
        setIndex: s.setIndex,
        reps: s.reps ?? null,
        weightKg: s.weightKg ?? null,
        durationSeconds: s.durationSeconds ?? null,
        distanceM: s.distanceM ?? null,
        rpe: s.rpe ?? null,
        isWarmup: s.isWarmup,
        restSeconds: s.restSeconds ?? null,
        createdAt: Date.now(),
      })),
    );
  }

  const records = await detectPersonalRecords(db, user.id, session.id);
  return c.json({ sets: body.sets.length, newRecords: records });
});

// ---------------------------------------------------------------- zones

app.get('/training/zones', async (c) => {
  const zoneSet = await currentZoneSet(c.get('db'), c.get('user').id);
  return c.json(zoneSet);
});

app.post('/training/zones/recalculate', async (c) => {
  const zoneSet = await insertZoneSet(c.get('db'), c.get('user').id);
  return c.json(zoneSet, 201);
});

// -------------------------------------------------------------- records

app.get('/training/records', async (c) => {
  const rows = await c.get('db').select().from(personalRecords).where(and(
    eq(personalRecords.userId, c.get('user').id),
    eq(personalRecords.isCurrent, true),
  )).orderBy(desc(personalRecords.achievedAt));
  return c.json({ items: rows });
});

app.get('/training/records/:metric/history', async (c) => {
  const metric = c.req.param('metric');
  const rows = await c.get('db').select().from(personalRecords).where(and(
    eq(personalRecords.userId, c.get('user').id),
    eq(personalRecords.metric, metric as 'max_weight'),
  )).orderBy(asc(personalRecords.achievedAt));
  return c.json({ items: rows });
});

export default app;
