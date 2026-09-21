import {
  sqliteTable, text, integer, real, index, uniqueIndex, primaryKey, check,
} from 'drizzle-orm/sqlite-core';
import { sql } from 'drizzle-orm';
import { pkUuid, ts, tsNow, bool } from './_shared';
import { users, mediaAssets } from './core';

export const SLEEP_SOURCES = ['health_sync', 'phone_mic', 'manual'] as const;
export const SLEEP_STAGES = ['awake', 'light', 'deep', 'rem'] as const;
export const SLEEP_AUDIO_EVENTS = [
  'snore', 'sleep_talk', 'cough', 'movement', 'apnea_suspect', 'other',
] as const;

export const sleepSessions = sqliteTable('sleep_sessions', {
  id: pkUuid(),
  userId: text('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  source: text('source', { enum: SLEEP_SOURCES }).notNull(),
  externalId: text('external_id'),
  startedAt: integer('started_at').notNull(),
  endedAt: ts('ended_at'),
  /** YYYY-MM-DD of the WAKE-UP day — the debt accounting key. */
  localDate: text('local_date').notNull(),
  inBedSeconds: integer('in_bed_seconds'),
  totalSleepSeconds: integer('total_sleep_seconds'),
  awakeSeconds: integer('awake_seconds'),
  lightSeconds: integer('light_seconds'),
  deepSeconds: integer('deep_seconds'),
  remSeconds: integer('rem_seconds'),
  sleepLatencySeconds: integer('sleep_latency_seconds'),
  sleepEfficiency: real('sleep_efficiency'),
  sleepScore: integer('sleep_score'),
  avgHeartRate: integer('avg_heart_rate'),
  /** 1 when stages came from phone mic/motion instead of a wearable. */
  stagesAreEstimated: bool('stages_are_estimated', false),
  audioRecordingEnabled: bool('audio_recording_enabled', false),
  /** What the user called the night, and anything they wanted to say about it. */
  title: text('title'),
  notes: text('notes'),
  createdAt: tsNow('created_at'),
  updatedAt: tsNow('updated_at'),
}, (t) => [
  uniqueIndex('sleep_sessions_user_date_uq').on(t.userId, t.localDate),
  // Listed newest-id first per user; the date unique index cannot serve that.
  index('sleep_sessions_user_id_idx').on(t.userId, t.id),
  uniqueIndex('sleep_sessions_external_uq').on(t.source, t.externalId),
  check('sleep_sessions_source_ck', sql`${t.source} in ('health_sync','phone_mic','manual')`),
]);

/** Full-night hypnogram, ~40-80 rows per night. */
export const sleepStageSegments = sqliteTable('sleep_stage_segments', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  sleepSessionId: text('sleep_session_id').notNull()
    .references(() => sleepSessions.id, { onDelete: 'cascade' }),
  stage: text('stage', { enum: SLEEP_STAGES }).notNull(),
  startedAt: integer('started_at').notNull(),
  endedAt: integer('ended_at').notNull(),
  confidence: real('confidence'),
}, (t) => [
  index('sleep_stage_segments_idx').on(t.sleepSessionId, t.startedAt),
  check('sleep_stage_ck', sql`${t.stage} in ('awake','light','deep','rem')`),
]);

/**
 * One short clip per detected snore/sleep-talk moment, never the whole night.
 * Clips are retained indefinitely and only removed when the user deletes them.
 */
export const sleepAudioEvents = sqliteTable('sleep_audio_events', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  sleepSessionId: text('sleep_session_id').notNull()
    .references(() => sleepSessions.id, { onDelete: 'cascade' }),
  eventType: text('event_type', { enum: SLEEP_AUDIO_EVENTS }).notNull(),
  occurredAt: integer('occurred_at').notNull(),
  durationMs: integer('duration_ms'),
  peakDb: real('peak_db'),
  confidence: real('confidence'),
  audioAssetId: text('audio_asset_id').references(() => mediaAssets.id),
  transcript: text('transcript'),
  /** Denormalized from the hypnogram for quick filtering. */
  stageAtEvent: text('stage_at_event', { enum: SLEEP_STAGES }),
  /**
   * When the user hid this event. The row and its clip stay: the clip is
   * evidence about their own night and the classification is training data,
   * so "xoá" here means "stop showing me this".
   */
  deletedAt: ts('deleted_at'),
  createdAt: tsNow('created_at'),
}, (t) => [
  index('sleep_audio_events_idx').on(t.sleepSessionId, t.occurredAt),
  index('sleep_audio_events_live_idx')
    .on(t.sleepSessionId, t.deletedAt, t.occurredAt),
]);

/** Fixed personal target, accumulated over a 14-day rolling window. */
export const sleepDebtDaily = sqliteTable('sleep_debt_daily', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  userId: text('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  localDate: text('local_date').notNull(),
  targetSleepSeconds: integer('target_sleep_seconds').notNull(),
  actualSleepSeconds: integer('actual_sleep_seconds').notNull().default(0),
  /** actual - target; negative = shortfall. */
  dailyDiffSeconds: integer('daily_diff_seconds').notNull(),
  /** Sum of negative diffs over the trailing 14 days ending on local_date. */
  rolling14dDebtSeconds: integer('rolling_14d_debt_seconds').notNull(),
  createdAt: tsNow('created_at'),
  updatedAt: tsNow('updated_at'),
}, (t) => [
  uniqueIndex('sleep_debt_uq').on(t.userId, t.localDate),
]);

export const sleepReminders = sqliteTable('sleep_reminders', {
  id: pkUuid(),
  userId: text('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  reminderType: text('reminder_type').notNull(),
  /** HH:MM in the user tz. */
  remindAtLocal: text('remind_at_local').notNull(),
  daysOfWeek: text('days_of_week').notNull(),
  isEnabled: bool('is_enabled', true),
  lastFiredAt: ts('last_fired_at'),
  createdAt: tsNow('created_at'),
  updatedAt: tsNow('updated_at'),
}, (t) => [
  index('sleep_reminders_user_idx').on(t.userId, t.isEnabled),
]);

/** Photos attached to a night, ordered the way the user arranged them. */
export const sleepPhotos = sqliteTable('sleep_photos', {
  sleepSessionId: text('sleep_session_id').notNull()
    .references(() => sleepSessions.id, { onDelete: 'cascade' }),
  assetId: text('asset_id').notNull().references(() => mediaAssets.id),
  sortOrder: integer('sort_order').notNull().default(0),
  createdAt: tsNow('created_at'),
}, (t) => [
  primaryKey({ columns: [t.sleepSessionId, t.assetId] }),
  index('sleep_photos_order_idx').on(t.sleepSessionId, t.sortOrder),
  index('sleep_photos_asset_idx').on(t.assetId),
]);
