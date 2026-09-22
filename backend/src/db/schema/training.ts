import { sqliteTable, text, integer, real, index, uniqueIndex, check, primaryKey } from 'drizzle-orm/sqlite-core';
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
  /** Elapsed minus moving: re-derived from the stream, not taken from the device. */
  stoppedSeconds: integer('stopped_seconds'),
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
  /** Highest point on the route, in metres — the stat grid's "độ cao tối đa". */
  elevationMaxM: real('elevation_max_m'),
  /** Average pace with the hills taken out of it (see services/runAnalysis.ts). */
  gapSecPerKm: real('gap_sec_per_km'),
  /** Cadence x moving minutes; null when the recorder gave no cadence. */
  steps: integer('steps'),
  /** The athlete saved this one from the detail screen's bookmark button. */
  isBookmarked: bool('is_bookmarked', false),
  notes: text('notes'),
  isDeleted: bool('is_deleted', false),
  createdAt: tsNow('created_at'),
  updatedAt: tsNow('updated_at'),
}, (t) => [
  index('workout_sessions_user_started_idx').on(t.userId, t.startedAt),
  // How the feed pages: newest id first, per user, live sessions only.
  index('workout_sessions_user_id_idx').on(t.userId, t.isDeleted, t.id),
  uniqueIndex('workout_sessions_external_uq').on(t.source, t.externalId),
  check('workout_sessions_source_ck', sql`${t.source} in ('in_app','health_sync','manual_entry')`),
]);

/**
 * Photos the athlete attaches to a session — up to five, ordered. Detaching
 * only deletes the link; the media row flips back to orphan and the sweeper
 * reclaims the R2 object, so nothing here ever deletes an asset directly.
 */
export const workoutPhotos = sqliteTable('workout_photos', {
  workoutSessionId: text('workout_session_id').notNull()
    .references(() => workoutSessions.id, { onDelete: 'cascade' }),
  assetId: text('asset_id').notNull()
    .references(() => mediaAssets.id),
  sortOrder: integer('sort_order').notNull().default(0),
  createdAt: tsNow('created_at'),
}, (t) => [
  primaryKey({ columns: [t.workoutSessionId, t.assetId] }),
  index('workout_photos_order_idx').on(t.workoutSessionId, t.sortOrder),
  // "Is this asset still referenced?", asked on every detach.
  index('workout_photos_asset_idx').on(t.assetId),
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

export const ZONE_KINDS = ['hr', 'pace'] as const;

/**
 * Time-in-zone, computed once from the stream at ingest. Two kinds share the
 * table because they are the same shape: heart-rate zones scored against the
 * athlete's max HR, and pace zones scored against their predicted 5 km time.
 */
export const workoutZoneSummaries = sqliteTable('workout_zone_summaries', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  workoutSessionId: text('workout_session_id').notNull()
    .references(() => workoutSessions.id, { onDelete: 'cascade' }),
  kind: text('kind', { enum: ZONE_KINDS }).notNull().default('hr'),
  zoneNumber: integer('zone_number').notNull(),
  secondsInZone: integer('seconds_in_zone').notNull(),
  percentOfSession: real('percent_of_session'),
}, (t) => [
  uniqueIndex('workout_zone_uq').on(t.workoutSessionId, t.kind, t.zoneNumber),
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
  // Deleting a workout has to find what it set; nothing cascades from here.
  index('personal_records_session_idx').on(t.workoutSessionId),
  index('personal_records_set_idx').on(t.strengthSetId),
]);

/** Standard distances a run is scored over, in metres. */
export const BEST_EFFORT_DISTANCES_M = [
  400, 805, 1000, 1609, 3219, 5000, 10000, 15000, 21097, 42195,
] as const;

/**
 * What one run did over a standard distance, and the place it took on the
 * all-time board the day it was run. Unlike `personal_records` — which keeps
 * one standing best per metric — every run that covers the distance gets a row,
 * which is what lets the detail screen say "second fastest 2 miles ever" and
 * what lets the map pin a medal at the stretch of road that earned it.
 */
export const workoutBestEfforts = sqliteTable('workout_best_efforts', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  workoutSessionId: text('workout_session_id').notNull()
    .references(() => workoutSessions.id, { onDelete: 'cascade' }),
  userId: text('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  activityTypeId: integer('activity_type_id').notNull().references(() => activityTypes.id),
  distanceM: real('distance_m').notNull(),
  elapsedSeconds: real('elapsed_seconds').notNull(),
  /** Where along the route the effort started and ended, in cumulative metres. */
  startDistanceM: real('start_distance_m').notNull(),
  endDistanceM: real('end_distance_m').notNull(),
  /** 1 = fastest ever at this distance. Frozen at ingest, never rewritten. */
  rank: integer('rank').notNull(),
  createdAt: tsNow('created_at'),
}, (t) => [
  uniqueIndex('workout_best_efforts_uq').on(t.workoutSessionId, t.distanceM),
  index('workout_best_efforts_board_idx')
    .on(t.userId, t.activityTypeId, t.distanceM, t.elapsedSeconds),
]);

/** Distances the athlete gets a predicted finishing time for. */
export const PREDICTED_DISTANCES_M = [5000, 10000, 21097, 42195] as const;

/**
 * Riegel predictions, kept as history rather than one row per distance, so a
 * run can show how much it moved the number. The session link is nullable:
 * deleting a run must not delete the prediction line it was part of.
 */
export const racePredictions = sqliteTable('race_predictions', {
  id: pkUuid(),
  userId: text('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  activityTypeId: integer('activity_type_id').notNull().references(() => activityTypes.id),
  distanceM: real('distance_m').notNull(),
  predictedSeconds: real('predicted_seconds').notNull(),
  /** What the prediction was before this run; null for the first one. */
  previousSeconds: real('previous_seconds'),
  workoutSessionId: text('workout_session_id')
    .references(() => workoutSessions.id, { onDelete: 'set null' }),
  isCurrent: bool('is_current', true),
  computedAt: tsNow('computed_at'),
}, (t) => [
  index('race_predictions_current_idx')
    .on(t.userId, t.activityTypeId, t.distanceM, t.isCurrent),
  index('race_predictions_session_idx').on(t.workoutSessionId),
]);

export const INSIGHT_KINDS = ['overview', 'pace', 'zones'] as const;

/**
 * The coach's one-liner about a run. Written once and read back: `input_hash`
 * digests the numbers the model was shown, so re-deriving the stream (a crop, a
 * re-upload) invalidates the line while opening the screen again does not.
 */
export const workoutInsights = sqliteTable('workout_insights', {
  workoutSessionId: text('workout_session_id').notNull()
    .references(() => workoutSessions.id, { onDelete: 'cascade' }),
  kind: text('kind', { enum: INSIGHT_KINDS }).notNull(),
  language: text('language').notNull(),
  body: text('body').notNull(),
  inputHash: text('input_hash').notNull(),
  createdAt: tsNow('created_at'),
}, (t) => [
  primaryKey({ columns: [t.workoutSessionId, t.kind, t.language] }),
]);
