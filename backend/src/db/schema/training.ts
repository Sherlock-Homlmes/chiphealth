import { sqliteTable, text, integer, real, index, uniqueIndex, check } from 'drizzle-orm/sqlite-core';
import { sql } from 'drizzle-orm';
import { pkUuid, ts, tsNow, bool } from './_shared';
import { users, mediaAssets } from './core';
import { activityTypes } from './identity';

export const WORKOUT_SOURCES = ['in_app', 'health_sync', 'manual_entry'] as const;
export const HR_ZONE_METHODS = ['auto_age_based', 'manual_max_hr', 'manual_threshold'] as const;
export const PR_METRICS = [
  'fastest_distance', 'longest_distance', 'longest_duration', 'max_elevation_gain',
  'best_pace', 'max_weight', 'max_reps', 'max_volume',
] as const;

export const workoutSessions = sqliteTable('workout_sessions', {
  /** UUIDv7 generated on-device, so recording works offline. */
  id: pkUuid(),
  userId: text('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  activityTypeId: integer('activity_type_id').notNull().references(() => activityTypes.id),
  source: text('source', { enum: WORKOUT_SOURCES }).notNull().default('in_app'),
  /** HealthKit / Health Connect record uuid, for sync dedup. */
  externalId: text('external_id'),
  title: text('title'),
  startedAt: integer('started_at').notNull(),
  endedAt: ts('ended_at'),
  localDate: text('local_date').notNull(),
  durationSeconds: integer('duration_seconds'),
  movingSeconds: integer('moving_seconds'),
  distanceM: real('distance_m'),
  avgHeartRate: integer('avg_heart_rate'),
  maxHeartRate: integer('max_heart_rate'),
  avgPaceSecPerKm: real('avg_pace_sec_per_km'),
  bestPaceSecPerKm: real('best_pace_sec_per_km'),
  avgCadence: integer('avg_cadence'),
  avgPowerW: real('avg_power_w'),
  elevationGainM: real('elevation_gain_m'),
  caloriesBurnedKcal: real('calories_burned_kcal'),
  /** 0 when the number came from the wearable. */
  caloriesAreEstimated: bool('calories_are_estimated', true),
  perceivedExertion: integer('perceived_exertion'),
  notes: text('notes'),
  isDeleted: bool('is_deleted', false),
  createdAt: tsNow('created_at'),
  updatedAt: tsNow('updated_at'),
}, (t) => [
  index('workout_sessions_user_started_idx').on(t.userId, t.startedAt),
  uniqueIndex('workout_sessions_external_uq').on(t.source, t.externalId),
  check('workout_sessions_source_ck', sql`${t.source} in ('in_app','health_sync','manual_entry')`),
]);

/**
 * One row per session instead of thousands of point rows. Full-fidelity samples
 * live as an R2 object; D1 keeps only what the feed and detail screens read.
 */
export const workoutStreams = sqliteTable('workout_streams', {
  workoutSessionId: text('workout_session_id').primaryKey()
    .references(() => workoutSessions.id, { onDelete: 'cascade' }),
  r2AssetId: text('r2_asset_id').references(() => mediaAssets.id),
  sampleCount: integer('sample_count'),
  sampleIntervalS: real('sample_interval_s'),
  /** Google encoded polyline, for map preview without touching R2. */
  encodedPolyline: text('encoded_polyline'),
  /** ~200 points of {t, hr, pace, ele} for in-app charts. */
  downsampledJson: text('downsampled_json'),
  startLatitude: real('start_latitude'),
  startLongitude: real('start_longitude'),
  boundsJson: text('bounds_json'),
  hasGps: bool('has_gps', false),
  hasHeartRate: bool('has_heart_rate', false),
  createdAt: tsNow('created_at'),
});

export const workoutSplits = sqliteTable('workout_splits', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  workoutSessionId: text('workout_session_id').notNull()
    .references(() => workoutSessions.id, { onDelete: 'cascade' }),
  splitIndex: integer('split_index').notNull(),
  splitDistanceM: real('split_distance_m').notNull().default(1000),
  elapsedSeconds: integer('elapsed_seconds').notNull(),
  movingSeconds: integer('moving_seconds'),
  avgHeartRate: integer('avg_heart_rate'),
  elevationGainM: real('elevation_gain_m'),
  avgPaceSecPerKm: real('avg_pace_sec_per_km'),
}, (t) => [
  uniqueIndex('workout_splits_uq').on(t.workoutSessionId, t.splitIndex),
]);

export const workoutExercises = sqliteTable('workout_exercises', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  code: text('code').notNull().unique(),
  muscleGroup: text('muscle_group').notNull(),
  equipment: text('equipment'),
  isUnilateral: bool('is_unilateral', false),
  sortOrder: integer('sort_order').notNull().default(0),
});

export const workoutStrengthSets = sqliteTable('workout_strength_sets', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  workoutSessionId: text('workout_session_id').notNull()
    .references(() => workoutSessions.id, { onDelete: 'cascade' }),
  exerciseId: integer('exercise_id').notNull().references(() => workoutExercises.id),
  setIndex: integer('set_index').notNull(),
  reps: integer('reps'),
  weightKg: real('weight_kg'),
  durationSeconds: integer('duration_seconds'),
  distanceM: real('distance_m'),
  rpe: real('rpe'),
  isWarmup: bool('is_warmup', false),
  restSeconds: integer('rest_seconds'),
  createdAt: tsNow('created_at'),
}, (t) => [
  uniqueIndex('workout_sets_uq').on(t.workoutSessionId, t.exerciseId, t.setIndex),
]);

/**
 * Recomputed when age or the max-HR override changes; effective_from keeps the
 * history so old workouts keep the zones they were scored with.
 */
export const heartRateZones = sqliteTable('heart_rate_zones', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  userId: text('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  zoneNumber: integer('zone_number').notNull(),
  minBpm: integer('min_bpm').notNull(),
  maxBpm: integer('max_bpm').notNull(),
  method: text('method', { enum: HR_ZONE_METHODS }).notNull().default('auto_age_based'),
  maxHeartRateUsed: integer('max_heart_rate_used').notNull(),
  effectiveFrom: integer('effective_from').notNull(),
  createdAt: tsNow('created_at'),
}, (t) => [
  uniqueIndex('hr_zones_uq').on(t.userId, t.effectiveFrom, t.zoneNumber),
]);

/** Time-in-zone, computed once from the stream at ingest. */
export const workoutZoneSummaries = sqliteTable('workout_zone_summaries', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  workoutSessionId: text('workout_session_id').notNull()
    .references(() => workoutSessions.id, { onDelete: 'cascade' }),
  zoneNumber: integer('zone_number').notNull(),
  secondsInZone: integer('seconds_in_zone').notNull(),
  percentOfSession: real('percent_of_session'),
}, (t) => [
  uniqueIndex('workout_zone_uq').on(t.workoutSessionId, t.zoneNumber),
]);

/** Auto-detected after each session. Exactly one of the two source ids is set. */
export const personalRecords = sqliteTable('personal_records', {
  id: pkUuid(),
  userId: text('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  activityTypeId: integer('activity_type_id').references(() => activityTypes.id),
  exerciseId: integer('exercise_id').references(() => workoutExercises.id),
  metric: text('metric', { enum: PR_METRICS }).notNull(),
  /** Set for fastest_distance: 1000 / 5000 / 10000 / 21097 / 42195. */
  distanceM: real('distance_m'),
  value: real('value').notNull(),
  unit: text('unit').notNull(),
  achievedAt: integer('achieved_at').notNull(),
  workoutSessionId: text('workout_session_id').references(() => workoutSessions.id),
  strengthSetId: integer('strength_set_id').references(() => workoutStrengthSets.id),
  previousValue: real('previous_value'),
  /** 0 once beaten; history is kept for the progression chart. */
  isCurrent: bool('is_current', true),
  createdAt: tsNow('created_at'),
}, (t) => [
  index('personal_records_user_current_idx').on(t.userId, t.isCurrent),
]);
