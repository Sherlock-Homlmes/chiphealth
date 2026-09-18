/**
 * Pure-logic tests. Bundled with esbuild and run on node — no Worker runtime and
 * no D1 needed, which keeps them fast enough to run on every change.
 *   npm test
 */
import { localDate, addDays, dateRange, ageFromDob } from '../src/lib/time';
import { bmrMifflinStJeor, tdee, activityMultiplier } from '../src/services/nutritionMath';
import { encodePolyline, decodePolyline, computeZoneRanges, haversineMeters } from '../src/services/workoutStream';
import { fastestForDistance, isBetter } from '../src/services/personalRecords';
import { rollingDebtSeconds } from '../src/services/sleepDebt';
import {
  extractJson, parseComponents, foodNameFits, effectiveAnalysis, MEAL_ANALYSIS_TIMEOUT_MS, ANALYSIS_TIMEOUT_MESSAGE,
} from '../src/services/mealAnalysis';
import { toFtsQuery } from '../src/services/foodSearch';
import { parseCsv } from '../src/routes/admin/foods';
import { insertMany, D1_MAX_BOUND_PARAMS } from '../src/db/client';

let passed = 0;
let failed = 0;

function check(name: string, actual: unknown, expected: unknown): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) {
    passed++;
    console.log(`  ok  ${name}`);
  } else {
    failed++;
    console.log(`FAIL  ${name}\n        expected ${e}\n        actual   ${a}`);
  }
}

function near(name: string, actual: number, expected: number, tolerance = 0.5): void {
  if (Math.abs(actual - expected) <= tolerance) {
    passed++;
    console.log(`  ok  ${name}`);
  } else {
    failed++;
    console.log(`FAIL  ${name}\n        expected ~${expected}\n        actual    ${actual}`);
  }
}

console.log('\n# time');
// 2026-01-01T00:30Z is already the 1st in Asia/Ho_Chi_Minh (+7) but still the
// 31st in New York (-5) — the reason every log row stores its own local_date.
check('localDate ICT', localDate(Date.parse('2026-01-01T00:30:00Z'), 'Asia/Ho_Chi_Minh'), '2026-01-01');
check('localDate NY', localDate(Date.parse('2026-01-01T00:30:00Z'), 'America/New_York'), '2025-12-31');
check('addDays across month', addDays('2026-01-31', 1), '2026-02-01');
check('addDays across year backwards', addDays('2026-01-01', -1), '2025-12-31');
check('addDays leap day', addDays('2028-02-28', 1), '2028-02-29');
check('dateRange inclusive', dateRange('2026-03-01', '2026-03-04').length, 4);
check('ageFromDob before birthday', ageFromDob('2000-12-31', Date.parse('2026-06-01T00:00:00Z')), 25);
check('ageFromDob after birthday', ageFromDob('2000-01-01', Date.parse('2026-06-01T00:00:00Z')), 26);

console.log('\n# BMR / TDEE (Mifflin-St Jeor)');
// Reference: 70 kg, 175 cm, 30 y male => 10*70 + 6.25*175 - 5*30 + 5 = 1648.75
near('male BMR', bmrMifflinStJeor({ weightKg: 70, heightCm: 175, age: 30, sex: 'male' }), 1648.75);
// Same body, female => -161 instead of +5 => 1482.75
near('female BMR', bmrMifflinStJeor({ weightKg: 70, heightCm: 175, age: 30, sex: 'female' }), 1482.75);
check('sedentary multiplier', activityMultiplier('sedentary'), 1.2);
check('very_active multiplier', activityMultiplier('very_active'), 1.9);
check('null multiplier falls back to moderate', activityMultiplier(null), 1.55);
near('TDEE moderate', tdee(1648.75, 'moderate'), 1648.75 * 1.55, 1);

console.log('\n# polyline');
// The reference example from Google's encoded-polyline specification.
const REFERENCE = '_p~iF~ps|U_ulLnnqC_mqNvxq`@';
check('encode reference', encodePolyline([[38.5, -120.2], [40.7, -120.95], [43.252, -126.453]]), REFERENCE);
check('decode round-trip', decodePolyline(REFERENCE), [[38.5, -120.2], [40.7, -120.95], [43.252, -126.453]]);
near('haversine ~1 deg latitude', haversineMeters(0, 0, 1, 0), 111195, 100);

console.log('\n# HR zones');
const zones = computeZoneRanges(190);
check('five zones', zones.length, 5);
check('Z1 lower bound is 50% of max', zones[0]!.minBpm, 95);
check('Z5 upper bound is max', zones[4]!.maxBpm, 190);
check('zones do not overlap', zones.every((z, i) => i === 0 || z.minBpm > zones[i - 1]!.maxBpm), true);

console.log('\n# personal records');
// 6 km at a steady 5:00/km, with km 3-4 run at 4:00/km.
const cumulative = [
  { d: 0, t: 0 }, { d: 1000, t: 300 }, { d: 2000, t: 600 }, { d: 3000, t: 840 },
  { d: 4000, t: 1080 }, { d: 5000, t: 1380 }, { d: 6000, t: 1680 },
];
check('fastest 1k finds the quick km', fastestForDistance(cumulative, 1000), 240);
// The best 5k window is km 1-6 (1680-300 = 1380) vs km 0-5 (1380). Equal, so 1380.
check('fastest 5k', fastestForDistance(cumulative, 5000), 1380);
check('distance longer than the run has no PR', fastestForDistance(cumulative, 10000), null);
check('lower time is better', isBetter('fastest_distance', 240, 300), true);
check('higher weight is better', isBetter('max_weight', 105, 100), true);
check('equalling a PR is not beating it', isBetter('max_weight', 100, 100), false);

console.log('\n# sleep debt (14-day rolling window)');
const target = 8 * 3600;
const days = dateRange('2026-03-01', '2026-03-16').map((localDate, i) => {
  const actual = i < 4 ? 5 * 3600 : 8 * 3600;   // four short nights at the start
  return { localDate, targetSleepSeconds: target, actualSleepSeconds: actual,
           dailyDiffSeconds: actual - target, hasData: true };
});
// Window 03-03..03-16 keeps only two of the four short nights: 2 x 3h = 6h.
check('debt inside the window', rollingDebtSeconds(days, '2026-03-16', 14), 6 * 3600);
// Window 03-01..03-14 keeps all four: 4 x 3h = 12h.
check('debt earlier in the window', rollingDebtSeconds(days, '2026-03-14', 14), 12 * 3600);
// A 10h surplus night must NOT repay the debt — it only stops adding to it.
const withSurplus = days.map((d, i) =>
  i === 10 ? { ...d, actualSleepSeconds: 10 * 3600, dailyDiffSeconds: 2 * 3600 } : d);
check('surplus does not cancel debt', rollingDebtSeconds(withSurplus, '2026-03-14', 14), 12 * 3600);
// Untracked nights are unknown, not zero: a new account must not owe a fortnight.
const untracked = days.map((d, i) => (i >= 4 ? { ...d, hasData: false } : d));
check('untracked nights add no debt', rollingDebtSeconds(untracked, '2026-03-14', 14), 12 * 3600);
check('no data at all means no debt',
  rollingDebtSeconds(days.map((d) => ({ ...d, hasData: false })), '2026-03-14', 14), 0);

console.log('\n# model output parsing');
check('JSON after prose', extractJson('Here you go:\n```json\n[{"name":"cơm"}]\n```'), [{ name: 'cơm' }]);
check('braces inside a string do not end the object',
  extractJson('{"note":"a } brace","n":1}'), { note: 'a } brace', n: 1 });
check('components default to 100 g when absent',
  parseComponents([{ name: 'rau muống' }]), [{ name: 'rau muống', grams: 100, label: undefined, confidence: undefined }]);
check('nameless entries are dropped', parseComponents([{ grams: 50 }, { name: 'gà', grams: 80 }]).length, 1);
let threw = false;
try { extractJson('no json at all'); } catch { threw = true; }
check('missing JSON throws', threw, true);

console.log('\n# food-base match must be the named food');
check('same name is exact', foodNameFits('Cơm trắng', 'cơm trắng'), 'exact');
check('a prefix is not a match ("trà" is not "Cơm trắng")', foodNameFits('Trà', 'Cơm trắng'), null);
check('a shared word is not a match', foodNameFits('Thịt bò', 'Phở bò'), null);
check('a more specific dish fits its base food', foodNameFits('phở bò tái', 'Phở bò'), 'contained');
check('an unmentioned filling does not fit', foodNameFits('Bánh mì', 'Bánh mì thịt'), null);
check('diacritics count when written', foodNameFits('trà', 'tra'), null);
check('unaccented input still matches', foodNameFits('pho bo', 'Phở bò'), 'exact');

console.log('\n# analysis timeout (3 minutes, read-side)');
const NOW = Date.parse('2026-09-09T12:00:00Z');
const run = (status: string, ageMs: number, errorMessage: string | null = null) =>
  ({ status, createdAt: NOW - ageMs, errorMessage });
check('timeout is three minutes', MEAL_ANALYSIS_TIMEOUT_MS, 180_000);
check('fresh run stays running', effectiveAnalysis(run('running', 60_000), NOW),
  { status: 'running', createdAt: NOW - 60_000, errorMessage: null, timedOut: false });
check('run past the deadline reads as failed',
  effectiveAnalysis(run('running', MEAL_ANALYSIS_TIMEOUT_MS + 1), NOW),
  { status: 'failed', createdAt: NOW - MEAL_ANALYSIS_TIMEOUT_MS - 1, errorMessage: ANALYSIS_TIMEOUT_MESSAGE, timedOut: true });
check('exactly at the deadline is still running',
  effectiveAnalysis(run('pending', MEAL_ANALYSIS_TIMEOUT_MS), NOW).status, 'pending');
check('pending hangs are timed out too',
  effectiveAnalysis(run('pending', MEAL_ANALYSIS_TIMEOUT_MS + 2_000), NOW).timedOut, true);
check('a completed row is never folded',
  effectiveAnalysis(run('completed', 10 * MEAL_ANALYSIS_TIMEOUT_MS), NOW),
  { status: 'completed', createdAt: NOW - 10 * MEAL_ANALYSIS_TIMEOUT_MS, errorMessage: null, timedOut: false });
check('a genuinely failed row keeps its own error',
  effectiveAnalysis(run('failed', 10 * MEAL_ANALYSIS_TIMEOUT_MS, 'upstream 5016'), NOW),
  { status: 'failed', createdAt: NOW - 10 * MEAL_ANALYSIS_TIMEOUT_MS, errorMessage: 'upstream 5016', timedOut: false });
check('missing createdAt cannot be judged', effectiveAnalysis(
  { status: 'running', createdAt: null, errorMessage: null }, NOW).status, 'running');

console.log('\n# FTS query building');
check('tokens become prefix ORs', toFtsQuery('cơm gà'), '"cơm"* OR "gà"*');
check('punctuation is stripped', toFtsQuery('bún! chả?'), '"bún"* OR "chả"*');
check('empty input yields empty query', toFtsQuery('   '), '');
check('quotes cannot break out', toFtsQuery('a"b'), '"a"* OR "b"*');

console.log('\n# CSV import');
check('plain row', parseCsv('a,b\n1,2'), [['a', 'b'], ['1', '2']]);
check('quoted comma stays one field', parseCsv('name,kcal\n"Cơm gà, đùi",650'),
  [['name', 'kcal'], ['Cơm gà, đùi', '650']]);
check('doubled quotes unescape', parseCsv('a\n"say ""hi"""'), [['a'], ['say "hi"']]);
check('CRLF is handled', parseCsv('a,b\r\n1,2\r\n'), [['a', 'b'], ['1', '2']]);
check('blank lines are dropped', parseCsv('a\n\n1\n'), [['a'], ['1']]);

console.log('\n# D1 bound-parameter chunking');
{
  const wide = Array.from({ length: 60 }, (_, i) => ({
    a: i, b: i, c: i, d: i, e: i, f: i, g: i, h: i,  // 8 columns
  }));
  const batches: number[] = [];
  await insertMany(async (chunk) => { batches.push(chunk.length); }, wide);
  check('splits a wide insert into batches', batches.length > 1, true);
  check('every batch stays under the D1 parameter cap',
    batches.every((n) => n * 8 <= D1_MAX_BOUND_PARAMS), true);
  check('no rows are lost', batches.reduce((a, b) => a + b, 0), wide.length);

  const narrow = Array.from({ length: 3 }, (_, i) => ({ a: i, b: i }));
  const single: number[] = [];
  await insertMany(async (chunk) => { single.push(chunk.length); }, narrow);
  check('a small insert stays a single statement', single, [3]);

  const none: number[] = [];
  await insertMany(async (chunk) => { none.push(chunk.length); }, []);
  check('an empty insert issues no statement', none, []);
}

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
