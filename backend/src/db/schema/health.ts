import { sqliteTable, text, integer, real, uniqueIndex } from 'drizzle-orm/sqlite-core';
import { pkUuid, ts, tsNow, bool } from './_shared';
import { users } from './core';

export const HEALTH_PLATFORMS = ['apple_health', 'health_connect'] as const;

/**
 * Apple Health / Health Connect are read on-device — there is no server-side
 * OAuth token. This only records that access was granted, so the server can
 * tell a wearable user from an estimate-only one.
 */
export const healthConnections = sqliteTable('health_connections', {
  id: pkUuid(),
  userId: text('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  platform: text('platform', { enum: HEALTH_PLATFORMS }).notNull(),
  isEnabled: bool('is_enabled', true),
  grantedScopes: text('granted_scopes'),
  lastSyncedAt: ts('last_synced_at'),
  lastSyncError: text('last_sync_error'),
  createdAt: tsNow('created_at'),
  updatedAt: tsNow('updated_at'),
}, (t) => [
  uniqueIndex('health_connections_uq').on(t.userId, t.platform),
]);

export const healthSyncCursors = sqliteTable('health_sync_cursors', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  userId: text('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  dataType: text('data_type').notNull(),
  lastRecordAt: integer('last_record_at').notNull(),
  updatedAt: tsNow('updated_at'),
}, (t) => [
  uniqueIndex('health_sync_cursors_uq').on(t.userId, t.dataType),
]);

export const dailyActivitySummaries = sqliteTable('daily_activity_summaries', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  userId: text('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  localDate: text('local_date').notNull(),
  steps: integer('steps'),
  activeCaloriesKcal: real('active_calories_kcal'),
  restingCaloriesKcal: real('resting_calories_kcal'),
  exerciseMinutes: integer('exercise_minutes'),
  avgRestingHr: integer('avg_resting_hr'),
  /** 1 when derived without a wearable. */
  isEstimated: bool('is_estimated', false),
  source: text('source', { enum: HEALTH_PLATFORMS }),
  createdAt: tsNow('created_at'),
  updatedAt: tsNow('updated_at'),
}, (t) => [
  uniqueIndex('daily_activity_uq').on(t.userId, t.localDate),
]);
