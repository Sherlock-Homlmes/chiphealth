import { Hono } from 'hono';
import { insertMany } from '../db/client';
import type { AnySQLiteColumn } from 'drizzle-orm/sqlite-core';
import { z } from 'zod';
import { and, asc, desc, eq, gte, isNotNull, isNull, lt, lte, sql } from 'drizzle-orm';
import {
  activityTypes,
  authSessions,
  bodyMetricsLogs,
  chronicConditions,
  goals,
  healthConnections,
  sleepSessions,
  userActivityPreferences,
  userProfiles,
  users,
  workoutSessions,
} from '../db/schema';
import { newId } from '../lib/ids';
import { isoDateSchema, page, paginationSchema, parseBody, parseQuery } from '../lib/http';
import { ApiError, notFound } from '../lib/errors';
import { SUPPORTED_LOCALES } from '../lib/language';
import {
  expiryFromDays, forgetFact, listFacts, rememberFact, MAX_FACT_LENGTH, MAX_TTL_DAYS,
} from '../services/agent/memory';
import { FACT_CATEGORIES } from '../db/schema';
import { addDays, localDate } from '../lib/time';
import {
  computeBmrTdee,
  loadTdeeInputs,
  recomputeDailyNutritionSummary,
} from '../services/nutritionMath';
import type { AppEnv } from '../env';
import type { Db } from '../db/client';

const me = new Hono<AppEnv>();

/* -------------------------------------------------------------------------- */
/* Shared shapes                                                               */
/* -------------------------------------------------------------------------- */

const SEX = ['male', 'female'] as const;
const ACTIVITY_LEVELS = ['sedentary', 'light', 'moderate', 'active', 'very_active'] as const;
const GOAL_TYPES = [
  'lose_weight', 'gain_weight', 'gain_muscle', 'reduce_body_fat',
  'improve_endurance', 'improve_strength', 'sleep_better', 'manage_condition',
] as const;
const GOAL_STATUSES = ['active', 'completed', 'abandoned'] as const;
const BODY_METRIC_SOURCES = ['manual', 'health_sync', 'estimated'] as const;

const hhmm = z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/, 'Expected HH:MM');

async function loadUserRow(db: Db, userId: string) {
  const rows = await db.select().from(users)
    .where(and(eq(users.id, userId), isNull(users.deletedAt)))
    .limit(1);
  const row = rows[0];
  if (!row) throw notFound('User');
  return row;
}

const publicUser = (u: Awaited<ReturnType<typeof loadUserRow>>) => ({
  id: u.id,
  email: u.email,
  emailVerified: u.emailVerified,
  displayName: u.displayName,
  avatarAssetId: u.avatarAssetId,
  avatarRemoteUrl: u.avatarRemoteUrl,
  role: u.role,
  locale: u.locale,
  unitSystem: u.unitSystem,
  timezone: u.timezone,
  createdAt: u.createdAt,
  updatedAt: u.updatedAt,
});

/* -------------------------------------------------------------------------- */
/* GET /v1/me — the composite bootstrap payload                                */
/* -------------------------------------------------------------------------- */

me.get('/', async (c) => {
  const db = c.get('db');
  const userId = c.get('user').id;

  // Six independent reads, one round of D1 latency.
  const [userRow, profileRows, metricRows, goalRows, conditionRows, connectionRows] =
    await Promise.all([
      loadUserRow(db, userId),
      db.select().from(userProfiles).where(eq(userProfiles.userId, userId)).limit(1),
      db.select().from(bodyMetricsLogs)
        .where(eq(bodyMetricsLogs.userId, userId))
        .orderBy(desc(bodyMetricsLogs.recordedAt))
        .limit(1),
      db.select().from(goals)
        .where(and(eq(goals.userId, userId), eq(goals.status, 'active')))
        .orderBy(desc(goals.priority), desc(goals.id)),
      db.select().from(chronicConditions)
        .where(and(eq(chronicConditions.userId, userId), eq(chronicConditions.isActive, true)))
        .orderBy(desc(chronicConditions.id)),
      db.select().from(healthConnections).where(eq(healthConnections.userId, userId)),
    ]);

  return c.json({
    user: publicUser(userRow),
    profile: profileRows[0] ?? null,
    latestBodyMetrics: metricRows[0] ?? null,
    activeGoals: goalRows,
    activeConditions: conditionRows,
    wearable: {
      connected: connectionRows.some((r) => r.isEnabled),
      connections: connectionRows.map((r) => ({
        id: r.id,
        platform: r.platform,
        isEnabled: r.isEnabled,
        grantedScopes: r.grantedScopes ? safeJson(r.grantedScopes) : null,
        lastSyncedAt: r.lastSyncedAt,
        lastSyncError: r.lastSyncError,
      })),
    },
  });
});

function safeJson(raw: string): unknown {
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

/* -------------------------------------------------------------------------- */
/* PATCH /v1/me                                                                */
/* -------------------------------------------------------------------------- */

const patchMeSchema = z.object({
  displayName: z.string().min(1).max(120).nullable().optional(),
  // Only the languages the app can actually speak: the ARB files, the
  // assistant's replies and the speech recogniser all key off this one value,
  // so a locale with no translation behind it would be a half-translated app.
  locale: z.enum(SUPPORTED_LOCALES).optional(),
  unitSystem: z.enum(['metric', 'imperial']).optional(),
  timezone: z.string().min(1).max(64).optional(),
  avatarAssetId: z.string().uuid().nullable().optional(),
}).strict();

me.patch('/', async (c) => {
  const body = await parseBody(c, patchMeSchema);
  const db = c.get('db');
  const userId = c.get('user').id;

  if (body.timezone !== undefined) {
    // A bad IANA id would silently poison every future local_date derivation.
    try {
      new Intl.DateTimeFormat('en-CA', { timeZone: body.timezone });
    } catch {
      throw new ApiError('VALIDATION_ERROR', `Unknown IANA timezone: ${body.timezone}`);
    }
  }

  await db.update(users).set({
    ...(body.displayName !== undefined ? { displayName: body.displayName } : {}),
    ...(body.locale !== undefined ? { locale: body.locale } : {}),
    ...(body.unitSystem !== undefined ? { unitSystem: body.unitSystem } : {}),
    ...(body.timezone !== undefined ? { timezone: body.timezone } : {}),
    ...(body.avatarAssetId !== undefined ? { avatarAssetId: body.avatarAssetId } : {}),
    updatedAt: Date.now(),
  }).where(and(eq(users.id, userId), isNull(users.deletedAt)));

  return c.json({ user: publicUser(await loadUserRow(db, userId)) });
});

/* -------------------------------------------------------------------------- */
/* DELETE /v1/me — soft delete + revoke every session                          */
/* -------------------------------------------------------------------------- */

me.delete('/', async (c) => {
  const db = c.get('db');
  const userId = c.get('user').id;
  const now = Date.now();

  await db.update(users)
    .set({ deletedAt: now, updatedAt: now })
    .where(and(eq(users.id, userId), isNull(users.deletedAt)));
  await db.update(authSessions)
    .set({ revokedAt: now })
    .where(and(eq(authSessions.userId, userId), isNull(authSessions.revokedAt)));

  return c.body(null, 204);
});

/* -------------------------------------------------------------------------- */
/* GET / PUT /v1/me/profile                                                    */
/* -------------------------------------------------------------------------- */

const profileSchema = z.object({
  dateOfBirth: isoDateSchema.nullable().optional(),
  biologicalSex: z.enum(SEX).nullable().optional(),
  activityLevel: z.enum(ACTIVITY_LEVELS).optional(),
  maxHeartRateOverride: z.number().int().min(80).max(240).nullable().optional(),
  restingHeartRate: z.number().int().min(25).max(140).nullable().optional(),
  lactateThresholdHr: z.number().int().min(80).max(230).nullable().optional(),
  targetSleepMinutes: z.number().int().min(180).max(900).optional(),
  bedtimeTarget: hhmm.nullable().optional(),
  waketimeTarget: hhmm.nullable().optional(),
  dailyCalorieOverrideKcal: z.number().min(800).max(6000).nullable().optional(),
  onboardingCompleted: z.boolean().optional(),
}).strict();

async function ensureProfile(db: Db, userId: string) {
  const rows = await db.select().from(userProfiles)
    .where(eq(userProfiles.userId, userId)).limit(1);
  const existing = rows[0];
  if (existing) return existing;
  const now = Date.now();
  await db.insert(userProfiles).values({ userId, createdAt: now, updatedAt: now });
  const created = await db.select().from(userProfiles)
    .where(eq(userProfiles.userId, userId)).limit(1);
  const row = created[0];
  if (!row) throw new ApiError('INTERNAL', 'Profile row disappeared right after insert');
  return row;
}

me.get('/profile', async (c) => c.json(await ensureProfile(c.get('db'), c.get('user').id)));

me.put('/profile', async (c) => {
  const body = await parseBody(c, profileSchema);
  const db = c.get('db');
  const userId = c.get('user').id;
  await ensureProfile(db, userId);

  const now = Date.now();
  await db.update(userProfiles).set({
    ...(body.dateOfBirth !== undefined ? { dateOfBirth: body.dateOfBirth } : {}),
    ...(body.biologicalSex !== undefined ? { biologicalSex: body.biologicalSex } : {}),
    ...(body.activityLevel !== undefined ? { activityLevel: body.activityLevel } : {}),
    ...(body.maxHeartRateOverride !== undefined
      ? { maxHeartRateOverride: body.maxHeartRateOverride } : {}),
    ...(body.restingHeartRate !== undefined
      ? { restingHeartRate: body.restingHeartRate } : {}),
    ...(body.lactateThresholdHr !== undefined
      ? { lactateThresholdHr: body.lactateThresholdHr } : {}),
    ...(body.targetSleepMinutes !== undefined
      ? { targetSleepMinutes: body.targetSleepMinutes } : {}),
    ...(body.bedtimeTarget !== undefined ? { bedtimeTarget: body.bedtimeTarget } : {}),
    ...(body.waketimeTarget !== undefined ? { waketimeTarget: body.waketimeTarget } : {}),
    ...(body.dailyCalorieOverrideKcal !== undefined
      ? { dailyCalorieOverrideKcal: body.dailyCalorieOverrideKcal } : {}),
    ...(body.onboardingCompleted === true ? { onboardingCompletedAt: now } : {}),
    updatedAt: now,
  }).where(eq(userProfiles.userId, userId));

  // Sex, age, activity and the override all move today's TDEE.
  await recomputeDailyNutritionSummary(db, c.env, userId, localDate(now, c.get('user').timezone))
    .catch(() => undefined);

  return c.json(await ensureProfile(db, userId));
});

/* -------------------------------------------------------------------------- */
/* Chronic conditions                                                          */
/* -------------------------------------------------------------------------- */

const conditionCreateSchema = z.object({
  id: z.string().uuid().optional(),
  description: z.string().min(1).max(2000),
  diagnosedOn: isoDateSchema.nullable().optional(),
  notes: z.string().max(4000).nullable().optional(),
  isActive: z.boolean().optional(),
}).strict();

const conditionPatchSchema = conditionCreateSchema.partial().omit({ id: true }).strict();

me.get('/conditions', async (c) => {
  const q = parseQuery(c, paginationSchema.extend({
    includeInactive: z.enum(['true', 'false']).default('false'),
  }));
  const db = c.get('db');
  const userId = c.get('user').id;

  const rows = await db.select().from(chronicConditions)
    .where(and(
      eq(chronicConditions.userId, userId),
      q.includeInactive === 'true' ? undefined : eq(chronicConditions.isActive, true),
      q.cursor ? lt(chronicConditions.id, q.cursor) : undefined,
    ))
    .orderBy(desc(chronicConditions.id))
    .limit(q.limit + 1);

  return c.json(page(rows, q.limit));
});

me.post('/conditions', async (c) => {
  const body = await parseBody(c, conditionCreateSchema);
  const db = c.get('db');
  const userId = c.get('user').id;
  const now = Date.now();
  const id = body.id ?? newId();

  await db.insert(chronicConditions).values({
    id,
    userId,
    description: body.description,
    diagnosedOn: body.diagnosedOn ?? null,
    notes: body.notes ?? null,
    isActive: body.isActive ?? true,
    createdAt: now,
    updatedAt: now,
  }).onConflictDoUpdate({
    target: chronicConditions.id,
    // Scoped to the caller, so a guessed id cannot overwrite someone else's row.
    setWhere: eq(chronicConditions.userId, userId),
    set: {
      description: body.description,
      diagnosedOn: body.diagnosedOn ?? null,
      notes: body.notes ?? null,
      isActive: body.isActive ?? true,
      updatedAt: now,
    },
  });

  const rows = await db.select().from(chronicConditions)
    .where(and(eq(chronicConditions.id, id), eq(chronicConditions.userId, userId))).limit(1);
  const row = rows[0];
  if (!row) throw new ApiError('CONFLICT', 'Condition id belongs to another user');
  return c.json(row, 201);
});

me.patch('/conditions/:id', async (c) => {
  const body = await parseBody(c, conditionPatchSchema);
  const db = c.get('db');
  const userId = c.get('user').id;
  const id = c.req.param('id');

  const existing = await db.select().from(chronicConditions)
    .where(and(eq(chronicConditions.id, id), eq(chronicConditions.userId, userId))).limit(1);
  if (!existing[0]) throw notFound('Condition');

  await db.update(chronicConditions).set({
    ...(body.description !== undefined ? { description: body.description } : {}),
    ...(body.diagnosedOn !== undefined ? { diagnosedOn: body.diagnosedOn } : {}),
    ...(body.notes !== undefined ? { notes: body.notes } : {}),
    ...(body.isActive !== undefined ? { isActive: body.isActive } : {}),
    updatedAt: Date.now(),
  }).where(and(eq(chronicConditions.id, id), eq(chronicConditions.userId, userId)));

  const rows = await db.select().from(chronicConditions)
    .where(eq(chronicConditions.id, id)).limit(1);
  return c.json(rows[0] ?? null);
});

me.delete('/conditions/:id', async (c) => {
  const db = c.get('db');
  const userId = c.get('user').id;
  await db.delete(chronicConditions)
    .where(and(
      eq(chronicConditions.id, c.req.param('id')),
      eq(chronicConditions.userId, userId),
    ));
  return c.body(null, 204);
});

/* -------------------------------------------------------------------------- */
/* Body metrics                                                                */
/* -------------------------------------------------------------------------- */

const bodyMetricSchema = z.object({
  recordedAt: z.number().int().positive().optional(),
  weightKg: z.number().min(20).max(400).nullable().optional(),
  heightCm: z.number().min(80).max(260).nullable().optional(),
  bodyFatPercent: z.number().min(1).max(75).nullable().optional(),
  muscleMassKg: z.number().min(1).max(200).nullable().optional(),
  waistCm: z.number().min(30).max(250).nullable().optional(),
  source: z.enum(BODY_METRIC_SOURCES).optional(),
}).strict().refine(
  (v) => v.weightKg != null || v.heightCm != null || v.bodyFatPercent != null
    || v.muscleMassKg != null || v.waistCm != null,
  { message: 'At least one measurement is required' },
);

me.get('/body-metrics', async (c) => {
  const q = parseQuery(c, paginationSchema.extend({
    from: isoDateSchema.optional(),
    to: isoDateSchema.optional(),
  }));
  const db = c.get('db');
  const userId = c.get('user').id;

  const cursorId = q.cursor ? Number(q.cursor) : undefined;
  if (q.cursor !== undefined && !Number.isFinite(cursorId)) {
    throw new ApiError('VALIDATION_ERROR', 'Invalid cursor');
  }

  const rows = await db.select().from(bodyMetricsLogs)
    .where(and(
      eq(bodyMetricsLogs.userId, userId),
      q.from ? gte(bodyMetricsLogs.localDate, q.from) : undefined,
      q.to ? lte(bodyMetricsLogs.localDate, q.to) : undefined,
      cursorId !== undefined ? lt(bodyMetricsLogs.id, cursorId) : undefined,
    ))
    .orderBy(desc(bodyMetricsLogs.id))
    .limit(q.limit + 1);

  return c.json(page(rows, q.limit));
});

me.get('/body-metrics/latest', async (c) => {
  const db = c.get('db');
  const userId = c.get('user').id;
  // Weight and height come from different rows: people re-weigh far more often
  // than they re-measure their height.
  const [latest, weight, height] = await Promise.all([
    db.select().from(bodyMetricsLogs).where(eq(bodyMetricsLogs.userId, userId))
      .orderBy(desc(bodyMetricsLogs.recordedAt)).limit(1),
    db.select({ v: bodyMetricsLogs.weightKg, at: bodyMetricsLogs.recordedAt })
      .from(bodyMetricsLogs)
      .where(and(eq(bodyMetricsLogs.userId, userId), isNotNull(bodyMetricsLogs.weightKg)))
      .orderBy(desc(bodyMetricsLogs.recordedAt)).limit(1),
    db.select({ v: bodyMetricsLogs.heightCm, at: bodyMetricsLogs.recordedAt })
      .from(bodyMetricsLogs)
      .where(and(eq(bodyMetricsLogs.userId, userId), isNotNull(bodyMetricsLogs.heightCm)))
      .orderBy(desc(bodyMetricsLogs.recordedAt)).limit(1),
  ]);

  return c.json({
    latest: latest[0] ?? null,
    weightKg: weight[0]?.v ?? null,
    weightRecordedAt: weight[0]?.at ?? null,
    heightCm: height[0]?.v ?? null,
    heightRecordedAt: height[0]?.at ?? null,
  });
});

me.post('/body-metrics', async (c) => {
  const body = await parseBody(c, bodyMetricSchema);
  const db = c.get('db');
  const user = c.get('user');
  const now = Date.now();
  const recordedAt = body.recordedAt ?? now;

  // local_date is always derived from the timestamp + the user's tz, never taken
  // from the client — it is the grouping key for every daily rollup.
  const day = localDate(recordedAt, user.timezone);

  const inserted = await db.insert(bodyMetricsLogs).values({
    userId: user.id,
    recordedAt,
    localDate: day,
    weightKg: body.weightKg ?? null,
    heightCm: body.heightCm ?? null,
    bodyFatPercent: body.bodyFatPercent ?? null,
    muscleMassKg: body.muscleMassKg ?? null,
    waistCm: body.waistCm ?? null,
    source: body.source ?? 'manual',
    createdAt: now,
  }).returning();

  // Weight moves BMR, which moves TDEE, which moves the day's calorie balance.
  c.executionCtx.waitUntil(
    recomputeDailyNutritionSummary(db, c.env, user.id, day).catch(() => undefined),
  );

  return c.json(inserted[0] ?? null, 201);
});

/* -------------------------------------------------------------------------- */
/* Goals — start_value is snapshotted server-side                              */
/* -------------------------------------------------------------------------- */

const goalCreateSchema = z.object({
  id: z.string().uuid().optional(),
  goalType: z.enum(GOAL_TYPES),
  targetValue: z.number().nullable().optional(),
  targetUnit: z.string().max(24).nullable().optional(),
  /** Only used when the server cannot derive a baseline from existing data. */
  startValue: z.number().optional(),
  deadline: isoDateSchema.nullable().optional(),
  priority: z.number().int().min(0).max(100).optional(),
}).strict();

const goalPatchSchema = z.object({
  targetValue: z.number().nullable().optional(),
  targetUnit: z.string().max(24).nullable().optional(),
  deadline: isoDateSchema.nullable().optional(),
  priority: z.number().int().min(0).max(100).optional(),
  status: z.enum(GOAL_STATUSES).optional(),
}).strict();

/** Default unit per goal type, so the client does not have to guess. */
const GOAL_UNITS: Record<(typeof GOAL_TYPES)[number], string | null> = {
  lose_weight: 'kg',
  gain_weight: 'kg',
  gain_muscle: 'kg',
  reduce_body_fat: 'percent',
  improve_endurance: 'km',
  improve_strength: 'kg',
  sleep_better: 'minutes',
  manage_condition: null,
};

/**
 * Snapshots the user's *current* state for the goal type, so progress % is
 * computable later. Returns null when nothing is known — the caller must then
 * have supplied an explicit startValue.
 */
async function deriveStartValue(
  db: Db, userId: string, goalType: (typeof GOAL_TYPES)[number],
): Promise<number | null> {
  // Any nullable numeric column of body_metrics_logs; the caller picks which.
  const latestMetric = async (col: AnySQLiteColumn) => {
    const rows = await db.select({ v: col }).from(bodyMetricsLogs)
      .where(and(eq(bodyMetricsLogs.userId, userId), isNotNull(col)))
      .orderBy(desc(bodyMetricsLogs.recordedAt)).limit(1);
    return (rows[0]?.v as number | null | undefined) ?? null;
  };

  switch (goalType) {
    case 'lose_weight':
    case 'gain_weight':
      return latestMetric(bodyMetricsLogs.weightKg);
    case 'gain_muscle':
      return latestMetric(bodyMetricsLogs.muscleMassKg);
    case 'reduce_body_fat':
      return latestMetric(bodyMetricsLogs.bodyFatPercent);
    case 'sleep_better': {
      // Baseline = mean sleep per DAY over the trailing two weeks, in minutes.
      // Per day, not per session: a day's night and its nap are one day's
      // sleep, and averaging the rows would count them as two short nights.
      const since = addDays(localDate(Date.now(), 'UTC'), -14);
      const rows = await db.select({
        daySeconds: sql<number>`sum(${sleepSessions.totalSleepSeconds})`,
      }).from(sleepSessions)
        .where(and(
          eq(sleepSessions.userId, userId),
          gte(sleepSessions.localDate, since),
          isNotNull(sleepSessions.totalSleepSeconds),
        ))
        .groupBy(sleepSessions.localDate);
      if (rows.length === 0) return null;
      const total = rows.reduce((sum, r) => sum + (r.daySeconds ?? 0), 0);
      return Math.round(total / rows.length / 60);
    }
    case 'improve_endurance': {
      // Baseline = longest single session distance in the last 90 days, in km.
      const rows = await db.select({
        maxDistance: sql<number | null>`max(${workoutSessions.distanceM})`,
      }).from(workoutSessions)
        .where(and(
          eq(workoutSessions.userId, userId),
          eq(workoutSessions.isDeleted, false),
          gte(workoutSessions.startedAt, Date.now() - 90 * 24 * 3600 * 1000),
        ));
      const m = rows[0]?.maxDistance;
      return m == null ? null : Math.round(m / 100) / 10;
    }
    default:
      // improve_strength and manage_condition have no single scalar baseline.
      return null;
  }
}

me.get('/goals', async (c) => {
  const q = parseQuery(c, paginationSchema.extend({
    status: z.enum(GOAL_STATUSES).optional(),
  }));
  const db = c.get('db');
  const userId = c.get('user').id;

  const rows = await db.select().from(goals)
    .where(and(
      eq(goals.userId, userId),
      q.status ? eq(goals.status, q.status) : undefined,
      q.cursor ? lt(goals.id, q.cursor) : undefined,
    ))
    .orderBy(desc(goals.id))
    .limit(q.limit + 1);

  return c.json(page(rows, q.limit));
});

me.post('/goals', async (c) => {
  const body = await parseBody(c, goalCreateSchema);
  const db = c.get('db');
  const userId = c.get('user').id;

  const derived = await deriveStartValue(db, userId, body.goalType);
  const startValue = derived ?? body.startValue;
  if (startValue === undefined) {
    throw new ApiError(
      'VALIDATION_ERROR',
      `No baseline is known for goal type "${body.goalType}" — send an explicit startValue`,
      { field: 'startValue', goalType: body.goalType },
    );
  }

  const now = Date.now();
  const id = body.id ?? newId();
  await db.insert(goals).values({
    id,
    userId,
    goalType: body.goalType,
    targetValue: body.targetValue ?? null,
    targetUnit: body.targetUnit ?? GOAL_UNITS[body.goalType],
    startValue,
    deadline: body.deadline ?? null,
    priority: body.priority ?? 0,
    status: 'active',
    createdAt: now,
    updatedAt: now,
  });

  const rows = await db.select().from(goals)
    .where(and(eq(goals.id, id), eq(goals.userId, userId))).limit(1);
  return c.json({ ...rows[0], startValueSource: derived != null ? 'server' : 'client' }, 201);
});

me.patch('/goals/:id', async (c) => {
  const body = await parseBody(c, goalPatchSchema);
  const db = c.get('db');
  const userId = c.get('user').id;
  const id = c.req.param('id');

  const existing = await db.select().from(goals)
    .where(and(eq(goals.id, id), eq(goals.userId, userId))).limit(1);
  if (!existing[0]) throw notFound('Goal');

  const now = Date.now();
  await db.update(goals).set({
    ...(body.targetValue !== undefined ? { targetValue: body.targetValue } : {}),
    ...(body.targetUnit !== undefined ? { targetUnit: body.targetUnit } : {}),
    ...(body.deadline !== undefined ? { deadline: body.deadline } : {}),
    ...(body.priority !== undefined ? { priority: body.priority } : {}),
    ...(body.status !== undefined ? { status: body.status } : {}),
    // start_value is a snapshot and is never editable.
    ...(body.status === 'completed' ? { completedAt: now } : {}),
    updatedAt: now,
  }).where(and(eq(goals.id, id), eq(goals.userId, userId)));

  const rows = await db.select().from(goals).where(eq(goals.id, id)).limit(1);
  return c.json(rows[0] ?? null);
});

me.delete('/goals/:id', async (c) => {
  const db = c.get('db');
  await db.delete(goals)
    .where(and(eq(goals.id, c.req.param('id')), eq(goals.userId, c.get('user').id)));
  return c.body(null, 204);
});

/* -------------------------------------------------------------------------- */
/* Sports (user_activity_preferences)                                          */
/* -------------------------------------------------------------------------- */

const sportsSchema = z.object({
  sports: z.array(z.object({
    activityTypeId: z.number().int().positive(),
    skillLevel: z.enum(['beginner', 'intermediate', 'advanced']).nullable().optional(),
    weeklyTargetSessions: z.number().int().min(0).max(21).nullable().optional(),
  })).max(50),
}).strict();

me.get('/sports', async (c) => {
  const db = c.get('db');
  const rows = await db.select({
    id: userActivityPreferences.id,
    activityTypeId: userActivityPreferences.activityTypeId,
    skillLevel: userActivityPreferences.skillLevel,
    weeklyTargetSessions: userActivityPreferences.weeklyTargetSessions,
    code: activityTypes.code,
    category: activityTypes.category,
    iconName: activityTypes.iconName,
  }).from(userActivityPreferences)
    .innerJoin(activityTypes, eq(activityTypes.id, userActivityPreferences.activityTypeId))
    .where(eq(userActivityPreferences.userId, c.get('user').id))
    .orderBy(asc(activityTypes.sortOrder));
  return c.json({ items: rows });
});

me.put('/sports', async (c) => {
  const body = await parseBody(c, sportsSchema);
  const db = c.get('db');
  const userId = c.get('user').id;
  const now = Date.now();

  // Bulk replace: the client always sends the full selection.
  await db.delete(userActivityPreferences).where(eq(userActivityPreferences.userId, userId));
  if (body.sports.length > 0) {
    await insertMany(
      (chunk) => db.insert(userActivityPreferences).values(chunk),
      body.sports.map((s) => ({
        userId,
        activityTypeId: s.activityTypeId,
        skillLevel: s.skillLevel ?? null,
        weeklyTargetSessions: s.weeklyTargetSessions ?? null,
        createdAt: now,
      })),
    );
  }

  const rows = await db.select().from(userActivityPreferences)
    .where(eq(userActivityPreferences.userId, userId));
  return c.json({ items: rows });
});

/* -------------------------------------------------------------------------- */
/* GET /v1/me/tdee                                                             */
/* -------------------------------------------------------------------------- */

me.get('/tdee', async (c) => {
  const q = parseQuery(c, z.object({ date: isoDateSchema.optional() }));
  const db = c.get('db');
  const user = c.get('user');
  const day = q.date ?? localDate(Date.now(), user.timezone);

  const [inputs, workoutRows] = await Promise.all([
    loadTdeeInputs(db, user.id),
    db.select({
      burned: sql<number>`coalesce(sum(${workoutSessions.caloriesBurnedKcal}), 0)`,
    }).from(workoutSessions).where(and(
      eq(workoutSessions.userId, user.id),
      eq(workoutSessions.localDate, day),
      eq(workoutSessions.isDeleted, false),
    )),
  ]);

  const workoutKcal = Number(workoutRows[0]?.burned ?? 0);
  const result = computeBmrTdee(inputs, workoutKcal);

  // The inputs are returned verbatim so the app can explain the number instead
  // of showing an unsourced figure.
  return c.json({
    date: day,
    formula: 'mifflin_st_jeor',
    bmrKcal: result.bmrKcal,
    tdeeKcal: result.tdeeKcal,
    missingInputs: result.missing,
    inputs: {
      weightKg: inputs.weightKg,
      weightRecordedAt: inputs.weightRecordedAt,
      heightCm: inputs.heightCm,
      heightRecordedAt: inputs.heightRecordedAt,
      dateOfBirth: inputs.dateOfBirth,
      age: inputs.age,
      biologicalSex: inputs.sex,
      activityLevel: inputs.activityLevel,
      activityMultiplier: inputs.activityMultiplier,
      dailyCalorieOverrideKcal: inputs.dailyCalorieOverrideKcal,
      workoutCaloriesKcal: workoutKcal,
    },
  });
});

/* -------------------------------------------------------------------------- */
/* /v1/me/facts — what the assistant remembers about this user                 */
/* -------------------------------------------------------------------------- */

/**
 * The assistant's long-term memory, behind the same API everything else uses:
 * its tools call these endpoints with the user's own token, so it can read and
 * write exactly its own memory and nothing else.
 *
 * Expired facts are never returned. The list is the live set, permanent facts
 * first — see services/agent/memory.ts for why the filter lives in the query
 * rather than in a sweeper.
 */
me.get('/facts', async (c) => {
  const q = parseQuery(c, z.object({
    q: z.string().trim().max(200).optional(),
    category: z.enum(FACT_CATEGORIES).optional(),
    limit: z.coerce.number().int().min(1).max(100).optional(),
  }));

  const items = await listFacts(c.get('db'), c.get('user').id, {
    query: q.q,
    category: q.category,
    limit: q.limit,
  });
  return c.json({ items });
});

const factSchema = z.object({
  fact: z.string().trim().min(3).max(MAX_FACT_LENGTH),
  category: z.enum(FACT_CATEGORIES).default('other'),
  /**
   * How long the fact stays true. Omitted (or null) means forever — that is
   * the right answer for an allergy and the wrong one for a three-week injury,
   * which is why the caller has to decide rather than getting a default TTL.
   */
  expiresInDays: z.number().positive().max(MAX_TTL_DAYS).nullish(),
  conversationId: z.string().uuid().nullish(),
}).strict();

me.post('/facts', async (c) => {
  const body = await parseBody(c, factSchema);
  const fact = await rememberFact(c.get('db'), c.get('user').id, {
    fact: body.fact,
    category: body.category,
    expiresAt: expiryFromDays(body.expiresInDays),
    conversationId: body.conversationId ?? null,
  });
  return c.json(fact, 201);
});

me.delete('/facts/:id', async (c) => {
  const gone = await forgetFact(c.get('db'), c.get('user').id, c.req.param('id'));
  if (!gone) throw notFound('Fact');
  return c.body(null, 204);
});

export default me;
