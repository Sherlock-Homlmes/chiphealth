import { Hono, type Context } from 'hono';
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

  // The route polyline rides along so the feed can draw a map per card without
  // one detail request each.
  const rows = await c.get('db')
    .select({ session: workoutSessions, polyline: workoutStreams.encodedPolyline })
    .from(workoutSessions)
    .leftJoin(workoutStreams, eq(workoutStreams.workoutSessionId, workoutSessions.id))
    .where(and(...filters)).orderBy(desc(workoutSessions.id)).limit(q.limit + 1);
  return c.json(page(rows.map((r) => ({ ...r.session, polyline: r.polyline ?? null })), q.limit));
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
    'activityTypeId', 'title', 'endedAt', 'durationSeconds', 'movingSeconds', 'distanceM', 'avgHeartRate',
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
 * Derives everything queryable from a raw sample stream and writes it back:
 * the stream row (polyline, downsampled series), splits, time-in-zone, the
 * session totals and PRs. Shared by the upload and by crop, which re-runs it
 * on the trimmed samples.
 */
async function applyStream(
  db: AppEnv['Variables']['db'],
  userId: string,
  session: typeof workoutSessions.$inferSelect,
  assetId: string,
  text: string,
  sampleIntervalS?: number | null,
) {
  const derivation = deriveFromSamples(normaliseSamples(parseSampleStream(text)));
  const zoneSet = await zoneSetEffectiveAt(db, userId, session.startedAt)
    ?? await insertZoneSet(db, userId, session.startedAt);

  const now = Date.now();
  await db.update(mediaAssets).set({ isOrphan: false }).where(eq(mediaAssets.id, assetId));

  await db.insert(workoutStreams).values({
    workoutSessionId: session.id,
    r2AssetId: assetId,
    sampleCount: derivation.sampleCount,
    sampleIntervalS: sampleIntervalS ?? derivation.sampleIntervalS,
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
      r2AssetId: assetId,
      sampleCount: derivation.sampleCount,
      sampleIntervalS: sampleIntervalS ?? derivation.sampleIntervalS,
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

  const records = await detectPersonalRecords(db, userId, session.id);
  return { derivation, zoneTimes, records };
}

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

  const { derivation, zoneTimes, records } = await applyStream(
    db, user.id, session, asset.id, await object.text(), body.sampleIntervalS,
  );

  return c.json({
    sampleCount: derivation.sampleCount,
    splits: derivation.splits.length,
    zones: zoneTimes.length,
    newRecords: records,
  });
});

/** The session's raw stream, or 404 when it was recorded without one. */
async function streamObject(c: Context<AppEnv>, sessionId: string) {
  const rows = await c.get('db')
    .select({ assetId: mediaAssets.id, r2Key: mediaAssets.r2Key })
    .from(workoutStreams)
    .innerJoin(mediaAssets, eq(mediaAssets.id, workoutStreams.r2AssetId))
    .where(eq(workoutStreams.workoutSessionId, sessionId)).limit(1);
  const row = rows[0];
  if (!row) throw notFound('Workout stream');
  const object = await c.env.MEDIA.get(row.r2Key);
  if (!object) throw notFound('Workout stream');
  return { ...row, text: await object.text() };
}

/** Upper bound on points sent for replay/crop; plenty for a smooth line. */
const TRACK_MAX_POINTS = 1500;

/**
 * Timed GPS points (t = seconds from the first sample, d = cumulative metres)
 * for replaying the route and picking crop bounds. The stored polyline has no
 * timestamps, so this reads the raw stream.
 */
app.get('/workouts/:id/track', async (c) => {
  const session = await ownedWorkout(c.get('db'), c.get('user').id, c.req.param('id'));
  const { text } = await streamObject(c, session.id);
  const gps = normaliseSamples(parseSampleStream(text))
    .filter((s) => s.lat !== null && s.lng !== null);
  const stride = Math.max(1, Math.ceil(gps.length / TRACK_MAX_POINTS));
  const points = gps
    .filter((_, i) => i % stride === 0 || i === gps.length - 1)
    .map((s) => ({
      t: Math.round(s.t * 10) / 10,
      lat: s.lat,
      lng: s.lng,
      d: Math.round(s.d),
      ele: s.ele,
      hr: s.hr,
    }));
  return c.json({ items: points });
});

/**
 * Strava-style crop: keeps the samples between `fromS` and `toS` (seconds from
 * the first sample), rewrites the stored stream and re-derives everything from
 * it. Personal records already set by the uncropped version are left alone.
 */
app.post('/workouts/:id/crop', async (c) => {
  const body = await parseBody(c, z.object({
    fromS: z.number().nonnegative(),
    toS: z.number().positive(),
  }).refine((b) => b.toS > b.fromS, 'toS must be after fromS'));
  const db = c.get('db');
  const user = c.get('user');
  const session = await ownedWorkout(db, user.id, c.req.param('id'));
  const stream = await streamObject(c, session.id);

  const raw = parseSampleStream(stream.text)
    .filter((s) => typeof s.t === 'number' && Number.isFinite(s.t))
    .sort((a, b) => a.t - b.t);
  if (raw.length === 0) throw new ApiError('CONFLICT', 'Stream has no samples');
  // Same clock as normaliseSamples: epoch ms when t is huge, else seconds.
  const asEpochMs = raw[0]!.t > 1e11;
  const base = raw[0]!.t;
  const secondsOf = (t: number) => (asEpochMs ? (t - base) / 1000 : t - base);
  const kept = raw.filter((s) => {
    const t = secondsOf(s.t);
    return t >= body.fromS && t <= body.toS;
  });
  if (kept.length < 2) {
    throw new ApiError('VALIDATION_ERROR', 'Crop keeps fewer than two samples');
  }

  const text = kept.map((s) => JSON.stringify(s)).join('\n');
  const written = await c.env.MEDIA.put(stream.r2Key, text, {
    httpMetadata: { contentType: 'application/x-ndjson' },
  });
  await db.update(mediaAssets).set({ byteSize: written?.size ?? text.length })
    .where(eq(mediaAssets.id, stream.assetId));

  const firstS = secondsOf(kept[0]!.t);
  const lastS = secondsOf(kept[kept.length - 1]!.t);
  const startedAt = session.startedAt + Math.round(firstS * 1000);
  const durationSeconds = Math.max(1, Math.round(lastS - firstS));
  // Totals are re-derived below; clear the ones applyStream only fills when blank.
  await db.update(workoutSessions).set({
    startedAt,
    endedAt: startedAt + durationSeconds * 1000,
    durationSeconds,
    distanceM: null,
    movingSeconds: null,
    elevationGainM: null,
    updatedAt: Date.now(),
  }).where(eq(workoutSessions.id, session.id));

  const fresh = await ownedWorkout(db, user.id, session.id);
  await applyStream(db, user.id, fresh, stream.assetId, text);
  // Derived duration counts sample span only; keep the cropped wall-clock span.
  await db.update(workoutSessions).set({ durationSeconds })
    .where(eq(workoutSessions.id, session.id));
  await recomputeDailyNutritionSummary(db, c.env, user.id, session.localDate);

  const rows = await db.select().from(workoutSessions)
    .where(eq(workoutSessions.id, session.id)).limit(1);
  return c.json(rows[0]);
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
