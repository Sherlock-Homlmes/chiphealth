/**
 * The maths behind the "Tiến trình" tab of the activity screen.
 *
 * Everything here is a pure function over rows the route already fetched, so
 * the whole tab is unit-testable without a D1 binding. The route layer does
 * the querying and the shaping; this file never touches the database.
 *
 * Weeks start on Monday and are keyed by the Monday's `YYYY-MM-DD`. Days come
 * from each session's `local_date`, which is the user's own calendar day —
 * that is why nothing here needs a timezone.
 */
import { addDays } from '../lib/time';

/* -------------------------------------------------------------------------- */
/* Sports                                                                      */
/* -------------------------------------------------------------------------- */

/**
 * The chip row is not a fixed three: it is "all" plus every activity the user
 * has actually recorded, busiest first. A catalogue of forty sports would be
 * unreadable, so the chips are built from the athlete's own history instead.
 */
export type SportFilter = string;
export const ALL_SPORTS = 'all';

/** Family a session belongs to — what the running-specific cards key off. */
export type Sport = 'run' | 'walk' | 'other';

const RUN_CODES = new Set(['running', 'trail_running', 'treadmill']);
const WALK_CODES = new Set(['walking', 'hiking', 'trekking']);

export function sportOf(activityCode: string | null | undefined): Sport {
  if (!activityCode) return 'other';
  if (RUN_CODES.has(activityCode)) return 'run';
  if (WALK_CODES.has(activityCode)) return 'walk';
  return 'other';
}

export function matchesSport(filter: SportFilter, activityCode: string): boolean {
  return filter === ALL_SPORTS || filter === activityCode;
}

export interface SportChip { code: string; sessions: number }

/**
 * The chips to offer, busiest first. Ties break on the code so the row does
 * not reshuffle between two equally used sports on every reload.
 */
export function sportChips(sessions: ProgressSession[]): SportChip[] {
  const counts = new Map<string, number>();
  for (const s of sessions) {
    counts.set(s.activityCode, (counts.get(s.activityCode) ?? 0) + 1);
  }
  return [...counts.entries()]
    .map(([code, n]) => ({ code, sessions: n }))
    .sort((a, b) => b.sessions - a.sessions || a.code.localeCompare(b.code));
}

/* -------------------------------------------------------------------------- */
/* Rows                                                                        */
/* -------------------------------------------------------------------------- */

/** One workout, reduced to what this tab draws. */
export interface ProgressSession {
  localDate: string;
  startedAt: number;
  activityCode: string;
  sport: Sport;
  /** Moving time where the recorder measured it, elapsed otherwise. */
  movingSeconds: number;
  distanceM: number;
  elevationGainM: number;
}

/* -------------------------------------------------------------------------- */
/* Weeks                                                                       */
/* -------------------------------------------------------------------------- */

/** The Monday of the week a date falls in. */
export function weekStartOf(isoDate: string): string {
  const [y, m, d] = isoDate.split('-').map(Number) as [number, number, number];
  // getUTCDay is 0 for Sunday; shift so Monday is 0.
  const weekday = (new Date(Date.UTC(y, m - 1, d)).getUTCDay() + 6) % 7;
  return addDays(isoDate, -weekday);
}

export interface WeekBucket {
  weekStart: string;
  weekEnd: string;
  distanceM: number;
  movingSeconds: number;
  elevationGainM: number;
  sessions: number;
}

const emptyWeek = (weekStart: string): WeekBucket => ({
  weekStart,
  weekEnd: addDays(weekStart, 6),
  distanceM: 0,
  movingSeconds: 0,
  elevationGainM: 0,
  sessions: 0,
});

/**
 * The last [weeks] Mondays, oldest first, ending with the week [today] is in.
 * A week with nothing in it still gets a bucket: the chart draws it at zero
 * rather than skipping the point, so the x axis stays evenly spaced.
 */
export function weekSeries(
  sessions: ProgressSession[], today: string, weeks = 12,
): WeekBucket[] {
  const current = weekStartOf(today);
  const buckets = new Map<string, WeekBucket>();
  for (let i = weeks - 1; i >= 0; i--) {
    const start = addDays(current, -7 * i);
    buckets.set(start, emptyWeek(start));
  }
  for (const s of sessions) {
    const bucket = buckets.get(weekStartOf(s.localDate));
    if (!bucket) continue;
    bucket.distanceM += s.distanceM;
    bucket.movingSeconds += s.movingSeconds;
    bucket.elevationGainM += s.elevationGainM;
    bucket.sessions += 1;
  }
  return [...buckets.values()];
}

/**
 * Consecutive weeks with at least one session, counted backwards. A current
 * week that is still empty does not break the streak — it has not happened
 * yet — so counting starts at the previous week in that case.
 */
export function streakWeeks(sessions: ProgressSession[], today: string): number {
  const active = new Set(sessions.map((s) => weekStartOf(s.localDate)));
  let week = weekStartOf(today);
  if (!active.has(week)) week = addDays(week, -7);
  let streak = 0;
  while (active.has(week)) {
    streak++;
    week = addDays(week, -7);
  }
  return streak;
}

export interface LogWeek {
  weekStart: string;
  /** Monday first. The current week stops at today; past weeks hold all 7. */
  days: Array<{ date: string; seconds: number }>;
  totalSeconds: number;
}

/** The two dot rows of the training-log card: this week so far, and last week. */
export function weekLog(
  sessions: ProgressSession[], today: string,
): { thisWeek: LogWeek; lastWeek: LogWeek } {
  const byDate = new Map<string, number>();
  for (const s of sessions) {
    byDate.set(s.localDate, (byDate.get(s.localDate) ?? 0) + s.movingSeconds);
  }
  const build = (weekStart: string, dayCount: number): LogWeek => {
    const days = [];
    for (let i = 0; i < dayCount; i++) {
      const date = addDays(weekStart, i);
      days.push({ date, seconds: byDate.get(date) ?? 0 });
    }
    return {
      weekStart,
      days,
      totalSeconds: days.reduce((sum, d) => sum + d.seconds, 0),
    };
  };
  const current = weekStartOf(today);
  const elapsed = Math.round(
    (Date.parse(`${today}T00:00:00Z`) - Date.parse(`${current}T00:00:00Z`)) / 86_400_000,
  ) + 1;
  return {
    thisWeek: build(current, Math.min(7, Math.max(1, elapsed))),
    lastWeek: build(addDays(current, -7), 7),
  };
}

/* -------------------------------------------------------------------------- */
/* Performance prediction                                                      */
/* -------------------------------------------------------------------------- */

/**
 * Riegel's endurance formula: a time over one distance predicts another.
 * The 1.06 exponent is the published constant and holds for efforts between
 * roughly 3 and 90 minutes, which is why very short efforts are filtered out
 * before this is called.
 */
export function riegelSeconds(seconds: number, fromM: number, toM: number): number {
  if (seconds <= 0 || fromM <= 0 || toM <= 0) return 0;
  return seconds * Math.pow(toM / fromM, 1.06);
}

export interface PredictionPoint { date: string; seconds: number }

export interface Prediction {
  distanceM: number;
  /** Best prediction at the end of the window, and at its start. */
  currentSeconds: number;
  baselineSeconds: number;
  /** Negative means faster, which is the improving direction. */
  deltaSeconds: number;
  series: PredictionPoint[];
}

/** Efforts shorter than this extrapolate badly, so they are left out. */
const MIN_PREDICTION_DISTANCE_M = 1500;

/**
 * Predicted time for [targetM] over the window, one point per day that had a
 * qualifying run. Each point is the best prediction *so far*, so the line can
 * only move in the improving direction — it is a personal best curve, not a
 * per-session scatter.
 */
export function predictionSeries(
  sessions: ProgressSession[], targetM = 5000,
): Prediction | null {
  const runs = sessions
    .filter((s) => s.sport === 'run'
      && s.distanceM >= MIN_PREDICTION_DISTANCE_M
      && s.movingSeconds > 0)
    .sort((a, b) => a.startedAt - b.startedAt);
  if (runs.length === 0) return null;

  const series: PredictionPoint[] = [];
  let best = Infinity;
  for (const run of runs) {
    const predicted = riegelSeconds(run.movingSeconds, run.distanceM, targetM);
    if (predicted <= 0) continue;
    best = Math.min(best, predicted);
    const rounded = Math.round(best);
    const last = series[series.length - 1];
    if (last && last.date === run.localDate) last.seconds = rounded;
    else series.push({ date: run.localDate, seconds: rounded });
  }
  if (series.length === 0) return null;

  const first = series[0]!.seconds;
  const current = series[series.length - 1]!.seconds;
  return {
    distanceM: targetM,
    currentSeconds: current,
    baselineSeconds: first,
    deltaSeconds: current - first,
    series,
  };
}

/* -------------------------------------------------------------------------- */
/* Heart-rate zones                                                            */
/* -------------------------------------------------------------------------- */

export interface ZoneSlice { zone: number; seconds: number; percent: number }

export interface ZoneBreakdown {
  totalSeconds: number;
  zones: ZoneSlice[];
  /** The zone with the most time, and how its share moved since last period. */
  topZone: number | null;
  topPercent: number;
  deltaPercent: number;
}

const ZONE_COUNT = 6;

/** Time-in-zone for the window, against the window before it. */
export function zoneBreakdown(
  current: Array<{ zone: number; seconds: number }>,
  previous: Array<{ zone: number; seconds: number }> = [],
): ZoneBreakdown {
  const fold = (rows: Array<{ zone: number; seconds: number }>) => {
    const out = new Array<number>(ZONE_COUNT).fill(0);
    for (const r of rows) {
      if (r.zone >= 1 && r.zone <= ZONE_COUNT) out[r.zone - 1] = out[r.zone - 1]! + r.seconds;
    }
    return out;
  };
  const now = fold(current);
  const before = fold(previous);
  const total = now.reduce((a, b) => a + b, 0);
  const beforeTotal = before.reduce((a, b) => a + b, 0);

  const zones: ZoneSlice[] = now.map((seconds, i) => ({
    zone: i + 1,
    seconds,
    percent: total > 0 ? Math.round((seconds / total) * 100) : 0,
  }));
  if (total === 0) {
    return { totalSeconds: 0, zones, topZone: null, topPercent: 0, deltaPercent: 0 };
  }
  const top = zones.reduce((a, b) => (b.seconds > a.seconds ? b : a));
  const beforePercent = beforeTotal > 0
    ? Math.round((before[top.zone - 1]! / beforeTotal) * 100)
    : 0;
  return {
    totalSeconds: total,
    zones,
    topZone: top.zone,
    topPercent: top.percent,
    deltaPercent: top.percent - beforePercent,
  };
}

/* -------------------------------------------------------------------------- */
/* Months                                                                      */
/* -------------------------------------------------------------------------- */

export const monthOf = (isoDate: string): string => isoDate.slice(0, 7);

export function previousMonth(month: string): string {
  const [y, m] = month.split('-').map(Number) as [number, number];
  return m === 1
    ? `${y - 1}-12`
    : `${y}-${String(m - 1).padStart(2, '0')}`;
}

export function daysInMonth(month: string): number {
  const [y, m] = month.split('-').map(Number) as [number, number];
  return new Date(Date.UTC(y, m, 0)).getUTCDate();
}

export interface MonthSeries {
  month: string;
  totalSeconds: number;
  /** Cumulative seconds after each day, day 1 first. */
  cumulativeSeconds: number[];
  /** Days the month has, even when the series stops earlier (current month). */
  daysInMonth: number;
}

/**
 * Time accumulated through the month, one step per day. [through] truncates
 * the series at today for the running month; a finished month passes nothing
 * and gets all of its days.
 */
export function monthSeries(
  sessions: ProgressSession[], month: string, through?: string,
): MonthSeries {
  const days = daysInMonth(month);
  const lastDay = through && monthOf(through) === month
    ? Number(through.slice(8, 10))
    : days;
  const perDay = new Array<number>(days).fill(0);
  for (const s of sessions) {
    if (monthOf(s.localDate) !== month) continue;
    const day = Number(s.localDate.slice(8, 10));
    if (day >= 1 && day <= days) perDay[day - 1] = perDay[day - 1]! + s.movingSeconds;
  }
  const cumulative: number[] = [];
  let running = 0;
  for (let i = 0; i < lastDay; i++) {
    running += perDay[i]!;
    cumulative.push(running);
  }
  return {
    month,
    totalSeconds: running,
    cumulativeSeconds: cumulative,
    daysInMonth: days,
  };
}

/* -------------------------------------------------------------------------- */
/* Suggested session                                                           */
/* -------------------------------------------------------------------------- */

/** The catalogue the "Buổi tập tức thì" card picks from. The app localizes it. */
export const SUGGESTION_CODES = [
  'first_run', 'recovery_run', 'base_run', 'tempo_run', 'long_run',
] as const;
export type SuggestionCode = typeof SUGGESTION_CODES[number];

export interface Suggestion {
  code: SuggestionCode;
  distanceM: number;
  /** Why this one came up, so the card is not an oracle. */
  reason: 'no_history' | 'recent_session' | 'building' | 'weekend' | 'midweek';
}

const round500 = (m: number) => Math.max(1000, Math.round(m / 500) * 500);
const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

/**
 * A next session sized from the last four weeks of running, not from a plan:
 * the app has no coach-set schedule, so the honest suggestion is a fraction of
 * what the runner is already doing.
 */
export function suggestWorkout(
  sessions: ProgressSession[], today: string,
): Suggestion {
  const runs = sessions.filter((s) => s.sport === 'run' && s.distanceM > 0);
  const fourWeeksAgo = addDays(today, -28);
  const recent = runs.filter((s) => s.localDate > fourWeeksAgo);
  if (recent.length === 0) {
    return { code: 'first_run', distanceM: 2000, reason: 'no_history' };
  }

  const weeklyM = recent.reduce((sum, s) => sum + s.distanceM, 0) / 4;
  const lastRun = recent.reduce((a, b) => (b.localDate > a.localDate ? b : a));
  const restedDays = Math.round(
    (Date.parse(`${today}T00:00:00Z`) - Date.parse(`${lastRun.localDate}T00:00:00Z`)) / 86_400_000,
  );
  if (restedDays <= 1) {
    return {
      code: 'recovery_run',
      distanceM: round500(clamp(weeklyM * 0.35, 2000, 8000)),
      reason: 'recent_session',
    };
  }
  if (weeklyM < 10_000) {
    return {
      code: 'base_run',
      distanceM: round500(clamp(weeklyM * 0.3, 2000, 6000)),
      reason: 'building',
    };
  }
  const [y, m, d] = today.split('-').map(Number) as [number, number, number];
  const isWeekend = [0, 6].includes(new Date(Date.UTC(y, m - 1, d)).getUTCDay());
  return isWeekend
    ? {
      code: 'long_run',
      distanceM: round500(clamp(weeklyM * 0.4, 6000, 25_000)),
      reason: 'weekend',
    }
    : {
      code: 'tempo_run',
      distanceM: round500(clamp(weeklyM * 0.25, 4000, 12_000)),
      reason: 'midweek',
    };
}
