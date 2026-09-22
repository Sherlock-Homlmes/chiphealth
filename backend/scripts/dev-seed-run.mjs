/**
 * Seeds ONE run with everything the detail screen draws: a looped route with a
 * stretch covered twice, per-kilometre paces that vary (including one very slow
 * kilometre), rolling elevation and a cadence. It goes through the HTTP API, so
 * splits, best efforts, predictions, pace zones and GAP are all derived by the
 * server exactly as they are for a real recording.
 *
 * The numbers follow the design brief's sample run: 10.60 km around Duy Tiên,
 * Hà Nam, with the kilometre paces listed there.
 *
 *   node scripts/dev-seed-run.mjs [email] [apiBase]
 */
import { createHmac } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

const vars = Object.fromEntries(
  readFileSync(new URL('../.dev.vars', import.meta.url), 'utf8')
    .split('\n')
    .filter((l) => l.includes('=') && !l.trimStart().startsWith('#'))
    .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]),
);

const email = process.argv[2] ?? vars.BOOTSTRAP_ADMIN_EMAILS?.split(',')[0].trim();
const base = (process.argv[3] ?? 'http://127.0.0.1:8787').replace(/\/+$/, '');
const tz = 'Asia/Ho_Chi_Minh';

const raw = execFileSync('npx', [
  'wrangler', 'd1', 'execute', 'chiphealth', '--local', '--json',
  '--command', `SELECT id FROM users WHERE email = '${email}'`,
], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
const userId = JSON.parse(raw.slice(raw.indexOf('[')))?.[0]?.results?.[0]?.id;
if (!userId) {
  console.error(`No user ${email}. Run: npm run dev:session`);
  process.exit(1);
}

const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const nowS = Math.floor(Date.now() / 1000);
const head = `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({
  sub: userId, email, role: 'admin', tz, locale: 'vi', iat: nowS, exp: nowS + 3600,
})}`;
const token = `${head}.${createHmac('sha256', vars.JWT_SECRET).update(head).digest('base64url')}`;

const api = async (method, path, body) => {
  const res = await fetch(base + path, {
    method,
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${path} -> ${res.status} ${text.slice(0, 300)}`);
  return text ? JSON.parse(text) : null;
};

/**
 * The runs to seed, newest last. The detail screen is opened on the last one:
 * the two before it are what give it something to be ranked against — a tempo
 * run it cannot beat over the short distances, and an older, slower 10 km whose
 * prediction it improves on.
 *
 * Each leg is (metres, seconds per kilometre).
 */
const RUNS = [
  {
    daysAgo: 14,
    title: 'Chạy dài cuối tuần',
    hour: 6,
    cadence: 154,
    legs: [[1000, 492], [1000, 488], [1000, 495], [1000, 486], [1000, 490],
      [1000, 484], [1000, 493], [1000, 487], [1000, 496], [1000, 489],
      [400, 494]],
  },
  {
    daysAgo: 6,
    title: 'Chạy tempo',
    hour: 18,
    cadence: 172,
    legs: [[1000, 398], [1000, 381], [1000, 376], [1000, 379], [1000, 386],
      [200, 372]],
  },
  {
    daysAgo: 1,
    title: 'Chạy bộ buổi tối',
    hour: 18,
    minute: 22,
    cadence: 160,
    legs: [[1000, 467], [1000, 446], [1000, 439], [1000, 446], [1000, 481],
      [1000, 467], [1000, 467], [1000, 461], [1000, 685], [1000, 472],
      [600, 448]],
  },
];

/* --- the route: one loop around Duy Tiên, run until the distance is up --- */
const M_PER_DEG_LAT = 111_320;
const ORIGIN = { lat: 20.62, lng: 105.97 };
const LOOP_M = 5300;

const toRad = (deg) => (deg * Math.PI) / 180;
const metresBetween = (a, b) => {
  const dLat = (b.lat - a.lat) * M_PER_DEG_LAT;
  const dLng = (b.lng - a.lng) * M_PER_DEG_LAT * Math.cos(toRad(ORIGIN.lat));
  return Math.hypot(dLat, dLng);
};

/**
 * A closed loop as a wobbling circle, so the line reads as streets rather than
 * as a perfect ring. The radius is scaled until the loop measures LOOP_M on the
 * ground, because the server derives distance from the GPS points — a route
 * that is geometrically 12 km long is a 12 km run however the samples are
 * labelled. Anything past one lap runs the same roads again, which is the case
 * the map has to draw legibly.
 */
function buildLoop() {
  const STEPS = 4000;
  const shape = (u) => (1 + 0.18 * Math.sin(3 * u) + 0.08 * Math.cos(5 * u));
  const at = (u, radiusScale) => {
    const r = radiusScale * shape(u);
    return {
      lat: ORIGIN.lat + (r * Math.cos(u)) / M_PER_DEG_LAT,
      lng: ORIGIN.lng + (r * Math.sin(u)) / (M_PER_DEG_LAT * Math.cos(toRad(ORIGIN.lat))),
      // 3 m to 17 m and back, twice around the loop.
      ele: 10 + 7 * Math.sin(u * 2 - 0.6),
    };
  };

  const base = LOOP_M / (2 * Math.PI);
  let arc = 0;
  for (let i = 1; i <= STEPS; i++) {
    arc += metresBetween(at(((i - 1) / STEPS) * 2 * Math.PI, base), at((i / STEPS) * 2 * Math.PI, base));
  }
  const radius = base * (LOOP_M / arc);

  const points = [];
  const cumulative = [0];
  for (let i = 0; i <= STEPS; i++) {
    points.push(at((i / STEPS) * 2 * Math.PI, radius));
    if (i > 0) cumulative.push(cumulative[i - 1] + metresBetween(points[i - 1], points[i]));
  }
  return { points, cumulative, length: cumulative[STEPS] };
}

const LOOP = buildLoop();

/** The point `distanceM` into the run, wrapping around the loop. */
function pointAt(distanceM) {
  const d = distanceM % LOOP.length;
  let lo = 0;
  let hi = LOOP.cumulative.length - 1;
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1;
    if (LOOP.cumulative[mid] <= d) lo = mid; else hi = mid;
  }
  const span = LOOP.cumulative[hi] - LOOP.cumulative[lo];
  const f = span > 0 ? (d - LOOP.cumulative[lo]) / span : 0;
  const a = LOOP.points[lo];
  const b = LOOP.points[hi];
  return {
    lat: a.lat + (b.lat - a.lat) * f,
    lng: a.lng + (b.lng - a.lng) * f,
    ele: a.ele + (b.ele - a.ele) * f,
  };
}

function syntheticStream(startMs, legs) {
  const samples = [];
  let d = 0;
  let t = 0;
  for (const [legM, paceSecPerKm] of legs) {
    const legSeconds = Math.round((legM / 1000) * paceSecPerKm);
    const stepM = legM / legSeconds;
    for (let i = 0; i < legSeconds; i++) {
      d += stepM;
      t += 1;
      const p = pointAt(d);
      samples.push({
        t: startMs + t * 1000,
        lat: Number(p.lat.toFixed(7)),
        lng: Number(p.lng.toFixed(7)),
        ele: Math.round(p.ele * 10) / 10,
      });
    }
  }
  return samples.map((x) => JSON.stringify(x)).join('\n');
}

const types = await api('GET', '/v1/catalog/activity-types?locale=vi');
const running = types.items.find((t) => t.code === 'running');

async function seed(spec) {
  const distanceM = spec.legs.reduce((sum, [m]) => sum + m, 0);
  const seconds = Math.round(spec.legs.reduce((sum, [m, pace]) => sum + (m / 1000) * pace, 0));

  const day = new Date(Date.now() - spec.daysAgo * 86_400_000);
  day.setUTCHours(spec.hour - 7, spec.minute ?? 0, 0, 0);
  const startedAt = day.getTime();

  const session = await api('POST', '/v1/workouts', {
    activityTypeId: running.id,
    startedAt,
    endedAt: startedAt + seconds * 1000,
    durationSeconds: seconds,
    movingSeconds: seconds,
    distanceM,
    avgCadence: spec.cadence,
    title: spec.title,
  });

  const bytes = Buffer.from(syntheticStream(startedAt, spec.legs), 'utf8');
  const reservation = await api('POST', '/v1/media/upload-url', {
    kind: 'workout_stream', mimeType: 'application/x-ndjson', byteSize: bytes.length,
  });
  const put = await fetch(`${base}/v1/media/${reservation.assetId}/content`, {
    method: 'PUT',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/x-ndjson' },
    body: bytes,
  });
  if (!put.ok) throw new Error(`stream upload -> ${put.status} ${await put.text()}`);
  await api('POST', `/v1/media/${reservation.assetId}/complete`);
  const applied = await api('PUT', `/v1/workouts/${session.id}/stream`, {
    assetId: reservation.assetId,
  });

  console.log(`${spec.title}: ${(distanceM / 1000).toFixed(2)} km asked, `
    + `${applied.sampleCount} samples, ${applied.splits} splits`);
  return session.id;
}

// Seeding twice would leave the new runs ranked behind their own earlier
// copies, so anything this script wrote before is cleared out first.
const titles = new Set(RUNS.map((r) => r.title));
const existing = await api('GET', '/v1/workouts?limit=100');
for (const s of existing.items ?? []) {
  if (titles.has(s.title)) await api('DELETE', `/v1/workouts/${s.id}`);
}

let lastId = null;
for (const spec of RUNS) lastId = await seed(spec);

const detail = await api('GET', `/v1/workouts/${lastId}`);
console.log(`\nderived: ${(detail.distanceM / 1000).toFixed(2)} km`
  + `, pace ${Math.round(detail.avgPaceSecPerKm)} s/km`
  + `, GAP ${detail.gapSecPerKm} s/km`
  + `, +${Math.round(detail.elevationGainM)} m, max ${detail.elevationMaxM} m`
  + `, ${detail.steps} steps`);
console.log(`best efforts: ${detail.bestEfforts
  .map((e) => `${e.distanceM}m #${e.rank} ${Math.round(e.elapsedSeconds)}s`).join(', ')}`);
console.log(`counters: ${JSON.stringify(detail.effortCounters)}`);
console.log(`predictions: ${detail.predictions
  .map((p) => `${p.distanceM}m ${p.seconds}s`).join(', ')}`);
console.log(`improved: ${JSON.stringify(detail.predictionImproved)}`);
console.log(`pace zones (5k basis ${detail.paceZoneBasisSeconds}s): ${detail.paceZones
  .map((z) => `Z${z.zoneNumber} ${z.percentOfSession}%`).join(' ')}`);
console.log(`\nopen: /workouts/${lastId}`);
