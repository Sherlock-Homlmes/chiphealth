/**
 * Fills the local dev account with a realistic fortnight of data so every screen
 * has something to show. Goes through the HTTP API, not straight into D1, so it
 * exercises the same code paths the app does — rollups, sleep debt and PR
 * detection all run for real.
 *
 *   node scripts/dev-demo-data.mjs [email] [apiBase]
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
const secret = vars.JWT_SECRET;
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
const now = Math.floor(Date.now() / 1000);
const head = `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({
  sub: userId, email, role: 'admin', tz, locale: 'vi', iat: now, exp: now + 3600,
})}`;
const token = `${head}.${createHmac('sha256', secret).update(head).digest('base64url')}`;

const api = async (method, path, body) => {
  const res = await fetch(base + path, {
    method,
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${path} -> ${res.status} ${text.slice(0, 200)}`);
  return text ? JSON.parse(text) : null;
};

const DAY = 86_400_000;
const at = (daysAgo, hour, minute = 0) => {
  const d = new Date(Date.now() - daysAgo * DAY);
  // The API derives local_date from the timestamp, so ICT offset matters here.
  d.setUTCHours(hour - 7, minute, 0, 0);
  return d.getTime();
};

console.log(`seeding ${email}\n`);

await api('PUT', '/v1/me/profile', {
  dateOfBirth: '1995-05-20',
  biologicalSex: 'male',
  activityLevel: 'moderate',
  targetSleepMinutes: 480,
  bedtimeTarget: '23:00',
  waketimeTarget: '07:00',
});
console.log('  profile');

// A weight trend, so the chart has a shape rather than a single dot.
for (let i = 13; i >= 0; i--) {
  await api('POST', '/v1/me/body-metrics', {
    recordedAt: at(i, 7),
    weightKg: Math.round((74.5 - (13 - i) * 0.12) * 10) / 10,
    heightCm: 175,
    bodyFatPercent: Math.round((21 - (13 - i) * 0.08) * 10) / 10,
  });
}
console.log('  14 body-metric entries');

await api('POST', '/v1/me/goals', {
  goalType: 'lose_weight', targetValue: 70, targetUnit: 'kg', deadline: '2026-12-31',
});
// Endurance has no derivable baseline (unlike weight, which reads the latest
// body metric), so the API insists on an explicit startValue.
await api('POST', '/v1/me/goals', {
  goalType: 'improve_endurance', targetValue: 15, targetUnit: 'km', startValue: 5,
});
await api('POST', '/v1/me/conditions', { description: 'Trào ngược dạ dày, hạn chế đồ cay và ăn muộn' });
console.log('  2 goals + 1 chronic condition');

// Sleep: three short nights early on, so the 14-day rolling debt is non-zero.
const stagesFor = (start, end) => {
  const out = [];
  const cycle = ['light', 'deep', 'rem', 'light'];
  for (let t = start, i = 0; t < end; t += 30 * 60_000, i++) {
    out.push({ stage: cycle[i % cycle.length], startedAt: t, endedAt: Math.min(t + 30 * 60_000, end) });
  }
  return out;
};

for (let i = 9; i >= 0; i--) {
  const hours = i > 6 ? 5.5 : i === 3 ? 6 : 7.8;
  const start = at(i + 1, 23);
  const end = start + hours * 3_600_000;
  await api('POST', '/v1/sleep/sessions', {
    source: 'phone_mic',
    startedAt: start,
    endedAt: end,
    stages: stagesFor(start, end),
    events: i % 3 === 0
      ? [
          { eventType: 'snore', occurredAt: start + 4_200_000, durationMs: 14_000, peakDb: 63, confidence: 0.82 },
          { eventType: 'sleep_talk', occurredAt: start + 9_600_000, durationMs: 3_500, peakDb: 51, confidence: 0.6 },
        ]
      : [],
    audioRecordingEnabled: true,
  });
}
console.log('  10 nights (3 short, snore + sleep-talk events)');

const types = await api('GET', '/v1/catalog/activity-types?locale=vi');
const running = types.items.find((t) => t.code === 'running') ?? types.items[0];
const gym = types.items.find((t) => t.code === 'gym_strength') ?? types.items[0];

const runs = [];
for (const [daysAgo, distanceKm, minutes] of [[8, 5.2, 29], [5, 8.1, 46], [2, 10.4, 58]]) {
  const start = at(daysAgo, 6);
  runs.push(await api('POST', '/v1/workouts', {
    activityTypeId: running.id,
    startedAt: start,
    endedAt: start + minutes * 60_000,
    durationSeconds: minutes * 60,
    movingSeconds: minutes * 60 - 40,
    distanceM: distanceKm * 1000,
    avgHeartRate: 150 + Math.round(distanceKm),
    maxHeartRate: 172,
    elevationGainM: 30 + distanceKm,
    caloriesBurnedKcal: Math.round(distanceKm * 65),
    title: `Chạy ${distanceKm} km`,
  }));
  runs[runs.length - 1].distanceKm = distanceKm;
  runs[runs.length - 1].minutes = minutes;
}
const gymStart = at(3, 18);
await api('POST', '/v1/workouts', {
  activityTypeId: gym.id,
  startedAt: gymStart,
  endedAt: gymStart + 55 * 60_000,
  durationSeconds: 55 * 60,
  caloriesBurnedKcal: 320,
  title: 'Đẩy ngực + vai',
});
console.log('  4 workouts');

/**
 * A synthetic 1 Hz GPS + heart-rate trace, uploaded the way the recorder does.
 * This is the only way to populate splits, time-in-zone and personal records:
 * the server derives all three from the stream, and stores no per-point rows.
 */
function syntheticStream(startMs, distanceM, seconds) {
  const samples = [];
  const stepM = distanceM / seconds;
  const M_PER_DEG_LAT = 111_320;
  let lat = 10.7769;
  let lng = 106.7009;
  for (let s = 0; s <= seconds; s++) {
    // Move on a heading rather than in both axes at once: adding a full step to
    // latitude AND longitude walks the hypotenuse and inflates the distance the
    // server derives (which is what the app then displays).
    const heading = (s / 240) % (2 * Math.PI);
    const mPerDegLng = M_PER_DEG_LAT * Math.cos((lat * Math.PI) / 180);
    lat += (stepM * Math.cos(heading)) / M_PER_DEG_LAT;
    lng += (stepM * Math.sin(heading)) / mPerDegLng;
    samples.push({
      t: startMs + s * 1000,
      lat: Number(lat.toFixed(7)),
      lng: Number(lng.toFixed(7)),
      ele: 8 + Math.round(6 * Math.sin(s / 200)),
      hr: Math.round(145 + 18 * Math.sin(s / 240) + (s > seconds * 0.8 ? 12 : 0)),
      speed: stepM,
    });
  }
  return samples.map((x) => JSON.stringify(x)).join('\n');
}

async function uploadStream(session) {
  const ndjson = syntheticStream(session.startedAt, session.distanceKm * 1000, session.minutes * 60);
  const bytes = Buffer.from(ndjson, 'utf8');

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
  return api('PUT', `/v1/workouts/${session.id}/stream`, { assetId: reservation.assetId });
}

let newRecords = 0;
for (const run of runs) {
  const result = await uploadStream(run);
  newRecords += result.newRecords?.length ?? 0;
  console.log(`    ${run.title}: ${result.sampleCount} samples, ${result.splits} splits, `
    + `${result.zones} zones, ${result.newRecords?.length ?? 0} PR`);
}
console.log(`  3 GPS streams uploaded (${newRecords} personal records detected)`);

const MEALS = [
  [0, 'breakfast', 'Bánh mì thịt', [['Bánh mì', 90, 240, 8, 45, 3], ['Thịt nguội', 60, 160, 12, 1, 12], ['Rau dưa góp', 40, 15, 1, 3, 0]]],
  [0, 'lunch', 'Cơm tấm sườn nướng', [['Cơm trắng', 250, 325, 7, 71, 1], ['Sườn nướng', 150, 380, 28, 6, 26], ['Đồ chua', 50, 20, 1, 4, 0]]],
  [1, 'dinner', 'Bún chả', [['Bún', 200, 220, 4, 50, 0], ['Chả nướng', 120, 300, 22, 4, 21], ['Rau sống', 80, 25, 2, 4, 0]]],
];

for (const [daysAgo, mealType, note, items] of MEALS) {
  const meal = await api('POST', '/v1/meals', {
    mealType, loggedAt: at(daysAgo, mealType === 'breakfast' ? 7 : mealType === 'lunch' ? 12 : 19), note,
  });
  for (const [name, grams, kcal, protein, carbs, fat] of items) {
    await api('POST', `/v1/meals/${meal.id}/items?learn=false`, {
      ingredientName: name, quantityG: grams, caloriesKcal: kcal,
      proteinG: protein, carbsG: carbs, fatG: fat,
      sugarG: Math.round(carbs * 0.1), sodiumMg: Math.round(grams * 3),
    });
  }
}
console.log('  3 meals with per-ingredient breakdown');

const daily = await api('GET', '/v1/nutrition/daily');
const debt = await api('GET', '/v1/sleep/debt');
const records = await api('GET', '/v1/training/records');

console.log(`
done.
  today      ${Math.round(daily.summary?.caloriesConsumedKcal ?? 0)} kcal vs TDEE ${Math.round(daily.energy?.tdeeKcal ?? 0)}
  sleep debt ${(debt.rollingDebtSeconds / 3600).toFixed(1)}h over ${debt.windowDays} days (${debt.daysRecorded} nights recorded)
  records    ${records.items.length}
`);
