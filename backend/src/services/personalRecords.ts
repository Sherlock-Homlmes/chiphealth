import { and, asc, eq, inArray, or } from 'drizzle-orm';
import { insertMany } from '../db/client';
import type { Db } from '../db/client';
import {
  personalRecords, workoutSessions, workoutSplits, workoutStrengthSets,
} from '../db/schema';
import { newId } from '../lib/ids';

export type PrMetric =
  | 'fastest_distance' | 'longest_distance' | 'longest_duration' | 'max_elevation_gain'
  | 'best_pace' | 'max_weight' | 'max_reps' | 'max_volume';

/** Distances scored for `fastest_distance`, in metres. */
export const PR_DISTANCES_M = [1000, 5000, 10000, 21097, 42195] as const;

/** Metrics where a SMALLER value is better. */
const LOWER_IS_BETTER: ReadonlySet<PrMetric> = new Set(['fastest_distance', 'best_pace']);

export const isBetter = (metric: PrMetric, candidate: number, current: number): boolean =>
  LOWER_IS_BETTER.has(metric) ? candidate < current : candidate > current;

export interface CumulativePoint { d: number; t: number }

/**
 * Fastest time to cover `targetM`, over a piecewise-linear cumulative
 * (distance, time) series — a rolling window, not just whole splits, so a 5k PR
 * set between the 1 km markers is still found.
 *
 * Within a segment the speed is constant, so the window duration is piecewise
 * linear in the window offset and its minimum sits on a breakpoint: either the
 * window END or its START is a node. Both families are scanned.
 */
export function fastestForDistance(
  points: readonly CumulativePoint[], targetM: number,
): number | null {
  if (points.length < 2 || targetM <= 0) return null;
  const last = points[points.length - 1]!;
  const first = points[0]!;
  if (last.d - first.d < targetM) return null;

  /** Elapsed time at an exact cumulative distance (linear interpolation). */
  const timeAt = (d: number): number | null => {
    if (d < first.d || d > last.d) return null;
    for (let i = 1; i < points.length; i++) {
      const a = points[i - 1]!;
      const b = points[i]!;
      if (d <= b.d) {
        const span = b.d - a.d;
        if (span <= 0) return b.t;
        return a.t + ((d - a.d) / span) * (b.t - a.t);
      }
    }
    return last.t;
  };

  let best: number | null = null;
  const consider = (v: number | null) => {
    if (v !== null && Number.isFinite(v) && v >= 0 && (best === null || v < best)) best = v;
  };

  for (const p of points) {
    // window ENDS at this node -> interpolated start
    const startT = timeAt(p.d - targetM);
    if (startT !== null) consider(p.t - startT);
    // window STARTS at this node -> interpolated end
    const endT = timeAt(p.d + targetM);
    if (endT !== null) consider(endT - p.t);
  }
  return best;
}

/**
 * Cumulative (distance, elapsed) nodes from stored splits.
 * `workout_splits.elapsed_seconds` is the duration OF that split, not a running total.
 */
export function cumulativeFromSplits(
  splits: readonly { splitIndex: number; splitDistanceM: number; elapsedSeconds: number }[],
  totalDistanceM?: number | null,
  totalDurationSeconds?: number | null,
): CumulativePoint[] {
  const ordered = splits.slice().sort((a, b) => a.splitIndex - b.splitIndex);
  const out: CumulativePoint[] = [{ d: 0, t: 0 }];
  let d = 0;
  let t = 0;
  for (const s of ordered) {
    d += s.splitDistanceM;
    t += s.elapsedSeconds;
    out.push({ d, t });
  }
  // Trailing partial kilometre, so a 21.097 km PR is reachable from 21 whole splits.
  if (
    totalDistanceM != null && totalDurationSeconds != null &&
    totalDistanceM > d && totalDurationSeconds > t
  ) {
    out.push({ d: totalDistanceM, t: totalDurationSeconds });
  }
  return out;
}

export interface PrCandidate {
  metric: PrMetric;
  value: number;
  unit: string;
  activityTypeId: number | null;
  exerciseId: number | null;
  distanceM: number | null;
  strengthSetId: number | null;
}

export interface StrengthSetLike {
  id: number;
  exerciseId: number;
  reps: number | null;
  weightKg: number | null;
  isWarmup: boolean;
}

export interface SessionLike {
  activityTypeId: number;
  distanceM: number | null;
  durationSeconds: number | null;
  movingSeconds: number | null;
  bestPaceSecPerKm: number | null;
  avgPaceSecPerKm: number | null;
  elevationGainM: number | null;
}

/** Everything a single session could have set, before comparing to the PR board. */
export function candidatesForSession(
  session: SessionLike,
  cumulative: readonly CumulativePoint[],
  sets: readonly StrengthSetLike[],
): PrCandidate[] {
  const out: PrCandidate[] = [];
  const at = session.activityTypeId;

  for (const dist of PR_DISTANCES_M) {
    const seconds = fastestForDistance(cumulative, dist);
    if (seconds !== null && seconds > 0) {
      out.push({
        metric: 'fastest_distance', value: Math.round(seconds * 10) / 10, unit: 's',
        activityTypeId: at, exerciseId: null, distanceM: dist, strengthSetId: null,
      });
    }
  }

  if (session.distanceM && session.distanceM > 0) {
    out.push({
      metric: 'longest_distance', value: session.distanceM, unit: 'm',
      activityTypeId: at, exerciseId: null, distanceM: null, strengthSetId: null,
    });
  }

  const duration = session.movingSeconds ?? session.durationSeconds;
  if (duration && duration > 0) {
    out.push({
      metric: 'longest_duration', value: duration, unit: 's',
      activityTypeId: at, exerciseId: null, distanceM: null, strengthSetId: null,
    });
  }

  const pace = session.bestPaceSecPerKm ?? session.avgPaceSecPerKm;
  if (pace && pace > 0) {
    out.push({
      metric: 'best_pace', value: pace, unit: 's/km',
      activityTypeId: at, exerciseId: null, distanceM: null, strengthSetId: null,
    });
  }

  if (session.elevationGainM && session.elevationGainM > 0) {
    out.push({
      metric: 'max_elevation_gain', value: session.elevationGainM, unit: 'm',
      activityTypeId: at, exerciseId: null, distanceM: null, strengthSetId: null,
    });
  }

  /* --- strength, scoped per exercise ------------------------------ */
  const working = sets.filter((s) => !s.isWarmup);
  const byExercise = new Map<number, StrengthSetLike[]>();
  for (const s of working) {
    const list = byExercise.get(s.exerciseId);
    if (list) list.push(s);
    else byExercise.set(s.exerciseId, [s]);
  }

  for (const [exerciseId, list] of byExercise) {
    let maxWeight: StrengthSetLike | null = null;
    let maxReps: StrengthSetLike | null = null;
    let volume = 0;
    for (const s of list) {
      if (s.weightKg != null && (maxWeight === null || s.weightKg > (maxWeight.weightKg ?? 0))) {
        maxWeight = s;
      }
      if (s.reps != null && (maxReps === null || s.reps > (maxReps.reps ?? 0))) maxReps = s;
      if (s.reps != null && s.weightKg != null) volume += s.reps * s.weightKg;
    }
    if (maxWeight?.weightKg) {
      out.push({
        metric: 'max_weight', value: maxWeight.weightKg, unit: 'kg',
        activityTypeId: null, exerciseId, distanceM: null, strengthSetId: maxWeight.id,
      });
    }
    if (maxReps?.reps) {
      out.push({
        metric: 'max_reps', value: maxReps.reps, unit: 'reps',
        activityTypeId: null, exerciseId, distanceM: null, strengthSetId: maxReps.id,
      });
    }
    if (volume > 0) {
      out.push({
        metric: 'max_volume', value: Math.round(volume * 10) / 10, unit: 'kg',
        activityTypeId: null, exerciseId, distanceM: null, strengthSetId: null,
      });
    }
  }

  return out;
}

const sameScope = (
  a: { metric: string; activityTypeId: number | null; exerciseId: number | null; distanceM: number | null },
  b: { metric: string; activityTypeId: number | null; exerciseId: number | null; distanceM: number | null },
) =>
  a.metric === b.metric &&
  a.activityTypeId === b.activityTypeId &&
  a.exerciseId === b.exerciseId &&
  a.distanceM === b.distanceM;

/**
 * Drops every record a workout set, and hands each board it emptied back to
 * the best record still standing.
 *
 * Deleting a workout has to take its records with it — a personal best set in
 * a session that never happened is not a best. But the older record it beat is
 * still sitting there with `is_current = 0`, and leaving it there would erase
 * the board instead of rolling it back, so whatever remains in that scope is
 * promoted.
 *
 * Strength records point at the set rather than the session, so they are found
 * through the session's sets — and they have to go either way, since nothing
 * cascades from personal_records and the session's sets are about to.
 */
export async function dropRecordsForSession(
  db: Db, userId: string, sessionId: string,
): Promise<number> {
  const setIds = (await db.select({ id: workoutStrengthSets.id })
    .from(workoutStrengthSets)
    .where(eq(workoutStrengthSets.workoutSessionId, sessionId)))
    .map((r) => r.id);

  const removed = await db.delete(personalRecords)
    .where(and(
      eq(personalRecords.userId, userId),
      setIds.length > 0
        ? or(
          eq(personalRecords.workoutSessionId, sessionId),
          inArray(personalRecords.strengthSetId, setIds),
        )
        : eq(personalRecords.workoutSessionId, sessionId),
    ))
    .returning({
      metric: personalRecords.metric,
      activityTypeId: personalRecords.activityTypeId,
      exerciseId: personalRecords.exerciseId,
      distanceM: personalRecords.distanceM,
      isCurrent: personalRecords.isCurrent,
    });

  // Only a board that just lost its holder needs a new one.
  const emptied = removed.filter((r) => r.isCurrent);
  if (emptied.length === 0) return removed.length;

  const survivors = await db.select().from(personalRecords)
    .where(eq(personalRecords.userId, userId));

  for (const scope of emptied) {
    const inScope = survivors.filter((r) => sameScope(r, scope));
    if (inScope.length === 0) continue;
    const best = inScope.reduce((a, b) =>
      isBetter(scope.metric, b.value, a.value) ? b : a);
    await db.update(personalRecords).set({ isCurrent: true })
      .where(eq(personalRecords.id, best.id));
  }

  return removed.length;
}

export interface DetectedPr {
  id: string;
  metric: PrMetric;
  value: number;
  unit: string;
  previousValue: number | null;
  distanceM: number | null;
  exerciseId: number | null;
  activityTypeId: number | null;
  achievedAt: number;
}

/**
 * Compares one session against the caller's current PR board. A beaten record is
 * flipped to `is_current = 0` and the new row records `previous_value`.
 */
export async function detectPersonalRecords(
  db: Db, userId: string, sessionId: string,
): Promise<DetectedPr[]> {
  const session = await db.query.workoutSessions.findFirst({
    where: and(eq(workoutSessions.id, sessionId), eq(workoutSessions.userId, userId)),
  });
  if (!session || session.isDeleted) return [];

  const splits = await db.select().from(workoutSplits)
    .where(eq(workoutSplits.workoutSessionId, sessionId))
    .orderBy(asc(workoutSplits.splitIndex));

  const sets = await db.select().from(workoutStrengthSets)
    .where(eq(workoutStrengthSets.workoutSessionId, sessionId));

  const cumulative = cumulativeFromSplits(
    splits, session.distanceM, session.movingSeconds ?? session.durationSeconds,
  );
  const candidates = candidatesForSession(session, cumulative, sets);
  if (candidates.length === 0) return [];

  const current = await db.select().from(personalRecords)
    .where(and(eq(personalRecords.userId, userId), eq(personalRecords.isCurrent, true)));

  const now = Date.now();
  const achievedAt = session.endedAt ?? session.startedAt;
  const beaten: number[] = [];
  const inserts: (typeof personalRecords.$inferInsert)[] = [];
  const detected: DetectedPr[] = [];

  for (const cand of candidates) {
    const existing = current.find((r) => sameScope(r, cand));
    if (existing && !isBetter(cand.metric, cand.value, existing.value)) continue;
    if (existing) beaten.push(existing.id as unknown as number);

    const id = newId();
    detected.push({
      id,
      metric: cand.metric,
      value: cand.value,
      unit: cand.unit,
      previousValue: existing?.value ?? null,
      distanceM: cand.distanceM,
      exerciseId: cand.exerciseId,
      activityTypeId: cand.activityTypeId,
      achievedAt,
    });
    inserts.push({
      id,
      userId,
      activityTypeId: cand.activityTypeId,
      exerciseId: cand.exerciseId,
      metric: cand.metric,
      distanceM: cand.distanceM,
      value: cand.value,
      unit: cand.unit,
      achievedAt,
      // Exactly one source id is set: a strength PR points at the set, the rest
      // at the session.
      workoutSessionId: cand.strengthSetId === null ? sessionId : null,
      strengthSetId: cand.strengthSetId,
      previousValue: existing?.value ?? null,
      isCurrent: true,
      createdAt: now,
    });
  }

  if (inserts.length === 0) return [];

  const beatenIds = current.filter((r) => detected.some((d) => sameScope(r, d))).map((r) => r.id);
  if (beatenIds.length) {
    await db.update(personalRecords).set({ isCurrent: false })
      .where(inArray(personalRecords.id, beatenIds));
  }
  await insertMany((chunk) => db.insert(personalRecords).values(chunk), inserts);
  return detected;
}
