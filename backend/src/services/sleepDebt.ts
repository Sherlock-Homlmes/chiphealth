import { and, eq, gte, lte } from 'drizzle-orm';
import { sleepSessions, sleepDebtDaily, userProfiles } from '../db/schema';
import { addDays, dateRange } from '../lib/time';
import type { Db } from '../db/client';
import type { Bindings } from '../env';

export const DEFAULT_WINDOW_DAYS = 14;
export const DEFAULT_TARGET_MINUTES = 480;

export function windowDays(env: Bindings): number {
  const n = Number(env.SLEEP_DEBT_WINDOW_DAYS);
  return Number.isFinite(n) && n > 0 ? n : DEFAULT_WINDOW_DAYS;
}

export interface DebtDay {
  localDate: string;
  targetSleepSeconds: number;
  actualSleepSeconds: number;
  dailyDiffSeconds: number;
  /** False when no night was recorded — unknown sleep, not zero sleep. */
  hasData: boolean;
}

/**
 * Sleep debt = the sum of SHORTFALLS inside the rolling window.
 *
 * Surplus nights deliberately do not repay debt: sleeping 10h on Sunday does not
 * undo four 5h weeknights, it only stops that Sunday adding more. Debt leaves the
 * total by ageing out of the window, not by being cancelled.
 *
 * Days with no recording are skipped entirely. Counting them as zero sleep would
 * charge a user 8h of debt for every day they simply did not wear/track anything,
 * which is how a brand-new account instantly "owes" a fortnight of sleep.
 */
export function rollingDebtSeconds(
  days: readonly DebtDay[], endDate: string, window: number,
): number {
  const startDate = addDays(endDate, -(window - 1));
  let debt = 0;
  for (const d of days) {
    if (!d.hasData) continue;
    if (d.localDate < startDate || d.localDate > endDate) continue;
    if (d.dailyDiffSeconds < 0) debt += -d.dailyDiffSeconds;
  }
  return debt;
}

async function targetSecondsFor(db: Db, userId: string): Promise<number> {
  const rows = await db.select({ minutes: userProfiles.targetSleepMinutes })
    .from(userProfiles).where(eq(userProfiles.userId, userId)).limit(1);
  return (rows[0]?.minutes ?? DEFAULT_TARGET_MINUTES) * 60;
}

/** Nightly totals for a date range, as a map keyed by the wake-up local date. */
async function actualsByDate(
  db: Db, userId: string, from: string, to: string,
): Promise<Map<string, number>> {
  const rows = await db.select({
    localDate: sleepSessions.localDate,
    total: sleepSessions.totalSleepSeconds,
  }).from(sleepSessions).where(and(
    eq(sleepSessions.userId, userId),
    gte(sleepSessions.localDate, from),
    lte(sleepSessions.localDate, to),
  ));
  const map = new Map<string, number>();
  for (const r of rows) map.set(r.localDate, r.total ?? 0);
  return map;
}

export interface SleepDebtResult {
  targetSeconds: number;
  windowDays: number;
  rollingDebtSeconds: number;
  /** How many nights in the window actually have data — context for the number. */
  daysRecorded: number;
  byDay: DebtDay[];
}

/** Read-only view for GET /v1/sleep/debt. */
export async function sleepDebtFor(
  db: Db, env: Bindings, userId: string, endDate: string,
): Promise<SleepDebtResult> {
  const window = windowDays(env);
  const startDate = addDays(endDate, -(window - 1));
  const [target, actuals] = await Promise.all([
    targetSecondsFor(db, userId),
    actualsByDate(db, userId, startDate, endDate),
  ]);

  const byDay: DebtDay[] = dateRange(startDate, endDate).map((localDate) => {
    const recorded = actuals.get(localDate);
    const actual = recorded ?? 0;
    return {
      localDate,
      targetSleepSeconds: target,
      actualSleepSeconds: actual,
      dailyDiffSeconds: actual - target,
      hasData: recorded !== undefined,
    };
  });

  return {
    targetSeconds: target,
    windowDays: window,
    rollingDebtSeconds: rollingDebtSeconds(byDay, endDate, window),
    daysRecorded: byDay.filter((d) => d.hasData).length,
    byDay,
  };
}

/**
 * Persists `sleep_debt_daily` for endDate. Called after every sleep write and by
 * the nightly cron. The row is an upsert on (user_id, local_date).
 */
export async function recomputeSleepDebt(
  db: Db, env: Bindings, userId: string, endDate: string,
): Promise<SleepDebtResult> {
  const result = await sleepDebtFor(db, env, userId, endDate);
  const today = result.byDay[result.byDay.length - 1];
  if (!today) return result;

  const now = Date.now();
  await db.insert(sleepDebtDaily).values({
    userId,
    localDate: today.localDate,
    targetSleepSeconds: today.targetSleepSeconds,
    actualSleepSeconds: today.actualSleepSeconds,
    dailyDiffSeconds: today.dailyDiffSeconds,
    rolling14dDebtSeconds: result.rollingDebtSeconds,
    createdAt: now,
    updatedAt: now,
  }).onConflictDoUpdate({
    target: [sleepDebtDaily.userId, sleepDebtDaily.localDate],
    set: {
      targetSleepSeconds: today.targetSleepSeconds,
      actualSleepSeconds: today.actualSleepSeconds,
      dailyDiffSeconds: today.dailyDiffSeconds,
      rolling14dDebtSeconds: result.rollingDebtSeconds,
      updatedAt: now,
    },
  });

  return result;
}
