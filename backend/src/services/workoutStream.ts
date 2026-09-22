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
  /** Vertical accuracy of the fix in metres, when the platform reports one. */
  ea?: number | null;
}

/**
 * A sample after normalisation: `t` is seconds from the session start.
 *
 * Two fields are re-derived rather than taken as given. `ele` is the SMOOTHED
 * altitude, not the raw fix (see `smoothElevations`), and `moving` is this
 * backend's own auto-pause verdict (see `applyDerivedMovement`) rather than
 * whatever the recording device happened to believe. Both are done here so that
 * every reader — the totals, the splits, the charts, GAP, a re-derive after a
 * crop — sees the same numbers.
 */
export interface NormalisedSample {
  t: number;
  lat: number | null;
  lng: number | null;
  hr: number | null;
  /** Smoothed altitude in metres. */
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

/* ------------------------------------------------------------------ */
/* Altitude and movement, re-derived from the raw stream               */
/* ------------------------------------------------------------------ */

/**
 * Altitude is the noisiest thing in the stream. A phone reports it to the
 * centimetre and is wrong by metres, and the error wanders: over an hour at
 * 1 Hz that is thousands of little rises and falls that never happened. Adding
 * up the positive ones — which is all a naive total ascent does — turns pure
 * noise into a mountain, and the noise scales with the sample count rather than
 * with the terrain. A flat 7.3 km run recorded by this app read 534.5 m of
 * climb on a route whose highest point was 7.9 m above sea level.
 *
 * Two defences, in this order. The track is first averaged over a window of
 * seconds, which kills the sample-to-sample jitter and leaves a real hill —
 * tens of seconds long — where it is. Then the ascent is accumulated with
 * hysteresis: a rise is only banked once it stands `ELEVATION_MIN_RISE_M` above
 * the last low, so what survives is climbs rather than wobble. The cost is up
 * to one threshold's worth of climb lost at the top of each hill, which is
 * nothing next to the error it removes.
 */
export const ELEVATION_SMOOTH_WINDOW_S = 15;
export const ELEVATION_MIN_RISE_M = 3;
/** A step larger than this between two fixes is a bad fix, not a cliff. */
export const ELEVATION_MAX_STEP_M = 15;
/** Fixes whose reported vertical accuracy is worse than this carry no altitude. */
export const ELEVATION_MAX_UNCERTAINTY_M = 30;

/**
 * Centred moving average of altitude over `ELEVATION_SMOOTH_WINDOW_S`, with
 * single-sample spikes pulled back to their neighbours first — one bad fix
 * dragged through the window would otherwise smear across every point it
 * touches. Samples with no altitude stay null and take no part in the average.
 */
export function smoothElevations(
  samples: readonly { t: number; ele: number | null }[],
): (number | null)[] {
  const n = samples.length;
  const out: (number | null)[] = new Array(n).fill(null);
  if (n === 0) return out;

  const cleaned: (number | null)[] = samples.map((s) => s.ele);
  for (let i = 1; i < n - 1; i++) {
    const prev = cleaned[i - 1];
    const cur = cleaned[i];
    const next = cleaned[i + 1];
    if (prev == null || cur == null || next == null) continue;
    if (Math.abs(cur - prev) > ELEVATION_MAX_STEP_M
      && Math.abs(next - prev) <= ELEVATION_MAX_STEP_M) {
      cleaned[i] = (prev + next) / 2;
    }
  }

  const half = ELEVATION_SMOOTH_WINDOW_S / 2;
  let lo = 0;
  let hi = 0;
  let sum = 0;
  let count = 0;
  for (let i = 0; i < n; i++) {
    const t = samples[i]!.t;
    while (hi < n && samples[hi]!.t <= t + half) {
      const e = cleaned[hi];
      if (e != null) { sum += e; count++; }
      hi++;
    }
    while (lo < hi && samples[lo]!.t < t - half) {
      const e = cleaned[lo];
      if (e != null) { sum -= e; count--; }
      lo++;
    }
    out[i] = count > 0 ? sum / count : null;
  }
  return out;
}

/**
 * Total ascent with hysteresis: `ref` is the last altitude the climb was banked
 * at, it follows the track down freely, and it only moves up — banking the
 * difference — once the track stands a threshold above it. On flat ground with
 * a metre of wander the threshold is never crossed and the total stays at zero,
 * which is the right answer.
 */
export function ascentFrom(elevations: readonly (number | null)[]): number {
  let gain = 0;
  let ref: number | null = null;
  for (const e of elevations) {
    if (e == null) continue;
    if (ref === null) { ref = e; continue; }
    if (e >= ref + ELEVATION_MIN_RISE_M) {
      gain += e - ref;
      ref = e;
    } else if (e < ref) {
      ref = e;
    }
  }
  return gain;
}

/**
 * Auto-pause, decided here rather than taken from the device.
 *
 * The recorder has its own idea of when the runner stopped, but it does not put
 * it in the stream — every sample arrives with no `paused` flag at all, so the
 * moving time the server stored was always the full elapsed time. Re-deriving
 * it from the samples fixes that and, more importantly, makes every session
 * comparable: the same rule applied to a phone that auto-pauses and to one that
 * does not.
 *
 * A stop is smoothed speed under `STOP_SPEED_MS` — slower than a dawdling walk
 * — that HOLDS for at least `STOP_MIN_SECONDS`. The hold is what keeps a single
 * noisy fix, or a genuine pause at the top of a hill, from being counted as a
 * stop. A `paused` flag from the device is still honoured when one is present;
 * this only ever adds stops, never removes them.
 */
export const STOP_SPEED_MS = 0.6;
export const STOP_MIN_SECONDS = 4;
export const SPEED_SMOOTH_WINDOW_S = 5;

export function applyDerivedMovement(samples: NormalisedSample[]): void {
  const n = samples.length;
  if (n < 2) return;

  const half = SPEED_SMOOTH_WINDOW_S / 2;
  const stopped: boolean[] = new Array(n).fill(false);
  let lo = 0;
  let hi = 0;
  for (let i = 0; i < n; i++) {
    const t = samples[i]!.t;
    while (hi < n - 1 && samples[hi]!.t <= t + half) hi++;
    while (lo < hi && samples[lo]!.t < t - half) lo++;
    const dt = samples[hi]!.t - samples[lo]!.t;
    if (dt <= 0) continue;
    stopped[i] = (samples[hi]!.d - samples[lo]!.d) / dt < STOP_SPEED_MS;
  }

  // Only a stop that holds counts: a run of flagged samples shorter than the
  // minimum is a wobble in the fix, not the runner standing still.
  let i = 0;
  while (i < n) {
    if (!stopped[i]) { i++; continue; }
    let j = i;
    while (j < n && stopped[j]) j++;
    if (samples[j - 1]!.t - samples[i]!.t < STOP_MIN_SECONDS) {
      for (let k = i; k < j; k++) stopped[k] = false;
    }
    i = j;
  }

  for (let k = 0; k < n; k++) if (stopped[k]) samples[k]!.moving = false;
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
      // A fix that admits it does not know its altitude is not evidence of one.
      ele: (numOrNull(s.ea) ?? 0) > ELEVATION_MAX_UNCERTAINTY_M ? null : numOrNull(s.ele),
      d: cumulative,
      moving: !(s.paused === 1 || s.paused === true),
    });

    if (lat !== null && lng !== null) {
      prevLat = lat;
      prevLng = lng;
    }
    prevT = t;
  }

  // Both are corrections to what the device sent, so they belong here rather
  // than in any one reader: the totals, the splits, GAP, the charts and a
  // re-derive after a crop all go through this function.
  const smoothed = smoothElevations(out);
  for (let i = 0; i < out.length; i++) out[i]!.ele = smoothed[i] ?? null;
  applyDerivedMovement(out);

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
    /** Elapsed minus moving: the time the runner spent standing still. */
    stoppedSeconds: number;
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
/** Shorter than this and the leftover at the end is rounding, not a split. */
export const SPLIT_TAIL_MIN_M = 50;
export const DOWNSAMPLE_TARGET_POINTS = 200;
/** Rolling-window resolution, and the cap that keeps the search bounded. */
export const CUMULATIVE_NODE_MIN_M = 25;
export const CUMULATIVE_NODE_BUDGET = 800;

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
      distanceM: 0, durationSeconds: 0, movingSeconds: 0, stoppedSeconds: 0,
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
  let stoppedSeconds = 0;
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
      if (dt > 0 && !s.moving) stoppedSeconds += dt;
      const dd = s.d - prev.d;
      if (dt > 0 && dd > 1) {
        const pace = (dt / dd) * 1000;
        // Ignore implausibly fast samples (< 2:00/km) caused by GPS noise.
        if (pace >= 120 && (bestPace === null || pace < bestPace)) bestPace = pace;
      }
    }
  }
  // Ascent is the one total that cannot be accumulated sample by sample: see
  // `ascentFrom`, which needs the whole track to tell a climb from a wobble.
  const elevationGainM = ascentFrom(samples.map((x) => x.ele));
  const movingSeconds = Math.max(0, durationSeconds - stoppedSeconds);

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

  /* --- Splits ------------------------------------------------------ */
  /*
   * A split's clock is wall clock, stops included. That is deliberate: a split
   * is "how long did that kilometre take me", and a kilometre the runner spent
   * four minutes of standing at a red light in DID take longer. It is also what
   * makes one split stand out as abnormally slow, which is the only visible
   * trace a stop leaves on the pace chart.
   *
   * The trailing part-kilometre is a split like any other, carrying its real
   * length. The app used to synthesise it client-side, which meant two places
   * deciding what the last bar of the chart meant.
   */
  const splits: DerivedSplit[] = [];
  const boundaries: number[] = [];
  for (let k = 1; k * SPLIT_DISTANCE_M <= distanceM; k++) boundaries.push(k * SPLIT_DISTANCE_M);
  if (distanceM - (boundaries[boundaries.length - 1] ?? 0) >= SPLIT_TAIL_MIN_M) {
    boundaries.push(distanceM);
  }

  let splitStartT = samples[0]!.t;
  let splitStartD = 0;
  let cursor = 1;
  for (let k = 0; k < boundaries.length; k++) {
    const targetD = boundaries[k]!;
    const endT = k === boundaries.length - 1 && targetD >= distanceM
      ? last.t
      : timeAtDistance(samples, targetD);
    if (endT === null) break;

    let hrSumSplit = 0;
    let hrCountSplit = 0;
    let movingSplit = 0;
    const eles: (number | null)[] = [];
    let j = cursor;
    for (; j < samples.length && samples[j - 1]!.d <= targetD; j++) {
      const cur = samples[j]!;
      const prev = samples[j - 1]!;
      if (cur.hr !== null) { hrSumSplit += cur.hr; hrCountSplit++; }
      eles.push(cur.ele);
      const dt = cur.t - prev.t;
      if (dt > 0 && cur.moving) movingSplit += dt;
    }
    cursor = Math.max(cursor, j - 1);

    const splitDistanceM = targetD - splitStartD;
    const elapsed = Math.max(0, endT - splitStartT);
    splits.push({
      splitIndex: k + 1,
      splitDistanceM: Math.round(splitDistanceM * 10) / 10,
      elapsedSeconds: Math.round(elapsed),
      movingSeconds: Math.round(Math.min(movingSplit, elapsed)),
      avgHeartRate: hrCountSplit ? Math.round(hrSumSplit / hrCountSplit) : null,
      elevationGainM: Math.round(ascentFrom(eles) * 10) / 10,
      // Per kilometre, so the part-kilometre at the end is comparable with the
      // whole ones rather than looking like the fastest split of the run.
      avgPaceSecPerKm: splitDistanceM > 0
        ? Math.round((elapsed / splitDistanceM) * 1000 * 10) / 10
        : 0,
    });
    splitStartT = endT;
    splitStartD = targetD;
  }

  /* --- Cumulative (distance, elapsed) nodes ------------------------ */
  /*
   * The input to every rolling-window effort — the fastest kilometre, the
   * fastest 5 km, the medals on the map. It used to hold one node per whole
   * kilometre, which made a "fastest 400 m" a straight-line interpolation
   * inside a kilometre it never looked at. Nodes every few tens of metres cost
   * little and make the window mean something; the spacing widens on a long run
   * so the O(n^2) window search stays bounded.
   */
  const nodeStep = Math.max(CUMULATIVE_NODE_MIN_M, distanceM / CUMULATIVE_NODE_BUDGET);
  const cumulative: { d: number; t: number }[] = [{ d: 0, t: samples[0]!.t }];
  for (const s of samples) {
    const prev = cumulative[cumulative.length - 1]!;
    if (s.d - prev.d >= nodeStep && s.t > prev.t) cumulative.push({ d: s.d, t: s.t });
  }
  const tailNode = cumulative[cumulative.length - 1]!;
  if (distanceM > tailNode.d && last.t > tailNode.t) {
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
      movingSeconds: Math.round(movingSeconds),
      stoppedSeconds: Math.round(stoppedSeconds),
      avgHeartRate: hrCount ? Math.round(hrSum / hrCount) : null,
      maxHeartRate: maxHr,
      // Average pace runs on moving time; the elapsed-time pace is the second
      // figure on the detail screen and is derived from the two stored totals.
      avgPaceSecPerKm: distanceM > 0 ? Math.round((movingSeconds / distanceM) * 1000) : null,
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
