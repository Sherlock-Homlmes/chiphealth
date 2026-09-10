import { and, asc, desc, eq, lte } from 'drizzle-orm';
import type { Db } from '../db/client';
import {
  heartRateZones, mediaAssets, userProfiles, workoutSessions, workoutSplits,
  workoutStreams, workoutZoneSummaries,
} from '../db/schema';
import { ApiError, notFound } from '../lib/errors';
import { ageFromDob } from '../lib/time';
import type { Bindings } from '../env';

/* ------------------------------------------------------------------ */
/* Encoded polyline (Google's algorithm — implemented here, no dep)    */
/* ------------------------------------------------------------------ */

function encodeSignedNumber(value: number): string {
  let v = value < 0 ? ~(value << 1) : value << 1;
  let out = '';
  while (v >= 0x20) {
    out += String.fromCharCode((0x20 | (v & 0x1f)) + 63);
    v >>>= 5;
  }
  out += String.fromCharCode(v + 63);
  return out;
}

/**
 * Google Encoded Polyline Algorithm Format.
 * `[[38.5,-120.2],[40.7,-120.95],[43.252,-126.453]]` -> `` _p~iF~ps|U_ulLnnqC_mqNvxq`@ ``
 */
export function encodePolyline(
  points: readonly (readonly [number, number])[],
  precision = 5,
): string {
  const factor = 10 ** precision;
  let prevLat = 0;
  let prevLng = 0;
  let out = '';
  for (const p of points) {
    const lat = Math.round(p[0] * factor);
    const lng = Math.round(p[1] * factor);
    out += encodeSignedNumber(lat - prevLat);
    out += encodeSignedNumber(lng - prevLng);
    prevLat = lat;
    prevLng = lng;
  }
  return out;
}

/** Decoder, used by the tests and by anything that needs to re-read a stored polyline. */
export function decodePolyline(encoded: string, precision = 5): [number, number][] {
  const factor = 10 ** precision;
  const out: [number, number][] = [];
  let i = 0;
  let lat = 0;
  let lng = 0;
  while (i < encoded.length) {
    let shift = 0;
    let result = 0;
    let byte: number;
    do {
      byte = encoded.charCodeAt(i++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);
    lat += result & 1 ? ~(result >> 1) : result >> 1;

    shift = 0;
    result = 0;
    do {
      byte = encoded.charCodeAt(i++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);
    lng += result & 1 ? ~(result >> 1) : result >> 1;

    out.push([lat / factor, lng / factor]);
  }
  return out;
}

/* ------------------------------------------------------------------ */
/* Raw sample stream                                                   */
/* ------------------------------------------------------------------ */

/**
 * One raw sample as uploaded by the app. `t` is either an epoch-ms timestamp or
 * an offset in seconds from the session start — both are normalised on parse.
 */
export interface RawSample {
  t: number;
  lat?: number | null;
  lng?: number | null;
  hr?: number | null;
  ele?: number | null;
  /** Cumulative distance in metres, when the device already computed it. */
  d?: number | null;
  /** Instantaneous speed in m/s, when available. */
  speed?: number | null;
  /** 1 while auto-paused. */
  paused?: number | boolean | null;
}

/** A sample after normalisation: `t` is seconds from the session start. */
export interface NormalisedSample {
  t: number;
  lat: number | null;
  lng: number | null;
  hr: number | null;
  ele: number | null;
  /** Cumulative distance in metres. */
  d: number;
  moving: boolean;
}

const EARTH_RADIUS_M = 6371008.8;

export function haversineMeters(
  aLat: number, aLng: number, bLat: number, bLng: number,
): number {
  const toRad = Math.PI / 180;
  const dLat = (bLat - aLat) * toRad;
  const dLng = (bLng - aLng) * toRad;
  const s =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(aLat * toRad) * Math.cos(bLat * toRad) * Math.sin(dLng / 2) ** 2;
  return 2 * EARTH_RADIUS_M * Math.asin(Math.min(1, Math.sqrt(s)));
}

const isFiniteNumber = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v);
const numOrNull = (v: unknown): number | null => (isFiniteNumber(v) ? v : null);

/**
 * Accepts NDJSON (one sample per line), a bare JSON array, or `{samples:[...]}`.
 * Unparseable lines are skipped rather than failing the whole ingest.
 */
export function parseSampleStream(text: string): RawSample[] {
  const trimmed = text.trim();
  if (!trimmed) return [];

  if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
    try {
      const doc = JSON.parse(trimmed) as unknown;
      if (Array.isArray(doc)) return doc as RawSample[];
      if (doc && typeof doc === 'object') {
        const samples = (doc as { samples?: unknown }).samples;
        if (Array.isArray(samples)) return samples as RawSample[];
      }
    } catch {
      /* fall through to NDJSON */
    }
  }

  const out: RawSample[] = [];
  for (const line of trimmed.split('\n')) {
    const l = line.trim();
    if (!l) continue;
    try {
      const parsed = JSON.parse(l) as unknown;
      if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
        out.push(parsed as RawSample);
      }
    } catch {
      /* skip malformed line */
    }
  }
  return out;
}

/**
 * Sorts, converts `t` to seconds-from-start and fills cumulative distance from
 * GPS (or from a device-provided `d` / `speed`) when it is missing.
 */
export function normaliseSamples(raw: readonly RawSample[]): NormalisedSample[] {
  const usable = raw.filter((s) => isFiniteNumber(s.t)).slice().sort((a, b) => a.t - b.t);
  if (usable.length === 0) return [];

  const first = usable[0]!;
  // Epoch-ms timestamps are > ~1973 in seconds; treat anything huge as epoch ms.
  const asEpochMs = first.t > 1e11;
  const base = first.t;

  const out: NormalisedSample[] = [];
  let cumulative = 0;
  let prevLat: number | null = null;
  let prevLng: number | null = null;
  let prevT = 0;

  for (const s of usable) {
    const t = asEpochMs ? (s.t - base) / 1000 : s.t - base;
    const lat = numOrNull(s.lat);
    const lng = numOrNull(s.lng);
    const deviceD = numOrNull(s.d);

    if (deviceD !== null) {
      cumulative = Math.max(cumulative, deviceD);
    } else if (lat !== null && lng !== null && prevLat !== null && prevLng !== null) {
      const step = haversineMeters(prevLat, prevLng, lat, lng);
      // Drop obvious GPS jumps (> 200 m between two samples).
      if (step < 200) cumulative += step;
    } else if (numOrNull(s.speed) !== null && out.length > 0) {
      cumulative += Math.max(0, s.speed as number) * Math.max(0, t - prevT);
    }

    out.push({
      t,
      lat,
      lng,
      hr: numOrNull(s.hr),
      ele: numOrNull(s.ele),
      d: cumulative,
      moving: !(s.paused === 1 || s.paused === true),
    });

    if (lat !== null && lng !== null) {
      prevLat = lat;
      prevLng = lng;
    }
    prevT = t;
  }
  return out;
}

/* ------------------------------------------------------------------ */
/* Derivations                                                         */
/* ------------------------------------------------------------------ */

export interface Bounds {
  minLat: number; minLng: number; maxLat: number; maxLng: number;
}

export interface DownsampledPoint {
  /** Seconds from the session start. */
  t: number;
  hr: number | null;
  /** sec/km. */
  pace: number | null;
  ele: number | null;
}

export interface DerivedSplit {
  splitIndex: number;
  splitDistanceM: number;
  elapsedSeconds: number;
  movingSeconds: number;
  avgHeartRate: number | null;
  elevationGainM: number;
  avgPaceSecPerKm: number;
}

export interface DerivedZoneTime {
  zoneNumber: number;
  secondsInZone: number;
  percentOfSession: number;
}

export interface StreamDerivation {
  sampleCount: number;
  sampleIntervalS: number | null;
  encodedPolyline: string | null;
  bounds: Bounds | null;
  startLatitude: number | null;
  startLongitude: number | null;
  downsampled: DownsampledPoint[];
  splits: DerivedSplit[];
  /** Cumulative (distance, elapsed) nodes — the input to fastest-distance PRs. */
  cumulative: { d: number; t: number }[];
  totals: {
    distanceM: number;
    durationSeconds: number;
    movingSeconds: number;
    avgHeartRate: number | null;
    maxHeartRate: number | null;
    avgPaceSecPerKm: number | null;
    bestPaceSecPerKm: number | null;
    elevationGainM: number;
  };
  hasGps: boolean;
  hasHeartRate: boolean;
}

export const SPLIT_DISTANCE_M = 1000;
export const DOWNSAMPLE_TARGET_POINTS = 200;

/** Linear interpolation of elapsed time at an exact cumulative distance. */
function timeAtDistance(samples: readonly NormalisedSample[], target: number): number | null {
  for (let i = 1; i < samples.length; i++) {
    const prev = samples[i - 1]!;
    const cur = samples[i]!;
    if (cur.d >= target && prev.d <= target) {
      const span = cur.d - prev.d;
      if (span <= 0) return cur.t;
      return prev.t + ((target - prev.d) / span) * (cur.t - prev.t);
    }
  }
  return null;
}

export function deriveFromSamples(samples: readonly NormalisedSample[]): StreamDerivation {
  const empty: StreamDerivation = {
    sampleCount: samples.length,
    sampleIntervalS: null,
    encodedPolyline: null,
    bounds: null,
    startLatitude: null,
    startLongitude: null,
    downsampled: [],
    splits: [],
    cumulative: [],
    totals: {
      distanceM: 0, durationSeconds: 0, movingSeconds: 0,
      avgHeartRate: null, maxHeartRate: null,
      avgPaceSecPerKm: null, bestPaceSecPerKm: null, elevationGainM: 0,
    },
    hasGps: false,
    hasHeartRate: false,
  };
  if (samples.length === 0) return empty;

  const last = samples[samples.length - 1]!;
  const durationSeconds = Math.max(0, Math.round(last.t));
  const distanceM = last.d;

  /* --- GPS: polyline + bounds ------------------------------------- */
  const geo = samples.filter(
    (s): s is NormalisedSample & { lat: number; lng: number } => s.lat !== null && s.lng !== null,
  );
  let bounds: Bounds | null = null;
  let encoded: string | null = null;
  if (geo.length > 0) {
    let minLat = Infinity; let minLng = Infinity;
    let maxLat = -Infinity; let maxLng = -Infinity;
    for (const g of geo) {
      if (g.lat < minLat) minLat = g.lat;
      if (g.lat > maxLat) maxLat = g.lat;
      if (g.lng < minLng) minLng = g.lng;
      if (g.lng > maxLng) maxLng = g.lng;
    }
    bounds = { minLat, minLng, maxLat, maxLng };
    // Keep the polyline light: at most ~1000 vertices for a map preview.
    const stride = Math.max(1, Math.ceil(geo.length / 1000));
    const pts: [number, number][] = [];
    for (let i = 0; i < geo.length; i += stride) pts.push([geo[i]!.lat, geo[i]!.lng]);
    const lastGeo = geo[geo.length - 1]!;
    const tail = pts[pts.length - 1];
    if (!tail || tail[0] !== lastGeo.lat || tail[1] !== lastGeo.lng) {
      pts.push([lastGeo.lat, lastGeo.lng]);
    }
    encoded = encodePolyline(pts);
  }

  /* --- HR + elevation + moving time ------------------------------- */
  let hrSum = 0;
  let hrCount = 0;
  let maxHr: number | null = null;
  let elevationGainM = 0;
  let movingSeconds = 0;
  let bestPace: number | null = null;

  for (let i = 0; i < samples.length; i++) {
    const s = samples[i]!;
    if (s.hr !== null) {
      hrSum += s.hr;
      hrCount++;
      if (maxHr === null || s.hr > maxHr) maxHr = s.hr;
    }
    if (i > 0) {
      const prev = samples[i - 1]!;
      const dt = s.t - prev.t;
      if (dt > 0 && s.moving) movingSeconds += dt;
      if (s.ele !== null && prev.ele !== null && s.ele > prev.ele) {
        elevationGainM += s.ele - prev.ele;
      }
      const dd = s.d - prev.d;
      if (dt > 0 && dd > 1) {
        const pace = (dt / dd) * 1000;
        // Ignore implausibly fast samples (< 2:00/km) caused by GPS noise.
        if (pace >= 120 && (bestPace === null || pace < bestPace)) bestPace = pace;
      }
    }
  }

  /* --- Downsample to ~200 chart points ---------------------------- */
  const stride = Math.max(1, Math.ceil(samples.length / DOWNSAMPLE_TARGET_POINTS));
  const downsampled: DownsampledPoint[] = [];
  for (let i = 0; i < samples.length; i += stride) {
    const s = samples[i]!;
    const win = samples.slice(Math.max(0, i - stride), Math.min(samples.length, i + stride + 1));
    const a = win[0]!;
    const b = win[win.length - 1]!;
    const dt = b.t - a.t;
    const dd = b.d - a.d;
    const hrs = win.map((w) => w.hr).filter((h): h is number => h !== null);
    downsampled.push({
      t: Math.round(s.t),
      hr: hrs.length ? Math.round(hrs.reduce((x, y) => x + y, 0) / hrs.length) : null,
      pace: dt > 0 && dd > 1 ? Math.round((dt / dd) * 1000) : null,
      ele: s.ele,
    });
  }

  /* --- Per-kilometre splits --------------------------------------- */
  const splits: DerivedSplit[] = [];
  const cumulative: { d: number; t: number }[] = [{ d: 0, t: samples[0]!.t }];
  const splitCount = Math.floor(distanceM / SPLIT_DISTANCE_M);
  let splitStartT = samples[0]!.t;
  let cursor = 0;

  for (let k = 1; k <= splitCount; k++) {
    const targetD = k * SPLIT_DISTANCE_M;
    const endT = timeAtDistance(samples, targetD);
    if (endT === null) break;
    cumulative.push({ d: targetD, t: endT });

    let hrSumSplit = 0;
    let hrCountSplit = 0;
    let gain = 0;
    let moving = 0;
    let j = cursor;
    for (; j < samples.length && samples[j]!.d <= targetD; j++) {
      const s = samples[j]!;
      if (s.hr !== null) { hrSumSplit += s.hr; hrCountSplit++; }
      if (j > 0) {
        const prev = samples[j - 1]!;
        if (s.ele !== null && prev.ele !== null && s.ele > prev.ele) gain += s.ele - prev.ele;
        const dt = s.t - prev.t;
        if (dt > 0 && s.moving && prev.d >= targetD - SPLIT_DISTANCE_M) moving += dt;
      }
    }
    cursor = Math.max(cursor, j - 1);

    const elapsed = Math.max(0, endT - splitStartT);
    splits.push({
      splitIndex: k,
      splitDistanceM: SPLIT_DISTANCE_M,
      elapsedSeconds: Math.round(elapsed),
      movingSeconds: Math.round(moving > 0 ? moving : elapsed),
      avgHeartRate: hrCountSplit ? Math.round(hrSumSplit / hrCountSplit) : null,
      elevationGainM: Math.round(gain * 10) / 10,
      avgPaceSecPerKm: Math.round(elapsed * 10) / 10,
    });
    splitStartT = endT;
  }

  // Trailing partial kilometre, so cumulative reaches the real end of the run.
  if (distanceM > splitCount * SPLIT_DISTANCE_M) {
    cumulative.push({ d: distanceM, t: last.t });
  }

  const intervals: number[] = [];
  for (let i = 1; i < samples.length; i++) intervals.push(samples[i]!.t - samples[i - 1]!.t);
  const sampleIntervalS = intervals.length
    ? Math.round((intervals.reduce((a, b) => a + b, 0) / intervals.length) * 100) / 100
    : null;

  return {
    sampleCount: samples.length,
    sampleIntervalS,
    encodedPolyline: encoded,
    bounds,
    startLatitude: geo[0]?.lat ?? null,
    startLongitude: geo[0]?.lng ?? null,
    downsampled,
    splits,
    cumulative,
    totals: {
      distanceM: Math.round(distanceM * 10) / 10,
      durationSeconds,
      movingSeconds: Math.round(movingSeconds > 0 ? movingSeconds : durationSeconds),
      avgHeartRate: hrCount ? Math.round(hrSum / hrCount) : null,
      maxHeartRate: maxHr,
      avgPaceSecPerKm: distanceM > 0 ? Math.round((durationSeconds / distanceM) * 1000) : null,
      bestPaceSecPerKm: bestPace === null ? null : Math.round(bestPace),
      elevationGainM: Math.round(elevationGainM * 10) / 10,
    },
    hasGps: geo.length > 0,
    hasHeartRate: hrCount > 0,
  };
}

/* ------------------------------------------------------------------ */
/* Heart-rate zones                                                    */
/* ------------------------------------------------------------------ */

export type HrZoneMethod = 'auto_age_based' | 'manual_max_hr' | 'manual_threshold';

export interface ZoneRange { zoneNumber: number; minBpm: number; maxBpm: number }

/** Z1..Z5 = 50-60 / 60-70 / 70-80 / 80-90 / 90-100 % of max HR. */
export const ZONE_PERCENTS: readonly (readonly [number, number])[] = [
  [0.5, 0.6], [0.6, 0.7], [0.7, 0.8], [0.8, 0.9], [0.9, 1.0],
];

/**
 * Zones must partition the bpm axis: with inclusive bounds on both ends, a beat
 * landing exactly on a boundary would count in two zones at once and time-in-zone
 * would not sum to the session duration. Every zone below the top therefore ends
 * one bpm short of the next zone's start.
 */
export function computeZoneRanges(maxHeartRate: number): ZoneRange[] {
  return ZONE_PERCENTS.map(([lo, hi], i) => {
    const isTopZone = i === ZONE_PERCENTS.length - 1;
    return {
      zoneNumber: i + 1,
      minBpm: Math.round(maxHeartRate * lo),
      maxBpm: Math.round(maxHeartRate * hi) - (isTopZone ? 0 : 1),
    };
  });
}

export const DEFAULT_AGE = 30;

/** 220 − age, unless `max_heart_rate_override` is set. */
export function resolveMaxHeartRate(
  profile: { dateOfBirth: string | null; maxHeartRateOverride: number | null } | undefined,
  now = Date.now(),
): { maxHeartRate: number; method: HrZoneMethod; age: number | null } {
  if (profile?.maxHeartRateOverride) {
    return { maxHeartRate: profile.maxHeartRateOverride, method: 'manual_max_hr', age: null };
  }
  const age = profile?.dateOfBirth ? ageFromDob(profile.dateOfBirth, now) : null;
  const usedAge = age !== null && age > 0 && age < 120 ? age : DEFAULT_AGE;
  return { maxHeartRate: 220 - usedAge, method: 'auto_age_based', age };
}

export interface ZoneSet {
  effectiveFrom: number;
  maxHeartRateUsed: number;
  method: HrZoneMethod;
  zones: ZoneRange[];
}

/**
 * Inserts a NEW zone set with a fresh `effective_from`. History is never updated
 * in place — otherwise old workouts would silently change zones.
 */
export async function insertZoneSet(
  db: Db, userId: string, now = Date.now(),
): Promise<ZoneSet> {
  const profile = await db.query.userProfiles.findFirst({
    where: eq(userProfiles.userId, userId),
  });
  const { maxHeartRate, method } = resolveMaxHeartRate(profile, now);
  const zones = computeZoneRanges(maxHeartRate);
  await db.insert(heartRateZones).values(
    zones.map((z) => ({
      userId,
      zoneNumber: z.zoneNumber,
      minBpm: z.minBpm,
      maxBpm: z.maxBpm,
      method,
      maxHeartRateUsed: maxHeartRate,
      effectiveFrom: now,
    })),
  ).onConflictDoNothing();
  return { effectiveFrom: now, maxHeartRateUsed: maxHeartRate, method, zones };
}

/** The zone set whose `effective_from` is the latest one <= `at`. */
export async function zoneSetEffectiveAt(
  db: Db, userId: string, at: number,
): Promise<ZoneSet | null> {
  const [head] = await db.select({ effectiveFrom: heartRateZones.effectiveFrom })
    .from(heartRateZones)
    .where(and(eq(heartRateZones.userId, userId), lte(heartRateZones.effectiveFrom, at)))
    .orderBy(desc(heartRateZones.effectiveFrom))
    .limit(1);

  let effectiveFrom = head?.effectiveFrom;
  if (effectiveFrom === undefined) {
    // No set predates the session (e.g. a backfilled workout): fall back to the
    // earliest set we have rather than scoring against nothing.
    const [earliest] = await db.select({ effectiveFrom: heartRateZones.effectiveFrom })
      .from(heartRateZones)
      .where(eq(heartRateZones.userId, userId))
      .orderBy(asc(heartRateZones.effectiveFrom))
      .limit(1);
    effectiveFrom = earliest?.effectiveFrom;
  }
  if (effectiveFrom === undefined) return null;

  const rows = await db.select().from(heartRateZones)
    .where(and(
      eq(heartRateZones.userId, userId),
      eq(heartRateZones.effectiveFrom, effectiveFrom),
    ))
    .orderBy(asc(heartRateZones.zoneNumber));
  if (rows.length === 0) return null;

  const first = rows[0]!;
  return {
    effectiveFrom,
    maxHeartRateUsed: first.maxHeartRateUsed,
    method: first.method,
    zones: rows.map((r) => ({ zoneNumber: r.zoneNumber, minBpm: r.minBpm, maxBpm: r.maxBpm })),
  };
}

/** Current zones, creating the first set on demand. */
export async function currentZoneSet(db: Db, userId: string): Promise<ZoneSet> {
  const now = Date.now();
  const existing = await zoneSetEffectiveAt(db, userId, now);
  if (existing) return existing;
  return insertZoneSet(db, userId, now);
}

export function zoneOf(zones: readonly ZoneRange[], hr: number): number | null {
  // Zones are contiguous; the top zone is open-ended so a max-effort spike counts.
  for (let i = zones.length - 1; i >= 0; i--) {
    const z = zones[i]!;
    if (hr >= z.minBpm) return z.zoneNumber;
  }
  return null;
}

export function timeInZones(
  samples: readonly NormalisedSample[], zones: readonly ZoneRange[],
): DerivedZoneTime[] {
  const seconds = new Map<number, number>();
  for (const z of zones) seconds.set(z.zoneNumber, 0);

  for (let i = 1; i < samples.length; i++) {
    const prev = samples[i - 1]!;
    const cur = samples[i]!;
    const dt = cur.t - prev.t;
    if (dt <= 0) continue;
    const hr = cur.hr ?? prev.hr;
    if (hr === null) continue;
    const zn = zoneOf(zones, hr);
    if (zn === null) continue;
    seconds.set(zn, (seconds.get(zn) ?? 0) + dt);
  }

  const total = [...seconds.values()].reduce((a, b) => a + b, 0);
  return [...seconds.entries()]
    .map(([zoneNumber, s]) => ({
      zoneNumber,
      secondsInZone: Math.round(s),
      percentOfSession: total > 0 ? Math.round((s / total) * 1000) / 10 : 0,
    }))
    .sort((a, b) => a.zoneNumber - b.zoneNumber);
}

/* ------------------------------------------------------------------ */
/* Ingest                                                              */
/* ------------------------------------------------------------------ */

async function readAssetText(env: Bindings, key: string): Promise<string> {
  const obj = await env.MEDIA.get(key);
  if (!obj) throw notFound('Stream object');
  const buf = new Uint8Array(await obj.arrayBuffer());
  // gzip magic number — the app uploads gzipped NDJSON.
  if (buf.length > 2 && buf[0] === 0x1f && buf[1] === 0x8b) {
    const ds = new DecompressionStream('gzip');
    const stream = new Blob([buf]).stream().pipeThrough(ds);
    return new Response(stream).text();
  }
  return new TextDecoder().decode(buf);
}

export interface IngestResult {
  derivation: StreamDerivation;
  zoneSummaries: DerivedZoneTime[];
  zoneSet: ZoneSet | null;
}

/**
 * Reads the raw sample stream out of R2 and writes back every queryable
 * derivative: polyline + bounds + downsampled series (`workout_streams`),
 * per-km `workout_splits`, and `workout_zone_summaries`.
 * D1 never stores per-point rows — this is the whole reason.
 */
export async function ingestWorkoutStream(
  db: Db,
  env: Bindings,
  session: typeof workoutSessions.$inferSelect,
  assetId: string,
  hints: { sampleCount?: number; sampleIntervalS?: number } = {},
): Promise<IngestResult> {
  const asset = await db.query.mediaAssets.findFirst({ where: eq(mediaAssets.id, assetId) });
  if (!asset) throw notFound('Media asset');
  if (asset.userId && asset.userId !== session.userId) {
    throw new ApiError('FORBIDDEN', 'Asset belongs to another user');
  }
  if (asset.kind !== 'workout_stream') {
    throw new ApiError('VALIDATION_ERROR', `Asset kind must be workout_stream, got ${asset.kind}`);
  }

  const text = await readAssetText(env, asset.r2Key);
  const samples = normaliseSamples(parseSampleStream(text));
  const derivation = deriveFromSamples(samples);

  const zoneSet = derivation.hasHeartRate
    ? (await zoneSetEffectiveAt(db, session.userId, session.startedAt))
      ?? (await insertZoneSet(db, session.userId, session.startedAt))
    : null;
  const zoneSummaries = zoneSet ? timeInZones(samples, zoneSet.zones) : [];

  const now = Date.now();

  await db.insert(workoutStreams).values({
    workoutSessionId: session.id,
    r2AssetId: assetId,
    sampleCount: hints.sampleCount ?? derivation.sampleCount,
    sampleIntervalS: hints.sampleIntervalS ?? derivation.sampleIntervalS,
    encodedPolyline: derivation.encodedPolyline,
    downsampledJson: JSON.stringify(derivation.downsampled),
    startLatitude: derivation.startLatitude,
    startLongitude: derivation.startLongitude,
    boundsJson: derivation.bounds ? JSON.stringify(derivation.bounds) : null,
    hasGps: derivation.hasGps,
    hasHeartRate: derivation.hasHeartRate,
    createdAt: now,
  }).onConflictDoUpdate({
    target: workoutStreams.workoutSessionId,
    set: {
      r2AssetId: assetId,
      sampleCount: hints.sampleCount ?? derivation.sampleCount,
      sampleIntervalS: hints.sampleIntervalS ?? derivation.sampleIntervalS,
      encodedPolyline: derivation.encodedPolyline,
      downsampledJson: JSON.stringify(derivation.downsampled),
      startLatitude: derivation.startLatitude,
      startLongitude: derivation.startLongitude,
      boundsJson: derivation.bounds ? JSON.stringify(derivation.bounds) : null,
      hasGps: derivation.hasGps,
      hasHeartRate: derivation.hasHeartRate,
    },
  });

  // The asset is now referenced by a domain row.
  await db.update(mediaAssets).set({ isOrphan: false }).where(eq(mediaAssets.id, assetId));

  // Splits and zone summaries are fully derived — replace, never merge.
  await db.delete(workoutSplits).where(eq(workoutSplits.workoutSessionId, session.id));
  if (derivation.splits.length) {
    await db.insert(workoutSplits).values(
      derivation.splits.map((s) => ({ workoutSessionId: session.id, ...s })),
    );
  }
  await db.delete(workoutZoneSummaries)
    .where(eq(workoutZoneSummaries.workoutSessionId, session.id));
  if (zoneSummaries.length) {
    await db.insert(workoutZoneSummaries).values(
      zoneSummaries.map((z) => ({ workoutSessionId: session.id, ...z })),
    );
  }

  // Fill session aggregates the client did not provide. Wearable-supplied
  // values (and calories) are never clobbered by the derived ones.
  const t = derivation.totals;
  const blank = (v: number | null) => v === null || v === 0;
  const patch: Partial<typeof workoutSessions.$inferInsert> = { updatedAt: now };
  if (blank(session.distanceM) && t.distanceM > 0) patch.distanceM = t.distanceM;
  if (blank(session.durationSeconds) && t.durationSeconds > 0) {
    patch.durationSeconds = t.durationSeconds;
  }
  if (blank(session.movingSeconds) && t.movingSeconds > 0) patch.movingSeconds = t.movingSeconds;
  if (blank(session.avgHeartRate) && t.avgHeartRate) patch.avgHeartRate = t.avgHeartRate;
  if (blank(session.maxHeartRate) && t.maxHeartRate) patch.maxHeartRate = t.maxHeartRate;
  if (blank(session.avgPaceSecPerKm) && t.avgPaceSecPerKm) {
    patch.avgPaceSecPerKm = t.avgPaceSecPerKm;
  }
  if (blank(session.bestPaceSecPerKm) && t.bestPaceSecPerKm) {
    patch.bestPaceSecPerKm = t.bestPaceSecPerKm;
  }
  if (blank(session.elevationGainM) && t.elevationGainM > 0) {
    patch.elevationGainM = t.elevationGainM;
  }
  await db.update(workoutSessions).set(patch).where(eq(workoutSessions.id, session.id));

  return { derivation, zoneSummaries, zoneSet };
}
