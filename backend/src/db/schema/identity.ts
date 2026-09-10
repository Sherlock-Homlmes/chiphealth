import { sqliteTable, text, integer, real, index, uniqueIndex, check } from 'drizzle-orm/sqlite-core';
import { sql } from 'drizzle-orm';
import { pkUuid, ts, tsNow, bool } from './_shared';
import { users } from './core';

export const SEXES = ['male', 'female'] as const;
export const ACTIVITY_LEVELS = ['sedentary', 'light', 'moderate', 'active', 'very_active'] as const;
export const GOAL_TYPES = [
  'lose_weight', 'gain_weight', 'gain_muscle', 'reduce_body_fat',
  'improve_endurance', 'improve_strength', 'sleep_better', 'manage_condition',
] as const;
export const GOAL_STATUSES = ['active', 'completed', 'abandoned'] as const;
export const BODY_METRIC_SOURCES = ['manual', 'health_sync', 'estimated'] as const;
export const ACTIVITY_CATEGORIES = [
  'cardio_gps', 'cardio_indoor', 'strength', 'sport', 'mind_body', 'other',
] as const;

export const userProfiles = sqliteTable('user_profiles', {
  userId: text('user_id').primaryKey().references(() => users.id, { onDelete: 'cascade' }),
  dateOfBirth: text('date_of_birth'),
  biologicalSex: text('biological_sex', { enum: SEXES }),
  activityLevel: text('activity_level', { enum: ACTIVITY_LEVELS }).notNull().default('moderate'),
  maxHeartRateOverride: integer('max_heart_rate_override'),
  restingHeartRate: integer('resting_heart_rate'),
  lactateThresholdHr: integer('lactate_threshold_hr'),
  targetSleepMinutes: integer('target_sleep_minutes').notNull().default(480),
  bedtimeTarget: text('bedtime_target'),
  waketimeTarget: text('waketime_target'),
  onboardingCompletedAt: ts('onboarding_completed_at'),
  createdAt: tsNow('created_at'),
  updatedAt: tsNow('updated_at'),
}, (t) => [
  check('user_profiles_sex_ck', sql`${t.biologicalSex} is null or ${t.biologicalSex} in ('male','female')`),
  check('user_profiles_activity_ck',
    sql`${t.activityLevel} in ('sedentary','light','moderate','active','very_active')`),
]);

export const chronicConditions = sqliteTable('chronic_conditions', {
  id: pkUuid(),
  userId: text('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  /** Free text by design — no coded vocabulary in v1. */
  description: text('description').notNull(),
  diagnosedOn: text('diagnosed_on'),
  notes: text('notes'),
  isActive: bool('is_active', true),
  createdAt: tsNow('created_at'),
  updatedAt: tsNow('updated_at'),
}, (t) => [
  index('chronic_conditions_user_active_idx').on(t.userId, t.isActive),
]);

export const bodyMetricsLogs = sqliteTable('body_metrics_logs', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  userId: text('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  recordedAt: integer('recorded_at').notNull(),
  localDate: text('local_date').notNull(),
  weightKg: real('weight_kg'),
  heightCm: real('height_cm'),
  bodyFatPercent: real('body_fat_percent'),
  muscleMassKg: real('muscle_mass_kg'),
  waistCm: real('waist_cm'),
  source: text('source', { enum: BODY_METRIC_SOURCES }).notNull().default('manual'),
  createdAt: tsNow('created_at'),
}, (t) => [
  index('body_metrics_user_recorded_idx').on(t.userId, t.recordedAt),
]);

export const goals = sqliteTable('goals', {
  id: pkUuid(),
  userId: text('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  goalType: text('goal_type', { enum: GOAL_TYPES }).notNull(),
  targetValue: real('target_value'),
  targetUnit: text('target_unit'),
  /** Baseline at creation, so progress % is computable later. */
  startValue: real('start_value').notNull(),
  deadline: text('deadline'),
  priority: integer('priority').notNull().default(0),
  status: text('status', { enum: GOAL_STATUSES }).notNull().default('active'),
  completedAt: ts('completed_at'),
  createdAt: tsNow('created_at'),
  updatedAt: tsNow('updated_at'),
}, (t) => [
  index('goals_user_status_idx').on(t.userId, t.status),
  check('goals_status_ck', sql`${t.status} in ('active','completed','abandoned')`),
]);

export const activityTypes = sqliteTable('activity_types', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  code: text('code').notNull().unique(),
  category: text('category', { enum: ACTIVITY_CATEGORIES }).notNull(),
  /** MET value, used to estimate calories when no HR data exists. */
  defaultMet: real('default_met').notNull(),
  supportsGps: bool('supports_gps', false),
  supportsSets: bool('supports_sets', false),
  supportsHeartRate: bool('supports_heart_rate', true),
  iconName: text('icon_name'),
  sortOrder: integer('sort_order').notNull().default(0),
  isActive: bool('is_active', true),
});

export const userActivityPreferences = sqliteTable('user_activity_preferences', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  userId: text('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  activityTypeId: integer('activity_type_id').notNull().references(() => activityTypes.id),
  skillLevel: text('skill_level'),
  weeklyTargetSessions: integer('weekly_target_sessions'),
  createdAt: tsNow('created_at'),
}, (t) => [
  uniqueIndex('user_activity_pref_uq').on(t.userId, t.activityTypeId),
]);

export const translations = sqliteTable('translations', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  entityType: text('entity_type').notNull(),
  entityId: text('entity_id').notNull(),
  locale: text('locale').notNull(),
  field: text('field').notNull(),
  value: text('value').notNull(),
}, (t) => [
  uniqueIndex('translations_uq').on(t.entityType, t.entityId, t.locale, t.field),
]);
