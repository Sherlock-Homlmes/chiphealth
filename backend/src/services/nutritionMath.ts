import { and, desc, eq, isNotNull, sql } from 'drizzle-orm';
import {
  bodyMetricsLogs,
  dailyNutritionSummaries,
  mealLogs,
  userProfiles,
  workoutSessions,
} from '../db/schema';
import { ageFromDob } from '../lib/time';
import type { Db } from '../db/client';
import type { Bindings } from '../env';

/* -------------------------------------------------------------------------- */
/* Pure math — no I/O, unit-testable                                           */
/* -------------------------------------------------------------------------- */

export type ActivityLevel = 'sedentary' | 'light' | 'moderate' | 'active' | 'very_active';
export type BiologicalSex = 'male' | 'female';

/** TDEE = BMR x one of these. Mirrors activity_level_enum in db_design.dbml. */
export const ACTIVITY_MULTIPLIERS: Record<ActivityLevel, number> = {
  sedentary: 1.2,
  light: 1.375,
  moderate: 1.55,
  active: 1.725,
  very_active: 1.9,
};

export const DEFAULT_ACTIVITY_LEVEL: ActivityLevel = 'moderate';

export function activityMultiplier(level: ActivityLevel | null | undefined): number {
  if (!level) return ACTIVITY_MULTIPLIERS[DEFAULT_ACTIVITY_LEVEL];
  const m = ACTIVITY_MULTIPLIERS[level];
  return m ?? ACTIVITY_MULTIPLIERS[DEFAULT_ACTIVITY_LEVEL];
}

export interface BmrInput {
  weightKg: number;
  heightCm: number;
  /** whole years */
  age: number;
  sex: BiologicalSex;
}

/**
 * Mifflin-St Jeor: 10*kg + 6.25*cm - 5*age + (male ? +5 : -161).
 * Returns kcal/day. Throws on non-finite input rather than silently emitting NaN.
 */
export function bmrMifflinStJeor(input: BmrInput): number {
  const { weightKg, heightCm, age, sex } = input;
  if (!Number.isFinite(weightKg) || !Number.isFinite(heightCm) || !Number.isFinite(age)) {
    throw new TypeError('bmrMifflinStJeor: weightKg, heightCm and age must be finite numbers');
  }
  return 10 * weightKg + 6.25 * heightCm - 5 * age + (sex === 'male' ? 5 : -161);
}

/** TDEE = BMR x activity multiplier + that day's workout calories. */
export function tdee(
  bmrKcal: number,
  level: ActivityLevel | null | undefined,
  workoutKcal = 0,
): number {
  return bmrKcal * activityMultiplier(level) + (Number.isFinite(workoutKcal) ? workoutKcal : 0);
}

export const round1 = (n: number): number => Math.round(n * 10) / 10;

/* -------------------------------------------------------------------------- */
/* Inputs loaded from the DB                                                   */
/* -------------------------------------------------------------------------- */

export interface TdeeInputs {
  weightKg: number | null;
  weightRecordedAt: number | null;
  heightCm: number | null;
  heightRecordedAt: number | null;
  dateOfBirth: string | null;
  age: number | null;
  sex: BiologicalSex | null;
  activityLevel: ActivityLevel;
  activityMultiplier: number;
}

/**
 * Weight and height are NOT stored on the profile — they are the most recent
 * non-null value in body_metrics_logs, and the two may come from different rows
 * (people re-weigh far more often than they re-measure their height).
 */
export async function loadTdeeInputs(db: Db, userId: string): Promise<TdeeInputs> {
  const [profileRows, weightRows, heightRows] = await Promise.all([
    db.select({
      dateOfBirth: userProfiles.dateOfBirth,
      biologicalSex: userProfiles.biologicalSex,
      activityLevel: userProfiles.activityLevel,
    }).from(userProfiles).where(eq(userProfiles.userId, userId)).limit(1),
    db.select({ value: bodyMetricsLogs.weightKg, recordedAt: bodyMetricsLogs.recordedAt })
      .from(bodyMetricsLogs)
      .where(and(eq(bodyMetricsLogs.userId, userId), isNotNull(bodyMetricsLogs.weightKg)))
      .orderBy(desc(bodyMetricsLogs.recordedAt))
      .limit(1),
    db.select({ value: bodyMetricsLogs.heightCm, recordedAt: bodyMetricsLogs.recordedAt })
      .from(bodyMetricsLogs)
      .where(and(eq(bodyMetricsLogs.userId, userId), isNotNull(bodyMetricsLogs.heightCm)))
      .orderBy(desc(bodyMetricsLogs.recordedAt))
      .limit(1),
  ]);

  const profile = profileRows[0];
  const weight = weightRows[0];
  const height = heightRows[0];
  const dateOfBirth = profile?.dateOfBirth ?? null;
  const activityLevel = (profile?.activityLevel ?? DEFAULT_ACTIVITY_LEVEL) as ActivityLevel;

  return {
    weightKg: weight?.value ?? null,
    weightRecordedAt: weight?.recordedAt ?? null,
    heightCm: height?.value ?? null,
    heightRecordedAt: height?.recordedAt ?? null,
    dateOfBirth,
    age: dateOfBirth ? ageFromDob(dateOfBirth) : null,
    sex: (profile?.biologicalSex ?? null) as BiologicalSex | null,
    activityLevel,
    activityMultiplier: activityMultiplier(activityLevel),
  };
}

export interface BmrTdeeResult {
  bmrKcal: number | null;
  tdeeKcal: number | null;
  /** Which inputs are missing, so the app can prompt for them. */
  missing: string[];
}

/** Null-safe wrapper: returns nulls (never NaN) when an input is unknown. */
export function computeBmrTdee(inputs: TdeeInputs, workoutKcal = 0): BmrTdeeResult {
  const missing: string[] = [];
  if (inputs.weightKg == null) missing.push('weightKg');
  if (inputs.heightCm == null) missing.push('heightCm');
  if (inputs.age == null) missing.push('dateOfBirth');
  if (inputs.sex == null) missing.push('biologicalSex');
  if (missing.length > 0) return { bmrKcal: null, tdeeKcal: null, missing };

  const bmrKcal = bmrMifflinStJeor({
    weightKg: inputs.weightKg as number,
    heightCm: inputs.heightCm as number,
    age: inputs.age as number,
    sex: inputs.sex as BiologicalSex,
  });
  return {
    bmrKcal: round1(bmrKcal),
    tdeeKcal: round1(tdee(bmrKcal, inputs.activityLevel, workoutKcal)),
    missing,
  };
}

/* -------------------------------------------------------------------------- */
/* Daily rollup                                                                */
/* -------------------------------------------------------------------------- */

export interface DailyNutritionRollup {
  userId: string;
  localDate: string;
  caloriesConsumedKcal: number;
  proteinG: number;
  carbsG: number;
  fatG: number;
  fiberG: number;
  sugarG: number;
  sodiumMg: number;
  caloriesBurnedWorkoutKcal: number;
  bmrKcal: number | null;
  tdeeKcal: number | null;
  calorieBalanceKcal: number | null;
  mealsLogged: number;
}

const num = (v: unknown): number => {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
};

/**
 * Sums the day's meal_logs, adds the day's workout calories, recomputes BMR/TDEE
 * from the profile + latest body metrics, and upserts daily_nutrition_summaries
 * (unique on user_id + local_date).
 *
 * `localDate` must already have been derived from a timestamp + the user's
 * timezone by the caller — never taken from client input.
 */
export async function recomputeDailyNutritionSummary(
  db: Db,
  _env: Bindings,
  userId: string,
  localDate: string,
): Promise<DailyNutritionRollup> {
  const [mealRows, workoutRows, inputs] = await Promise.all([
    db.select({
      calories: sql<number>`coalesce(sum(${mealLogs.totalCaloriesKcal}), 0)`,
      protein: sql<number>`coalesce(sum(${mealLogs.totalProteinG}), 0)`,
      carbs: sql<number>`coalesce(sum(${mealLogs.totalCarbsG}), 0)`,
      fat: sql<number>`coalesce(sum(${mealLogs.totalFatG}), 0)`,
      fiber: sql<number>`coalesce(sum(${mealLogs.totalFiberG}), 0)`,
      sugar: sql<number>`coalesce(sum(${mealLogs.totalSugarG}), 0)`,
      sodium: sql<number>`coalesce(sum(${mealLogs.totalSodiumMg}), 0)`,
      meals: sql<number>`count(*)`,
    }).from(mealLogs)
      .where(and(eq(mealLogs.userId, userId), eq(mealLogs.localDate, localDate))),
    db.select({
      burned: sql<number>`coalesce(sum(${workoutSessions.caloriesBurnedKcal}), 0)`,
    }).from(workoutSessions)
      .where(and(
        eq(workoutSessions.userId, userId),
        eq(workoutSessions.localDate, localDate),
        eq(workoutSessions.isDeleted, false),
      )),
    loadTdeeInputs(db, userId),
  ]);

  const meal = mealRows[0];
  const workoutKcal = num(workoutRows[0]?.burned);
  const { bmrKcal, tdeeKcal } = computeBmrTdee(inputs, workoutKcal);

  const rollup: DailyNutritionRollup = {
    userId,
    localDate,
    caloriesConsumedKcal: round1(num(meal?.calories)),
    proteinG: round1(num(meal?.protein)),
    carbsG: round1(num(meal?.carbs)),
    fatG: round1(num(meal?.fat)),
    fiberG: round1(num(meal?.fiber)),
    sugarG: round1(num(meal?.sugar)),
    sodiumMg: round1(num(meal?.sodium)),
    caloriesBurnedWorkoutKcal: round1(workoutKcal),
    bmrKcal,
    tdeeKcal,
    calorieBalanceKcal: tdeeKcal == null ? null : round1(num(meal?.calories) - tdeeKcal),
    mealsLogged: num(meal?.meals),
  };

  const now = Date.now();
  await db.insert(dailyNutritionSummaries)
    .values({
      userId: rollup.userId,
      localDate: rollup.localDate,
      caloriesConsumedKcal: rollup.caloriesConsumedKcal,
      proteinG: rollup.proteinG,
      carbsG: rollup.carbsG,
      fatG: rollup.fatG,
      fiberG: rollup.fiberG,
      sugarG: rollup.sugarG,
      sodiumMg: rollup.sodiumMg,
      bmrKcal: rollup.bmrKcal,
      tdeeKcal: rollup.tdeeKcal,
      caloriesBurnedWorkoutKcal: rollup.caloriesBurnedWorkoutKcal,
      calorieBalanceKcal: rollup.calorieBalanceKcal,
      mealsLogged: rollup.mealsLogged,
      createdAt: now,
      updatedAt: now,
    })
    .onConflictDoUpdate({
      target: [dailyNutritionSummaries.userId, dailyNutritionSummaries.localDate],
      set: {
        caloriesConsumedKcal: rollup.caloriesConsumedKcal,
        proteinG: rollup.proteinG,
        carbsG: rollup.carbsG,
        fatG: rollup.fatG,
        fiberG: rollup.fiberG,
        sugarG: rollup.sugarG,
        sodiumMg: rollup.sodiumMg,
        bmrKcal: rollup.bmrKcal,
        tdeeKcal: rollup.tdeeKcal,
        caloriesBurnedWorkoutKcal: rollup.caloriesBurnedWorkoutKcal,
        calorieBalanceKcal: rollup.calorieBalanceKcal,
        mealsLogged: rollup.mealsLogged,
        updatedAt: now,
      },
    });

  return rollup;
}
