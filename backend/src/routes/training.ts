import { Hono, type Context } from 'hono';
import { and, asc, desc, eq, gte, inArray, lte, or, sql } from 'drizzle-orm';
import { z } from 'zod';
import {
  workoutSessions, workoutStreams, workoutSplits, workoutStrengthSets,
  workoutZoneSummaries, heartRateZones, personalRecords, mediaAssets, activityTypes,
  workoutPhotos, userProfiles, workoutBestEfforts, racePredictions,
} from '../db/schema';
import { parseBody, parseQuery, paginationSchema, page, isoDateSchema } from '../lib/http';
import { ApiError, notFound } from '../lib/errors';
import { newId } from '../lib/ids';
import { localDate, addDays } from '../lib/time';
import {
  parseSampleStream, normaliseSamples, deriveFromSamples,
  insertZoneSet, zoneSetEffectiveAt, currentZoneSet,
} from '../services/workoutStream';
import { detectPersonalRecords, dropRecordsForSession } from '../services/personalRecords';
import {
  effortCounters, gradeAdjustedPace, paceZoneRanges, persistRunAnalysis,
} from '../services/runAnalysis';
import { loadTdeeInputs, recomputeDailyNutritionSummary } from '../services/nutritionMath';
import { insertMany } from '../db/client';
import {
  ALL_SPORTS, sportOf, matchesSport, sportChips, weekSeries, streakWeeks, weekLog,
  predictionSeries, zoneBreakdown, monthOf, previousMonth, monthSeries, suggestWorkout,
  type ProgressSession,
} from '../services/trainingProgress';
import {
  distanceText, durationText, isInsightKind, paceText, workoutInsight,
} from '../services/workoutInsight';
import { accountLocale } from '../lib/language';
import type { AppEnv } from '../env';

const app = new Hono<AppEnv>();

/** Strava-style photo ceiling; the schema enforces it on every write path. */
export const MAX_WORKOUT_PHOTOS = 5;

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
  /** Steps per minute. The only thing the step count on the detail screen has. */
  avgCadence: z.number().int().positive().max(300).nullish(),
  elevationGainM: z.number().nullish(),
  caloriesBurnedKcal: z.number().nonnegative().nullish(),
  caloriesAreEstimated: z.boolean().default(true),
  perceivedExertion: z.number().int().min(1).max(10).nullish(),
  notes: z.string().max(1000).nullish(),
  photoAssetIds: z.array(z.string().uuid()).max(MAX_WORKOUT_PHOTOS).optional(),
});

/** Used when nobody has logged a weight yet, so a workout still counts. */
const FALLBACK_WEIGHT_KG = 65;

/**
 * Recreational average speed (m/s) per sport, for when only a distance was
 * typed ("bơi 300 m"): distance / speed gives the time the MET formula needs.
 */
const TYPICAL_SPEED_MS: Record<string, number> = {
  running: 2.8, trail_running: 2.2, treadmill: 2.8,
  walking: 1.4, hiking: 1.1, trekking: 1.0,
  cycling: 5.5, mountain_biking: 4.2, indoor_cycling: 7, spinning: 7,
  swimming: 0.6, open_water_swimming: 0.55,
  rowing: 2.5, kayaking: 1.5, skiing: 5, snowboarding: 5,
};

interface CalorieEstimate {
  kcal: number | null;
  met: number | null;
  weightKg: number;
  weightIsFallback: boolean;
  /** The time the estimate used — typed, or derived from the distance. */
  seconds: number | null;
  secondsFromDistance: boolean;
}

/** MET (activity_types) x latest weight (body_metrics_logs) x hours. */
async function estimateCalorieDetail(
  db: AppEnv['Variables']['db'], userId: string, activityTypeId: number,
  seconds: number | null | undefined, distanceM?: number | null,
): Promise<CalorieEstimate> {
  const [typeRows, inputs] = await Promise.all([
    db.select({ met: activityTypes.defaultMet, code: activityTypes.code })
      .from(activityTypes).where(eq(activityTypes.id, activityTypeId)).limit(1),
    loadTdeeInputs(db, userId),
  ]);
  const met = typeRows[0]?.met ?? null;
  const speed = TYPICAL_SPEED_MS[typeRows[0]?.code ?? ''];
  const weightKg = inputs.weightKg ?? FALLBACK_WEIGHT_KG;

  let time = seconds && seconds > 0 ? seconds : null;
  let fromDistance = false;
  if (!time && distanceM && distanceM > 0 && speed) {
    time = Math.round(distanceM / speed);
    fromDistance = true;
  }
  return {
    kcal: met && time ? Math.round(met * weightKg * (time / 3600)) : null,
    met,
    weightKg,
    weightIsFallback: inputs.weightKg == null,
    seconds: time,
    secondsFromDistance: fromDistance,
  };
}

async function estimateCalories(
  db: AppEnv['Variables']['db'], userId: string, activityTypeId: number,
  seconds: number | null | undefined, distanceM?: number | null,
): Promise<number | null> {
  return (await estimateCalorieDetail(db, userId, activityTypeId, seconds, distanceM)).kcal;
}

/** Live preview for the manual-entry form; the same maths POST applies. */
app.get('/workouts/estimate', async (c) => {
  const q = parseQuery(c, z.object({
    activityTypeId: z.coerce.number().int().positive(),
    durationSeconds: z.coerce.number().int().nonnegative().optional(),
    distanceM: z.coerce.number().nonnegative().optional(),
  }));
  return c.json(await estimateCalorieDetail(
    c.get('db'), c.get('user').id, q.activityTypeId, q.durationSeconds, q.distanceM,
  ));
});

/**
 * Re-derives an estimated session's calories after its sport or duration
 * changed. A figure the user typed (or a wearable reported) is left alone.
 */
async function refreshEstimatedCalories(db: AppEnv['Variables']['db'], userId: string, id: string) {
  const rows = await db.select().from(workoutSessions).where(eq(workoutSessions.id, id)).limit(1);
  const s = rows[0];
  if (!s || (!s.caloriesAreEstimated && s.caloriesBurnedKcal != null)) return;
  const kcal = await estimateCalories(
    db, userId, s.activityTypeId, s.movingSeconds || s.durationSeconds, s.distanceM,
  );
  await db.update(workoutSessions)
    .set({ caloriesBurnedKcal: kcal, caloriesAreEstimated: true })
    .where(eq(workoutSessions.id, id));
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
    avgCadence: body.avgCadence ?? null,
    elevationGainM: body.elevationGainM ?? null,
    caloriesBurnedKcal: body.caloriesBurnedKcal
      ?? await estimateCalories(db, user.id, body.activityTypeId, body.movingSeconds || duration, body.distanceM),
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

  if (body.photoAssetIds) await setWorkoutPhotos(db, user.id, id, body.photoAssetIds);

  await recomputeDailyNutritionSummary(db, c.env, user.id, day);

  const rows = await db.select().from(workoutSessions).where(eq(workoutSessions.id, id)).limit(1);
  const photos = await photosBySession(db, [id]);
  return c.json({ ...rows[0], photoAssetIds: photos.get(id) ?? [] }, 201);
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
  const paged = page(rows.map((r) => ({ ...r.session, polyline: r.polyline ?? null })), q.limit);
  // Thumbnails for the cards: one query for the page, not one per session.
  const photos = await photosBySession(c.get('db'), paged.items.map((s) => s.id));
  return c.json({
    ...paged,
    items: paged.items.map((s) => ({ ...s, photoAssetIds: photos.get(s.id) ?? [] })),
  });
});

async function ownedWorkout(db: AppEnv['Variables']['db'], userId: string, id: string) {
  const rows = await db.select().from(workoutSessions)
    .where(and(eq(workoutSessions.id, id), eq(workoutSessions.userId, userId))).limit(1);
  const session = rows[0];
  if (!session) throw notFound('Workout');
  return session;
}

/**
 * Full-replace, same semantics as PUT /sets: the client sends the ordered list
 * it wants. New ids must be the caller's own `workout_photo` assets; ids that
 * drop out are only unlinked — the asset row flips back to orphan and the
 * sweeper reclaims the object, unless another session still points at it.
 */
async function setWorkoutPhotos(
  db: AppEnv['Variables']['db'], userId: string, sessionId: string, ids: string[],
) {
  const unique = [...new Set(ids)];
  const previous = (await db.select({ assetId: workoutPhotos.assetId })
    .from(workoutPhotos).where(eq(workoutPhotos.workoutSessionId, sessionId)))
    .map((r) => r.assetId);
  const added = unique.filter((id) => !previous.includes(id));

  if (added.length > 0) {
    const assets = await db.select().from(mediaAssets)
      .where(and(inArray(mediaAssets.id, added), eq(mediaAssets.userId, userId)));
    if (assets.length !== added.length) throw notFound('Photo asset');
    // Workout photos are uploaded as kind 'meal_photo': media_assets' kind
    // CHECK cannot be widened on D1 (see 0008_coach_photo.sql), and that kind
    // already gives exactly the rules needed — images only, owner-only reads.
    if (assets.some((a) => a.kind !== 'meal_photo')) {
      throw new ApiError('VALIDATION_ERROR', 'Only photo assets can be attached');
    }
  }

  await db.delete(workoutPhotos).where(eq(workoutPhotos.workoutSessionId, sessionId));
  if (unique.length > 0) {
    await insertMany(
      (chunk) => db.insert(workoutPhotos).values(chunk),
      unique.map((assetId, sortOrder) => ({
        workoutSessionId: sessionId,
        assetId,
        sortOrder,
        createdAt: Date.now(),
      })),
    );
    await db.update(mediaAssets).set({ isOrphan: false })
      .where(inArray(mediaAssets.id, unique));
  }

  // Only now, with this session's links gone, does "still referenced" mean
  // referenced by *another* session — those keep their object.
  const removed = previous.filter((id) => !unique.includes(id));
  if (removed.length > 0) {
    const stillLinked = (await db.select({ assetId: workoutPhotos.assetId })
      .from(workoutPhotos).where(inArray(workoutPhotos.assetId, removed)))
      .map((r) => r.assetId);
    const orphans = removed.filter((id) => !stillLinked.includes(id));
    if (orphans.length > 0) {
      await db.update(mediaAssets).set({ isOrphan: true })
        .where(inArray(mediaAssets.id, orphans));
    }
  }
}

/** photoAssetIds per session, in sort order — one query for the whole page. */
async function photosBySession(
  db: AppEnv['Variables']['db'], sessionIds: string[],
): Promise<Map<string, string[]>> {
  if (sessionIds.length === 0) return new Map();
  const rows = await db.select({
    sessionId: workoutPhotos.workoutSessionId,
    assetId: workoutPhotos.assetId,
  }).from(workoutPhotos)
    .where(inArray(workoutPhotos.workoutSessionId, sessionIds))
    .orderBy(asc(workoutPhotos.sortOrder), asc(workoutPhotos.assetId));

  const map = new Map<string, string[]>();
  for (const row of rows) {
    const list = map.get(row.sessionId) ?? [];
    list.push(row.assetId);
    map.set(row.sessionId, list);
  }
  return map;
}

app.get('/workouts/:id', async (c) => {
  const db = c.get('db');
  const userId = c.get('user').id;
  const session = await ownedWorkout(db, userId, c.req.param('id'));

  const [stream, splits, zones, sets, photos, efforts, predictions] = await Promise.all([
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
    photosBySession(db, [session.id]),
    db.select().from(workoutBestEfforts)
      .where(eq(workoutBestEfforts.workoutSessionId, session.id))
      .orderBy(asc(workoutBestEfforts.distanceM)),
    // The board as it stands, plus whatever this run moved — the screen needs
    // both: the standing 5 km time captions the pace zones, and the rows this
    // session wrote are what the "prediction improved" card is about.
    db.select().from(racePredictions).where(and(
      eq(racePredictions.userId, userId),
      eq(racePredictions.activityTypeId, session.activityTypeId),
      or(
        eq(racePredictions.isCurrent, true),
        eq(racePredictions.workoutSessionId, session.id),
      ),
    )),
  ]);

  const currentPredictions = predictions.filter((p) => p.isCurrent);
  const fiveK = currentPredictions.find((p) => p.distanceM === 5000)?.predictedSeconds ?? null;

  return c.json({
    ...session,
    stream: stream[0] ?? null,
    splits,
    zones: zones.filter((z) => z.kind === 'hr'),
    paceZones: zones.filter((z) => z.kind === 'pace'),
    // Recomputed rather than stored: the ranges are a pure function of the
    // 5 km prediction, and the screen prints them next to the times.
    paceZoneRanges: fiveK === null ? [] : paceZoneRanges(fiveK),
    paceZoneBasisSeconds: fiveK,
    sets,
    photoAssetIds: photos.get(session.id) ?? [],
    bestEfforts: efforts,
    effortCounters: effortCounters(efforts),
    predictions: currentPredictions.map((p) => ({
      distanceM: p.distanceM,
      seconds: Math.round(p.predictedSeconds),
    })),
    predictionImproved: predictions
      .filter((p) => p.workoutSessionId === session.id && p.previousSeconds !== null)
      .map((p) => ({
        distanceM: p.distanceM,
        seconds: Math.round(p.predictedSeconds),
        improvedBySeconds: Math.round(p.previousSeconds! - p.predictedSeconds),
      }))
      .filter((p) => p.improvedBySeconds > 0)
      .sort((a, b) => b.improvedBySeconds - a.improvedBySeconds),
  });
});

/**
 * Athlete Intelligence: one coached sentence about the run, in the athlete's
 * language. Its own endpoint rather than a field on the detail response
 * because it is the one part of the screen that waits on a model — the sheet
 * renders its numbers immediately and each card fills in when its line lands,
 * or stays hidden when it does not.
 */
app.get('/workouts/:id/insight/:kind', async (c) => {
  const kind = c.req.param('kind');
  if (!isInsightKind(kind)) {
    throw new ApiError('VALIDATION_ERROR', `Unknown insight kind: ${kind}`);
  }
  const db = c.get('db');
  const user = c.get('user');
  const session = await ownedWorkout(db, user.id, c.req.param('id'));

  const [splits, efforts, zones, predictions] = await Promise.all([
    db.select().from(workoutSplits)
      .where(eq(workoutSplits.workoutSessionId, session.id))
      .orderBy(asc(workoutSplits.splitIndex)),
    db.select().from(workoutBestEfforts)
      .where(eq(workoutBestEfforts.workoutSessionId, session.id))
      .orderBy(asc(workoutBestEfforts.distanceM)),
    db.select().from(workoutZoneSummaries).where(and(
      eq(workoutZoneSummaries.workoutSessionId, session.id),
      eq(workoutZoneSummaries.kind, 'pace'),
    )).orderBy(asc(workoutZoneSummaries.zoneNumber)),
    db.select().from(racePredictions).where(and(
      eq(racePredictions.userId, user.id),
      eq(racePredictions.activityTypeId, session.activityTypeId),
      eq(racePredictions.isCurrent, true),
    )),
  ]);

  // Only what the sentence is allowed to talk about, and in the units a reader
  // uses: a model handed the whole session row invents a narrative out of the
  // fields it recognises, and one handed raw seconds spends its answer working
  // out what they mean.
  const shared = {
    quang_duong: distanceText(session.distanceM),
    thoi_gian_di_chuyen: durationText(session.movingSeconds),
    nhip_do_tb: paceText(session.avgPaceSecPerKm),
  };
  const data = kind === 'overview'
    ? {
      ...shared,
      do_cao_tang: session.elevationGainM === null ? null : `${Math.round(session.elevationGainM)} m`,
      nhip_do_dieu_chinh_doc: paceText(session.gapSecPerKm),
      thanh_tich: efforts.map((e) => ({
        cu_ly: distanceText(e.distanceM),
        thoi_gian: durationText(e.elapsedSeconds),
        hang: e.rank,
      })),
      du_doan: predictions.map((p) => ({
        cu_ly: distanceText(p.distanceM),
        thoi_gian: durationText(p.predictedSeconds),
      })),
    }
    : kind === 'pace'
      ? (() => {
        // The shape of the run rather than the whole split table: handed all
        // eleven kilometres the model narrates each one in its scratchpad and
        // runs out of budget before it writes a sentence.
        const paces = splits
          .map((sp) => sp.avgPaceSecPerKm)
          .filter((p): p is number => p !== null);
        return {
          ...shared,
          thoi_gian_thuc_te: durationText(session.durationSeconds),
          so_chang: splits.length,
          chang_dau: paceText(paces[0] ?? null),
          chang_cuoi: paceText(paces[paces.length - 1] ?? null),
          chang_nhanh_nhat: paces.length ? paceText(Math.min(...paces)) : null,
          chang_cham_nhat: paces.length ? paceText(Math.max(...paces)) : null,
          nua_dau_so_voi_nua_sau: paces.length >= 4
            ? (() => {
              const half = Math.floor(paces.length / 2);
              const mean = (xs: number[]) => xs.reduce((a, b) => a + b, 0) / xs.length;
              const delta = Math.round(mean(paces.slice(half)) - mean(paces.slice(0, half)));
              return delta === 0 ? 'đều nhau'
                : delta > 0 ? `nửa sau chậm hơn ${delta} giây mỗi km`
                  : `nửa sau nhanh hơn ${-delta} giây mỗi km`;
            })()
            : null,
        };
      })()
      : {
        ...shared,
        phan_tram_thoi_gian_moi_vung: Object.fromEntries(
          zones.map((z) => [`Z${z.zoneNumber}`, `${z.percentOfSession ?? 0}%`]),
        ),
        du_doan_5km: durationText(
          predictions.find((p) => p.distanceM === 5000)?.predictedSeconds ?? null,
        ),
      };

  const locale = await accountLocale(db, user);
  const insight = await workoutInsight(db, c.env, session.id, kind, locale, data);
  return c.json({ kind, body: insight?.body ?? null });
});

/**
 * Saving a run. It is a flag on the session rather than a table of its own —
 * only the owner ever sees their workouts, so there is no second party whose
 * bookmark would need a row.
 */
app.post('/workouts/:id/bookmark', async (c) => {
  const body = await parseBody(c, z.object({ bookmarked: z.boolean() }));
  const db = c.get('db');
  const session = await ownedWorkout(db, c.get('user').id, c.req.param('id'));
  await db.update(workoutSessions)
    .set({ isBookmarked: body.bookmarked, updatedAt: Date.now() })
    .where(eq(workoutSessions.id, session.id));
  return c.json({ bookmarked: body.bookmarked });
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

  // A typed figure sticks; clearing it (null) hands it back to the estimate.
  if (body.caloriesBurnedKcal !== undefined) patch.caloriesAreEstimated = body.caloriesBurnedKcal == null;

  await db.update(workoutSessions).set(patch).where(eq(workoutSessions.id, session.id));
  if (body.photoAssetIds !== undefined) {
    await setWorkoutPhotos(db, user.id, session.id, body.photoAssetIds);
  }
  await refreshEstimatedCalories(db, user.id, session.id);
  await recomputeDailyNutritionSummary(db, c.env, user.id, session.localDate);

  const [rows, photos] = await Promise.all([
    db.select().from(workoutSessions).where(eq(workoutSessions.id, session.id)).limit(1),
    photosBySession(db, [session.id]),
  ]);
  return c.json({ ...rows[0], photoAssetIds: photos.get(session.id) ?? [] });
});

/**
 * Deleting a workout removes it, the way deleting a meal does.
 *
 * It used to be a flag: PATCH { isDeleted: true } hid the session from the
 * feed and left everything it had produced behind — the personal records it
 * set stayed on the board, so a run the user had thrown away kept holding
 * their 5 km best and the assistant kept reading it back to them.
 *
 * Order matters. The photos are detached first, while the session still
 * exists, because that is what decides whether an asset is still referenced
 * anywhere. The records go next: nothing cascades from personal_records, and
 * a strength record points at a set this delete is about to take with it.
 */
app.delete('/workouts/:id', async (c) => {
  const db = c.get('db');
  const user = c.get('user');
  const session = await ownedWorkout(db, user.id, c.req.param('id'));

  await setWorkoutPhotos(db, user.id, session.id, []);
  await dropRecordsForSession(db, user.id, session.id);
  // Streams, splits, zone summaries and strength sets cascade from here.
  await db.delete(workoutSessions).where(eq(workoutSessions.id, session.id));
  // The day's burned calories are a stored sum, not a view.
  await recomputeDailyNutritionSummary(db, c.env, user.id, session.localDate);

  return c.body(null, 204);
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
  const samples = normaliseSamples(parseSampleStream(text));
  const derivation = deriveFromSamples(samples);
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
        kind: 'hr' as const,
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

  await refreshEstimatedCalories(db, userId, session.id);

  const records = await detectPersonalRecords(db, userId, session.id);
  // Best efforts, predictions, pace zones and GAP. It reads the session row
  // back for the cadence and moving time the update above just wrote.
  const analysis = await persistRunAnalysis(
    db, userId,
    {
      id: session.id,
      activityTypeId: session.activityTypeId,
      avgCadence: session.avgCadence,
      movingSeconds: totals.movingSeconds || session.movingSeconds,
    },
    samples, derivation.cumulative, now,
  );
  return { derivation, zoneTimes, records, analysis };
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
  await recomputeDailyNutritionSummary(db, c.env, user.id, session.localDate);

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
 * for replaying the route, picking crop bounds and drawing the detail screen's
 * charts. The stored polyline has no timestamps, so this reads the raw stream.
 *
 * One endpoint serves all three because they want the same series at different
 * resolutions: `points` trades detail for payload, and the charts ask for a few
 * hundred while crop asks for everything it can get.
 *
 * `pace` and `gap` are measured across the gap to the PREVIOUS returned point,
 * not between raw samples — at a one-second sample rate a runner covers about
 * three metres, and a pace computed over three metres is GPS noise.
 */
app.get('/workouts/:id/track', async (c) => {
  const query = parseQuery(c, z.object({
    points: z.coerce.number().int().min(50).max(TRACK_MAX_POINTS).default(TRACK_MAX_POINTS),
  }));
  const session = await ownedWorkout(c.get('db'), c.get('user').id, c.req.param('id'));
  const { text } = await streamObject(c, session.id);
  const gps = normaliseSamples(parseSampleStream(text))
    .filter((s) => s.lat !== null && s.lng !== null);
  const stride = Math.max(1, Math.ceil(gps.length / query.points));
  const kept = gps.filter((_, i) => i % stride === 0 || i === gps.length - 1);

  const items = kept.map((s, i) => {
    const prev = i > 0 ? kept[i - 1]! : null;
    let pace: number | null = null;
    let gap: number | null = null;
    if (prev) {
      const dd = s.d - prev.d;
      const dt = s.t - prev.t;
      if (dd > 1 && dt > 0) {
        const raw = (dt / dd) * 1000;
        // Same noise floor as the session totals: nothing under 2:00/km is real.
        if (raw >= 120 && raw <= 3600) {
          pace = Math.round(raw);
          const grade = s.ele !== null && prev.ele !== null ? (s.ele - prev.ele) / dd : 0;
          gap = Math.round(gradeAdjustedPace(raw, grade));
        }
      }
    }
    return {
      t: Math.round(s.t * 10) / 10,
      lat: s.lat,
      lng: s.lng,
      d: Math.round(s.d),
      ele: s.ele,
      hr: s.hr,
      pace,
      gap,
    };
  });
  // The first point has no predecessor to measure against; it borrows the
  // second's pace so the chart starts on the line rather than at zero.
  if (items.length > 1) {
    items[0]!.pace = items[1]!.pace;
    items[0]!.gap = items[1]!.gap;
  }
  return c.json({ items });
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

/* -------------------------------------------------------------------------- */
/* Progress tab                                                                */
/* -------------------------------------------------------------------------- */

/**
 * Two endpoints, not nine and not one.
 *
 * The chart at the top changes sport whenever a chip is tapped, and only it
 * does — so it gets its own endpoint that takes the sport and answers with
 * nothing but the twelve weeks. Everything else on the tab is sport-agnostic
 * and is read from one scan of the same sessions, so splitting it per card
 * would mean eight round trips over one dataset. One call fills the page, one
 * small call follows each chip.
 */

/** How far back the tab ever looks: a streak can be long, a year of it is enough. */
const PROGRESS_HISTORY_DAYS = 400;

/** The window the zone and prediction cards call "1 tháng qua". */
const PROGRESS_MONTH_DAYS = 30;

const progressQuerySchema = z.object({
  sport: z.string().min(1).max(64).default(ALL_SPORTS),
  weeks: z.coerce.number().int().min(4).max(52).default(12),
});

/** Sessions reduced to what the progress maths reads, newest last. */
async function loadProgressSessions(
  c: Context<AppEnv>, from: string,
): Promise<ProgressSession[]> {
  const db = c.get('db');
  const rows = await db.select({
    localDate: workoutSessions.localDate,
    startedAt: workoutSessions.startedAt,
    activityTypeId: workoutSessions.activityTypeId,
    durationSeconds: workoutSessions.durationSeconds,
    movingSeconds: workoutSessions.movingSeconds,
    distanceM: workoutSessions.distanceM,
    elevationGainM: workoutSessions.elevationGainM,
  }).from(workoutSessions).where(and(
    eq(workoutSessions.userId, c.get('user').id),
    eq(workoutSessions.isDeleted, false),
    gte(workoutSessions.localDate, from),
  )).orderBy(asc(workoutSessions.startedAt));

  const typeIds = [...new Set(rows.map((r) => r.activityTypeId))];
  const types = typeIds.length
    ? await db.select({ id: activityTypes.id, code: activityTypes.code })
      .from(activityTypes).where(inArray(activityTypes.id, typeIds))
    : [];
  const codeById = new Map(types.map((t) => [t.id, t.code]));

  return rows.map((r) => {
    const code = codeById.get(r.activityTypeId) ?? 'other';
    return {
      localDate: r.localDate,
      startedAt: r.startedAt,
      activityCode: code,
      sport: sportOf(code),
      // Moving time is what a pace is measured against; elapsed is the fallback
      // for a manually typed session, which has no moving figure at all.
      movingSeconds: r.movingSeconds ?? r.durationSeconds ?? 0,
      distanceM: r.distanceM ?? 0,
      elevationGainM: r.elevationGainM ?? 0,
    };
  });
}

app.get('/training/progress/weeks', async (c) => {
  const q = parseQuery(c, progressQuerySchema);
  const today = localDate(Date.now(), c.get('user').timezone);
  const from = addDays(today, -(q.weeks + 1) * 7);
  const sessions = (await loadProgressSessions(c, from))
    .filter((s) => matchesSport(q.sport, s.activityCode));
  return c.json({
    sport: q.sport,
    today,
    weeks: weekSeries(sessions, today, q.weeks),
  });
});

app.get('/training/progress', async (c) => {
  const db = c.get('db');
  const userId = c.get('user').id;
  const today = localDate(Date.now(), c.get('user').timezone);
  const monthStart = `${monthOf(today)}-01`;
  const lastMonth = previousMonth(monthOf(today));
  const zoneFrom = addDays(today, -(PROGRESS_MONTH_DAYS - 1));
  const zonePreviousFrom = addDays(zoneFrom, -PROGRESS_MONTH_DAYS);

  /** Time in zone over a window, joined through the sessions that own it. */
  const zonesBetween = (from: string, to: string) => db.select({
    zone: workoutZoneSummaries.zoneNumber,
    seconds: workoutZoneSummaries.secondsInZone,
  }).from(workoutZoneSummaries)
    .innerJoin(workoutSessions, eq(workoutSessions.id, workoutZoneSummaries.workoutSessionId))
    .where(and(
      eq(workoutSessions.userId, userId),
      eq(workoutSessions.isDeleted, false),
      gte(workoutSessions.localDate, from),
      lte(workoutSessions.localDate, to),
    ));

  const [sessions, profileRows, recordRows, zonesNow, zonesBefore] = await Promise.all([
    loadProgressSessions(c, addDays(today, -PROGRESS_HISTORY_DAYS)),
    db.select({ trainingFocus: userProfiles.trainingFocus }).from(userProfiles)
      .where(eq(userProfiles.userId, userId)).limit(1),
    db.select().from(personalRecords).where(and(
      eq(personalRecords.userId, userId),
      eq(personalRecords.metric, 'fastest_distance'),
      eq(personalRecords.isCurrent, true),
    )).orderBy(desc(personalRecords.distanceM)).limit(3),
    zonesBetween(zoneFrom, today),
    zonesBetween(zonePreviousFrom, addDays(zoneFrom, -1)),
  ]);

  const monthWindow = sessions.filter((s) => s.localDate >= zoneFrom);

  return c.json({
    today,
    focus: profileRows[0]?.trainingFocus ?? 'stay_active',
    sports: sportChips(sessions.filter((s) => s.localDate >= addDays(today, -12 * 7))),
    streakWeeks: streakWeeks(sessions, today),
    log: weekLog(sessions, today),
    suggestion: suggestWorkout(sessions, today),
    prediction: predictionSeries(monthWindow),
    zones: {
      from: zoneFrom,
      to: today,
      ...zoneBreakdown(zonesNow, zonesBefore),
    },
    records: recordRows.map((r) => ({
      distanceM: r.distanceM,
      seconds: r.value,
      achievedAt: r.achievedAt,
      // Every row here is the standing best for its distance, so nothing on
      // this card is ranked below first. The field exists because the card
      // draws a medal, and a medal needs a place.
      rank: 1,
    })),
    monthRecap: { month: lastMonth },
    monthly: {
      thisMonth: monthSeries(sessions.filter((s) => s.localDate >= monthStart), monthOf(today), today),
      lastMonth: monthSeries(
        sessions.filter((s) => monthOf(s.localDate) === lastMonth), lastMonth,
      ),
    },
  });
});

export default app;
