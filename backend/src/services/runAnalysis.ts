import { and, eq, gte, sql } from 'drizzle-orm';
import { insertMany } from '../db/client';
import type { Db } from '../db/client';
import {
  BEST_EFFORT_DISTANCES_M, PREDICTED_DISTANCES_M,
  racePredictions, workoutBestEfforts, workoutSessions, workoutZoneSummaries,
} from '../db/schema';
import type { NormalisedSample } from './workoutStream';

/* ------------------------------------------------------------------ */
/* Grade adjusted pace                                                 */
/* ------------------------------------------------------------------ */

/**
 * The steepest gradient the cost curve is allowed to see. Minetti's polynomial
 * is fitted to -45%..+45%, but a road run does not contain a 45% grade: what
 * produces one is bad altitude data, and the curve is steep enough out there
 * that a single bad segment would dominate the average. Clamping at a quarter
 * keeps every real hill and throws away only the impossible ones. It is a
 * constant rather than a literal because this is an approximation that may want
 * tuning against real runs.
 */
export const MAX_GRADE = 0.25;

/**
 * Minetti's measured cost of running on a gradient, in J/kg/m. On the flat it
 * is 3.6; at +10% it is roughly double. Downhill it dips below 3.6 — free speed
 * — and then climbs again as braking starts to cost more than it saves.
 */
export function runningCost(grade: number): number {
  const i = Math.max(-MAX_GRADE, Math.min(MAX_GRADE, grade));
  return 155.4 * i ** 5 - 30.4 * i ** 4 - 43.3 * i ** 3 + 46.3 * i ** 2 + 19.5 * i + 3.6;
}

/** Flat-equivalent speed multiplier for a gradient: cost(i) / cost(0). */
export const gradeFactor = (grade: number): number => runningCost(grade) / 3.6;

/**
 * Grade adjusted pace for one stretch of road: the pace the same effort would
 * have produced on the flat. Uphill costs more, so the flat-equivalent pace is
 * FASTER than the pace actually run — hence the division.
 */
export const gradeAdjustedPace = (paceSecPerKm: number, grade: number): number =>
  paceSecPerKm / gradeFactor(grade);

/** A stretch of the run between two samples, already reduced to what GAP needs. */
export interface Segment {
  /** Cumulative metres at the END of the segment. */
  d: number;
  /** Seconds the segment took, standing still excluded. */
  dt: number;
  /** Metres covered. */
  dd: number;
  /** Elevation change over the segment, in metres; null when unknown. */
  dEle: number | null;
}

/**
 * Segments long enough to carry a believable gradient AND a believable pace.
 *
 * GPS elevation wobbles by a metre or two between consecutive samples, which
 * over 5 m of road reads as a 40% climb. The altitude reaching this point has
 * already been smoothed (`smoothElevations`), but a gradient divides by the
 * distance and so stays sensitive to whatever is left. Time is just as coarse:
 * a sample clock
 * ticking in whole seconds puts a 10% error on any stretch covered in ten of
 * them. At 100 m both settle down — roughly half a minute of running per
 * segment — which is fine enough for the charts and for time-in-zone without
 * being fine enough to be noise. A shorter remainder at the end is dropped.
 */
export const MIN_SEGMENT_M = 100;

export function segmentsFromSamples(samples: readonly NormalisedSample[]): Segment[] {
  const out: Segment[] = [];
  let dd = 0;
  let dt = 0;
  let dEle: number | null = null;
  let anchorEle: number | null = null;

  for (let i = 1; i < samples.length; i++) {
    const prev = samples[i - 1]!;
    const cur = samples[i]!;
    if (anchorEle === null) anchorEle = prev.ele;
    dd += Math.max(0, cur.d - prev.d);
    // Moving time, not wall clock: a light the runner waited at did not make
    // the hill harder, and GAP is a statement about effort. It also keeps the
    // average honest — GAP over the run is moving time divided by the
    // flat-equivalent distance, which is what the screen calls "GAP TB".
    if (cur.moving) dt += Math.max(0, cur.t - prev.t);
    if (dd < MIN_SEGMENT_M) continue;

    dEle = anchorEle !== null && cur.ele !== null ? cur.ele - anchorEle : null;
    if (dt > 0) out.push({ d: cur.d, dt, dd, dEle });
    dd = 0;
    dt = 0;
    anchorEle = cur.ele;
  }
  return out;
}

export interface GapSummary {
  /** Average grade adjusted pace over the run, sec/km. */
  avgGapSecPerKm: number | null;
  /** Per-segment GAP, for the chart: cumulative metres -> sec/km. */
  series: { d: number; gap: number }[];
}

/**
 * GAP is averaged as total flat-equivalent time over total distance, not as the
 * mean of the per-segment paces: a slow segment lasts longer and must weigh
 * more, exactly as it does for ordinary average pace.
 */
export function gapFromSegments(segments: readonly Segment[]): GapSummary {
  const series: { d: number; gap: number }[] = [];
  let flatSeconds = 0;
  let metres = 0;

  for (const seg of segments) {
    if (seg.dd <= 0 || seg.dt <= 0) continue;
    const pace = (seg.dt / seg.dd) * 1000;
    // Without elevation the segment is its own flat equivalent.
    const grade = seg.dEle === null ? 0 : seg.dEle / seg.dd;
    const gap = gradeAdjustedPace(pace, grade);
    // Same noise floor the totals use: nothing under 2:00/km is a real pace.
    if (gap < 120 || gap > 3600) continue;
    series.push({ d: Math.round(seg.d), gap: Math.round(gap) });
    flatSeconds += (gap / 1000) * seg.dd;
    metres += seg.dd;
  }

  return {
    avgGapSecPerKm: metres > 0 ? Math.round((flatSeconds / metres) * 1000) : null,
    series,
  };
}

/* ------------------------------------------------------------------ */
/* Best efforts                                                        */
/* ------------------------------------------------------------------ */

export interface CumulativePoint { d: number; t: number }

export interface EffortWindow {
  seconds: number;
  startDistanceM: number;
  endDistanceM: number;
}

/**
 * The fastest stretch of exactly `targetM` metres, and where on the route it
 * was. Same rolling window as `fastestForDistance` in personalRecords.ts — the
 * minimum sits on a breakpoint, so both the window-ends-here and the
 * window-starts-here families are scanned — but this one keeps the position,
 * which is what pins the medal to the map.
 */
export function fastestWindow(
  points: readonly CumulativePoint[], targetM: number,
): EffortWindow | null {
  if (points.length < 2 || targetM <= 0) return null;
  const first = points[0]!;
  const last = points[points.length - 1]!;
  if (last.d - first.d < targetM) return null;

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

  let best: EffortWindow | null = null;
  const consider = (seconds: number | null, startM: number, endM: number) => {
    if (seconds === null || !Number.isFinite(seconds) || seconds <= 0) return;
    if (best === null || seconds < best.seconds) {
      best = { seconds, startDistanceM: startM, endDistanceM: endM };
    }
  };

  for (const p of points) {
    const startD = p.d - targetM;
    const startT = timeAt(startD);
    if (startT !== null) consider(p.t - startT, startD, p.d);
    const endD = p.d + targetM;
    const endT = timeAt(endD);
    if (endT !== null) consider(endT - p.t, p.d, endD);
  }
  return best;
}

export interface RunEffort extends EffortWindow { distanceM: number }

/** Every standard distance this run covered, with its fastest stretch. */
export function effortsForRun(points: readonly CumulativePoint[]): RunEffort[] {
  const out: RunEffort[] = [];
  for (const distanceM of BEST_EFFORT_DISTANCES_M) {
    const win = fastestWindow(points, distanceM);
    if (win) out.push({ distanceM, ...win });
  }
  return out;
}

/* ------------------------------------------------------------------ */
/* Race predictions                                                    */
/* ------------------------------------------------------------------ */

/** Riegel's exponent: the cost of doubling the distance, fitted on road races. */
export const RIEGEL_EXPONENT = 1.06;

export const riegel = (seconds: number, fromM: number, toM: number): number =>
  seconds * (toM / fromM) ** RIEGEL_EXPONENT;

/**
 * Predicted finishing time from the athlete's board of best efforts.
 *
 * Riegel is only honest near the distance it extrapolates from, so an anchor
 * has to be within a quarter and four times the target — a 400 m sprint says
 * nothing useful about a marathon — and among the anchors that qualify, the
 * one CLOSEST to the target wins rather than the one that flatters the athlete
 * most. Extrapolation error grows with the ratio, so a real 10 km beats a 5 km
 * doubled even when doubling the 5 km would predict something faster; the
 * board each anchor comes from already holds the athlete's best at that
 * distance, so an easy long run never drags a prediction down.
 */
export function predictFromEfforts(
  efforts: readonly { distanceM: number; seconds: number }[], targetM: number,
): number | null {
  let best: { predicted: number; ratio: number } | null = null;
  for (const e of efforts) {
    if (e.seconds <= 0 || e.distanceM <= 0) continue;
    if (e.distanceM < targetM / 4 || e.distanceM > targetM * 4) continue;
    const ratio = Math.abs(Math.log(e.distanceM / targetM));
    const predicted = riegel(e.seconds, e.distanceM, targetM);
    // Equally close anchors (a target between two standard distances) are
    // settled by the faster one.
    if (best === null || ratio < best.ratio
      || (ratio === best.ratio && predicted < best.predicted)) {
      best = { predicted, ratio };
    }
  }
  return best === null ? null : Math.round(best.predicted);
}

/* ------------------------------------------------------------------ */
/* Pace zones                                                          */
/* ------------------------------------------------------------------ */

export interface PaceZoneRange {
  zoneNumber: number;
  /** Inclusive lower bound in sec/km; null on Z6, which has no floor. */
  minSecPerKm: number | null;
  /** Exclusive upper bound in sec/km; null on Z1, which has no ceiling. */
  maxSecPerKm: number | null;
}

/**
 * Zone boundaries as a fraction of threshold SPEED, fastest zone first. A pace
 * in sec/km is the reciprocal, so the fractions are divided into the threshold
 * pace rather than multiplied by it.
 */
export const PACE_ZONE_SPEED_FRACTIONS = [1.14, 1.07, 1.0, 0.89, 0.77] as const;

/**
 * Six pace zones anchored on the predicted 5 km pace, which is the closest the
 * app can get to threshold effort without a lab test: a 5 km race is run at
 * roughly the pace that can be held for an hour's hard work.
 */
export function paceZoneRanges(fiveKSeconds: number): PaceZoneRange[] {
  const threshold = (fiveKSeconds / 5000) * 1000;
  const bounds = PACE_ZONE_SPEED_FRACTIONS.map((f) => Math.round(threshold / f));
  // bounds[0] is the Z6/Z5 edge (fastest), bounds[4] the Z2/Z1 edge (slowest).
  return [
    { zoneNumber: 6, minSecPerKm: null, maxSecPerKm: bounds[0]! },
    { zoneNumber: 5, minSecPerKm: bounds[0]!, maxSecPerKm: bounds[1]! },
    { zoneNumber: 4, minSecPerKm: bounds[1]!, maxSecPerKm: bounds[2]! },
    { zoneNumber: 3, minSecPerKm: bounds[2]!, maxSecPerKm: bounds[3]! },
    { zoneNumber: 2, minSecPerKm: bounds[3]!, maxSecPerKm: bounds[4]! },
    { zoneNumber: 1, minSecPerKm: bounds[4]!, maxSecPerKm: null },
  ];
}

export interface ZoneTime { zoneNumber: number; seconds: number; percent: number }

/**
 * Seconds spent in each pace zone. Standing still is not a pace zone: segments
 * slower than 30:00/km are read as a stop and left out of the total, so the
 * percentages describe the running rather than the waiting at traffic lights.
 */
export function paceZoneTimes(
  segments: readonly Segment[], ranges: readonly PaceZoneRange[],
): ZoneTime[] {
  const seconds = new Map<number, number>();
  let total = 0;
  for (const seg of segments) {
    if (seg.dd <= 0 || seg.dt <= 0) continue;
    const pace = (seg.dt / seg.dd) * 1000;
    if (pace < 120 || pace > 1800) continue;
    const zone = ranges.find(
      (r) => (r.maxSecPerKm === null || pace < r.maxSecPerKm)
        && (r.minSecPerKm === null || pace >= r.minSecPerKm),
    );
    if (!zone) continue;
    seconds.set(zone.zoneNumber, (seconds.get(zone.zoneNumber) ?? 0) + seg.dt);
    total += seg.dt;
  }
  if (total <= 0) return [];
  return ranges
    .map((r) => {
      const s = seconds.get(r.zoneNumber) ?? 0;
      return {
        zoneNumber: r.zoneNumber,
        seconds: Math.round(s),
        percent: Math.round((s / total) * 1000) / 10,
      };
    })
    .sort((a, b) => a.zoneNumber - b.zoneNumber);
}

/* ------------------------------------------------------------------ */
/* Odds and ends the stat grid reads                                   */
/* ------------------------------------------------------------------ */

/** Highest point on the route, in metres; null when nothing recorded elevation. */
export function elevationMax(samples: readonly NormalisedSample[]): number | null {
  let max: number | null = null;
  for (const s of samples) {
    if (s.ele !== null && (max === null || s.ele > max)) max = s.ele;
  }
  return max === null ? null : Math.round(max * 10) / 10;
}

/**
 * Steps from cadence. Cadence is recorded in steps per minute (both feet), so
 * this is the count over the moving time rather than the elapsed time — the
 * athlete takes no steps while paused.
 */
export function stepsFromCadence(
  avgCadence: number | null | undefined, movingSeconds: number | null | undefined,
): number | null {
  if (!avgCadence || !movingSeconds || avgCadence <= 0 || movingSeconds <= 0) return null;
  return Math.round(avgCadence * (movingSeconds / 60));
}

/* ------------------------------------------------------------------ */
/* Persistence                                                         */
/* ------------------------------------------------------------------ */

/** How far back an effort still counts as evidence of current fitness. */
export const PREDICTION_WINDOW_DAYS = 365;

export interface RunAnalysis {
  efforts: (RunEffort & { rank: number })[];
  paceZones: ZoneTime[];
  paceZoneRanges: PaceZoneRange[];
  gap: GapSummary;
  elevationMaxM: number | null;
  steps: number | null;
  /** Predicted seconds per standard distance, after this run. */
  predictions: { distanceM: number; seconds: number; previousSeconds: number | null }[];
}

/**
 * Everything the run detail screen needs that the plain totals do not give:
 * best efforts with their all-time place, race predictions and how much this
 * run moved them, pace zones, and grade adjusted pace.
 *
 * Called from the stream ingest, after splits and totals are already written,
 * and safe to re-run: every table it touches is cleared for this session first.
 */
export async function persistRunAnalysis(
  db: Db,
  userId: string,
  session: { id: string; activityTypeId: number; avgCadence: number | null; movingSeconds: number | null },
  samples: readonly NormalisedSample[],
  cumulative: readonly CumulativePoint[],
  now = Date.now(),
): Promise<RunAnalysis> {
  const segments = segmentsFromSamples(samples);
  const gap = gapFromSegments(segments);
  const elevationMaxM = elevationMax(samples);
  const steps = stepsFromCadence(session.avgCadence, session.movingSeconds);
  const raw = effortsForRun(cumulative);

  await db.delete(workoutBestEfforts)
    .where(eq(workoutBestEfforts.workoutSessionId, session.id));

  /* --- rank each effort against the board it joins ----------------- */
  const ranks = new Map<number, number>();
  if (raw.length > 0) {
    // One query rather than one per distance: each distance carries its own
    // threshold, so the counts come back already split by GROUP BY.
    const clauses = raw.map((e) => sql`(${workoutBestEfforts.distanceM} = ${e.distanceM} and ${
      workoutBestEfforts.elapsedSeconds} < ${e.seconds})`);
    const rows = await db
      .select({
        distanceM: workoutBestEfforts.distanceM,
        better: sql<number>`count(*)`,
      })
      .from(workoutBestEfforts)
      .where(and(
        eq(workoutBestEfforts.userId, userId),
        eq(workoutBestEfforts.activityTypeId, session.activityTypeId),
        sql`(${sql.join(clauses, sql` or `)})`,
      ))
      .groupBy(workoutBestEfforts.distanceM);
    for (const row of rows) ranks.set(row.distanceM, Number(row.better));
  }

  const efforts = raw.map((e) => ({ ...e, rank: (ranks.get(e.distanceM) ?? 0) + 1 }));

  if (efforts.length > 0) {
    await insertMany(
      (chunk) => db.insert(workoutBestEfforts).values(chunk),
      efforts.map((e) => ({
        workoutSessionId: session.id,
        userId,
        activityTypeId: session.activityTypeId,
        distanceM: e.distanceM,
        elapsedSeconds: Math.round(e.seconds * 10) / 10,
        startDistanceM: Math.round(e.startDistanceM),
        endDistanceM: Math.round(e.endDistanceM),
        rank: e.rank,
        createdAt: now,
      })),
    );
  }

  /* --- predictions from the whole board, this run included --------- */
  const since = now - PREDICTION_WINDOW_DAYS * 86_400_000;
  const board = await db
    .select({
      distanceM: workoutBestEfforts.distanceM,
      seconds: sql<number>`min(${workoutBestEfforts.elapsedSeconds})`,
    })
    .from(workoutBestEfforts)
    .where(and(
      eq(workoutBestEfforts.userId, userId),
      eq(workoutBestEfforts.activityTypeId, session.activityTypeId),
      gte(workoutBestEfforts.createdAt, since),
    ))
    .groupBy(workoutBestEfforts.distanceM);

  const current = await db
    .select()
    .from(racePredictions)
    .where(and(
      eq(racePredictions.userId, userId),
      eq(racePredictions.activityTypeId, session.activityTypeId),
      eq(racePredictions.isCurrent, true),
    ));
  const currentByDistance = new Map(current.map((r) => [r.distanceM, r]));

  const predictions: RunAnalysis['predictions'] = [];
  for (const target of PREDICTED_DISTANCES_M) {
    const seconds = predictFromEfforts(
      board.map((b) => ({ distanceM: b.distanceM, seconds: Number(b.seconds) })), target,
    );
    if (seconds === null) continue;
    const held = currentByDistance.get(target);
    const previousSeconds = held ? held.predictedSeconds : null;
    predictions.push({ distanceM: target, seconds, previousSeconds });
    // An unchanged prediction keeps the row it already has, so the history does
    // not grow a line for every run that changed nothing.
    if (held && Math.round(held.predictedSeconds) === seconds) continue;
    if (held) {
      await db.update(racePredictions).set({ isCurrent: false })
        .where(eq(racePredictions.id, held.id));
    }
    await db.insert(racePredictions).values({
      userId,
      activityTypeId: session.activityTypeId,
      distanceM: target,
      predictedSeconds: seconds,
      previousSeconds,
      workoutSessionId: session.id,
      isCurrent: true,
      computedAt: now,
    });
  }

  /* --- pace zones, anchored on the 5 km prediction ----------------- */
  const fiveK = predictions.find((p) => p.distanceM === 5000)?.seconds ?? null;
  const ranges = fiveK === null ? [] : paceZoneRanges(fiveK);
  const zones = ranges.length > 0 ? paceZoneTimes(segments, ranges) : [];

  // Only the pace rows: the heart-rate rows in this table were written from the
  // same stream moments ago and are none of this function's business.
  await db.delete(workoutZoneSummaries).where(and(
    eq(workoutZoneSummaries.workoutSessionId, session.id),
    eq(workoutZoneSummaries.kind, 'pace'),
  ));
  if (zones.length > 0) {
    await insertMany(
      (chunk) => db.insert(workoutZoneSummaries).values(chunk),
      zones.map((z) => ({
        workoutSessionId: session.id,
        kind: 'pace' as const,
        zoneNumber: z.zoneNumber,
        secondsInZone: z.seconds,
        percentOfSession: z.percent,
      })),
    );
  }

  await db.update(workoutSessions).set({
    elevationMaxM,
    gapSecPerKm: gap.avgGapSecPerKm,
    steps,
  }).where(eq(workoutSessions.id, session.id));

  return {
    efforts, paceZones: zones, paceZoneRanges: ranges, gap, elevationMaxM, steps, predictions,
  };
}

/**
 * The three counters over the "Kết quả" list. A first place is a personal best;
 * a top-ten place is an achievement. There are no challenges in this app, so
 * the third counter the layout allows for is simply not returned.
 */
export function effortCounters(
  efforts: readonly { rank: number }[],
): { bestEver: number; achievements: number } {
  return {
    bestEver: efforts.filter((e) => e.rank === 1).length,
    achievements: efforts.filter((e) => e.rank <= 10).length,
  };
}
