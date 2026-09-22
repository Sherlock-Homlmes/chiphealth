import { and, desc, eq, inArray } from 'drizzle-orm';
import {
  foods, userFoods, mealLogs, mealItems, mealAiAnalyses,
} from '../db/schema';
import { modelConfig } from '../config/models';
import { hybridFoodSearch, type Candidate } from './foodSearch';
import { recomputeDailyNutritionSummary } from './nutritionMath';
import { ApiError } from '../lib/errors';
import { insertMany } from '../db/client';
import { aiText, toDataUri, withTimeout } from '../lib/aiText';
import type { Db } from '../db/client';
import type { Bindings } from '../env';
import { PROMPTS, renderPrompt } from '../prompts';

const NUTRIENT_KEYS = [
  'caloriesKcal', 'proteinG', 'carbsG', 'fatG', 'saturatedFatG',
  'fiberG', 'sugarG', 'sodiumMg', 'cholesterolMg',
] as const;
type NutrientKey = typeof NUTRIENT_KEYS[number];
type Nutrients = Partial<Record<NutrientKey, number | null>>;

export interface DetectedComponent {
  name: string;
  grams: number;
  label?: string;
  confidence?: number;
  /**
   * Fluid this component carries, in ml. Comes from the model and is kept on
   * the component rather than folded into [NUTRIENT_KEYS]: those are scaled
   * from a food-base row, and the food base has no water column, so a matched
   * food would silently lose the estimate.
   */
  waterMl?: number;
}

/**
 * How long one analysis attempt may run. A hung model or a consumer that died
 * leaves the row `running` forever, so every reader applies the same clock:
 * past this point a still-active attempt is reported as failed (timed out).
 */
export const MEAL_ANALYSIS_TIMEOUT_MS = 10 * 60_000;

export const ANALYSIS_TIMEOUT_MESSAGE = 'Phân tích kéo dài quá 10 phút';

/**
 * What one attempt actually gives itself. The run has to be *written* before
 * [MEAL_ANALYSIS_TIMEOUT_MS], not merely still going at it, so the pipeline
 * works to an earlier deadline and spends the difference closing the row out.
 * Past this point the remaining model calls are skipped rather than started:
 * a meal with a few unpriced components beats "phân tích kéo dài quá 10 phút".
 */
export const MEAL_ANALYSIS_BUDGET_MS = MEAL_ANALYSIS_TIMEOUT_MS - 45_000;

/**
 * Time held back from the detection call for everything after it — the food
 * lookups, the estimates and the writes. Without it a slow vision model eats
 * the whole budget and the components it found are never priced.
 */
const RESOLVE_RESERVE_MS = 90_000;

/** Kept back from the last model call for the writes that close the run out. */
const WRITE_RESERVE_MS = 15_000;

export interface AnalysisLike {
  status: string;
  createdAt: number | null;
  errorMessage: string | null;
}

/**
 * The read-side half of the timeout contract. The row itself is left alone
 * (only the cron sweeper and the run's own completion write to it); readers
 * just see a run that is past the deadline as failed, with `timedOut` set so
 * the client can say "took too long, try again" instead of a generic error.
 */
export function effectiveAnalysis<T extends AnalysisLike>(
  a: T, now = Date.now(),
): T & { timedOut: boolean } {
  const active = a.status === 'running' || a.status === 'pending';
  if (active && a.createdAt !== null && now - a.createdAt > MEAL_ANALYSIS_TIMEOUT_MS) {
    return { ...a, status: 'failed', errorMessage: ANALYSIS_TIMEOUT_MESSAGE, timedOut: true };
  }
  return { ...a, timedOut: false };
}

/**
 * What a re-run of a meal would be given, or null when there is nothing to run.
 *
 * A photo meal re-runs its photo, which is still in R2. A spoken or typed one
 * re-runs the words it was given: the clip was thrown away after ASR, but the
 * transcript is kept on the attempt (meal_ai_analyses.input_text), so a failed
 * voice meal is as retryable as a photo one. Null is the leftover case — no
 * photo, and every attempt on this meal predates that column — and it is the
 * only one the retry endpoint refuses.
 */
export function retryableInput(
  photoR2Key: string | null | undefined, lastInputText: string | null | undefined,
): { kind: 'photo'; photoR2Key: string } | { kind: 'speech'; transcript: string } | null {
  if (photoR2Key) return { kind: 'photo', photoR2Key };
  const transcript = lastInputText?.trim();
  return transcript ? { kind: 'speech', transcript } : null;
}

/**
 * Models wrap JSON in prose or fences no matter how firm the instruction is, so
 * pull out the first balanced JSON value instead of trusting the whole response.
 *
 * A busy plate is the case that breaks: the model lists fifteen components, runs
 * into its token ceiling and stops mid-object, and the whole meal used to fail
 * over the tail. So a value that never closes is repaired instead — cut back to
 * the last element that did finish and closed off — and the meal is logged with
 * the components the model got to.
 */
export function extractJson(text: string): unknown {
  const start = text.search(/[[{]/);
  if (start === -1) throw new ApiError('UPSTREAM_AI_ERROR', 'Model returned no JSON');

  const stack: string[] = [];
  let inString = false;
  let escaped = false;
  /** Last index at which a value finished, with the brackets still open there. */
  let cut = -1;
  let cutStack: string[] = [];

  for (let i = start; i < text.length; i++) {
    const ch = text[i]!;
    if (inString) {
      if (escaped) escaped = false;
      else if (ch === '\\') escaped = true;
      else if (ch === '"') inString = false;
      continue;
    }
    if (ch === '"') inString = true;
    else if (ch === '[' || ch === '{') stack.push(ch === '[' ? ']' : '}');
    else if (ch === ']' || ch === '}') {
      stack.pop();
      if (stack.length === 0) {
        try {
          return JSON.parse(text.slice(start, i + 1));
        } catch {
          throw new ApiError('UPSTREAM_AI_ERROR', 'Model JSON is malformed');
        }
      }
      cut = i;
      cutStack = [...stack];
    } else if (ch === ',') {
      // Everything before the comma is a value that finished, whatever its kind.
      cut = i - 1;
      cutStack = [...stack];
    }
  }

  if (cut > start) {
    try {
      return JSON.parse(text.slice(start, cut + 1) + cutStack.reverse().join(''));
    } catch {
      // Falls through to the truncation error below.
    }
  }
  throw new ApiError('UPSTREAM_AI_ERROR', 'Model JSON is truncated');
}

/** The dish as a whole, e.g. "bún riêu cua". Absent when the model only listed parts. */
export function parseDishName(raw: unknown): string | null {
  const name = (raw as { dish?: unknown; dishName?: unknown })?.dish
    ?? (raw as { dishName?: unknown })?.dishName;
  if (typeof name !== 'string') return null;
  const trimmed = name.trim();
  return trimmed.length > 0 && trimmed.length <= 120 ? trimmed : null;
}

export function parseComponents(raw: unknown): DetectedComponent[] {
  const arr = Array.isArray(raw)
    ? raw
    : (raw as { items?: unknown[] })?.items ?? (raw as { components?: unknown[] })?.components;
  if (!Array.isArray(arr)) throw new ApiError('UPSTREAM_AI_ERROR', 'Unexpected model shape');

  return arr.flatMap((entry): DetectedComponent[] => {
    const e = entry as Record<string, unknown>;
    const name = typeof e.name === 'string' ? e.name.trim() : '';
    if (!name) return [];
    const grams = Number(e.grams ?? e.quantity_g ?? e.quantityG);
    const waterMl = Number(e.waterMl ?? e.water_ml ?? e.water);
    return [{
      name,
      grams: Number.isFinite(grams) && grams > 0 ? grams : 100,
      label: typeof e.label === 'string' ? e.label : undefined,
      confidence: Number.isFinite(Number(e.confidence)) ? Number(e.confidence) : undefined,
      // A model that says nothing about water leaves it unknown; 0 would be a
      // claim that the component is bone dry.
      waterMl: Number.isFinite(waterMl) && waterMl >= 0
        ? Math.round(waterMl)
        : undefined,
    }];
  });
}

function nameTokens(name: string, stripMarks: boolean): string[] {
  let s = name.normalize('NFC').toLowerCase();
  if (stripMarks) s = s.normalize('NFD').replace(/\p{M}/gu, '').replace(/đ/g, 'd');
  return s.split(/[^\p{L}\p{N}]+/u).filter((t) => t.length > 0);
}

/**
 * Whether a food-base row is the thing the component names, not merely a row
 * that shares a prefix with it. Search is prefix-OR on purpose (it feeds
 * search-as-you-type), so "trà" finds "Cơm trắng" and "thịt bò" finds
 * "Phở bò" — fine for a list to pick from, wrong as the source of a meal's
 * calories. A row fits when every word of its name is a word of the component:
 * "phở bò tái" is a "Phở bò", but "bánh mì" is not a "Bánh mì thịt" — that
 * would add a filling nobody mentioned. Diacritics only count when the model
 * wrote them; "pho bo" still reaches "Phở bò".
 */
export function foodNameFits(component: string, foodName: string): 'exact' | 'contained' | null {
  const strip = nameTokens(component, true).join(' ') === nameTokens(component, false).join(' ');
  const comp = nameTokens(component, strip);
  const food = nameTokens(foodName, strip);
  if (comp.length === 0 || food.length === 0) return null;
  if (comp.join(' ') === food.join(' ')) return 'exact';
  const words = new Set(comp);
  return food.every((t) => words.has(t)) ? 'contained' : null;
}

/**
 * A vector-only hit carries no words to check, so it has to earn its place on
 * similarity alone — high enough that "cơm tẻ" still reaches "Cơm trắng" but a
 * neighbour dish does not.
 */
const VECTOR_ONLY_MIN_SCORE = 0.85;

/** Scale a per-serving nutrition row to the eaten grams. */
function scale(row: Nutrients & { servingSizeG?: number | null }, grams: number): Nutrients {
  const per = row.servingSizeG && row.servingSizeG > 0 ? row.servingSizeG : 100;
  const factor = grams / per;
  const out: Nutrients = {};
  for (const key of NUTRIENT_KEYS) {
    const v = row[key];
    out[key] = typeof v === 'number' ? Math.round(v * factor * 100) / 100 : null;
  }
  return out;
}

type ResolvedSource = 'admin_barcode' | 'admin_manual' | 'rag_matched' | 'web_search' | 'ai_estimated';

interface Resolution {
  source: ResolvedSource;
  confidence: number;
  foodId?: string;
  userFoodId?: string;
  nutrients: Nutrients;
}

/**
 * Resolution order, most trusted first:
 *   the caller's own user_foods  ->  a verified global food  ->  the fused RAG
 *   candidates  ->  web grounding  ->  a bare model estimate.
 * The caller's row wins over the global one because the same dish genuinely
 * differs between households.
 *
 * Returns a null resolution when nothing in the food base fits: the caller
 * collects those and estimates them together, one model call for the lot,
 * instead of one call per component.
 */
async function lookupComponent(
  db: Db, env: Bindings, userId: string, comp: DetectedComponent,
): Promise<{ resolution: Resolution | null; candidates: Candidate[] }> {
  const personal = await db.select().from(userFoods)
    .where(and(eq(userFoods.userId, userId), eq(userFoods.name, comp.name)))
    .limit(1);

  const own = personal[0];
  if (own) {
    return {
      resolution: {
        source: 'rag_matched',
        confidence: 0.95,
        userFoodId: own.id,
        nutrients: scale(own, comp.grams),
      },
      candidates: [],
    };
  }

  const search = await hybridFoodSearch(env, comp.name);
  const foodIds = search.fused.filter((c) => c.kind === 'food').map((c) => c.id);

  if (foodIds.length > 0) {
    const rows = await db.select().from(foods).where(inArray(foods.id, foodIds));
    const byId = new Map(rows.map((r) => [r.id, r]));
    // Only rows that are the named food count; the rest fall through to an
    // estimate. Among those, an exact name beats a contained one, a verified row
    // beats an unverified one, and the fused ordering breaks the remaining ties.
    const ordered = search.fused
      .filter((c) => c.kind === 'food')
      .flatMap((c, rank) => {
        const row = byId.get(c.id);
        if (!row) return [];
        const fit = foodNameFits(comp.name, row.name)
          ?? (c.bm25Rank === undefined && (c.vectorScore ?? 0) >= VECTOR_ONLY_MIN_SCORE
            ? 'contained'
            : null);
        return fit ? [{ row, fit, rank }] : [];
      })
      .sort((a, b) =>
        Number(b.fit === 'exact') - Number(a.fit === 'exact')
        || Number(b.row.isVerified) - Number(a.row.isVerified)
        || a.rank - b.rank);

    const match = ordered[0];
    if (match) {
      const { row: best, fit, rank } = match;
      return {
        resolution: {
          source: best.source === 'admin_barcode' || best.source === 'admin_manual'
            ? best.source
            : 'rag_matched',
          confidence: best.isVerified
            ? (fit === 'exact' ? 0.9 : 0.85)
            : Math.max(0.7 - rank * 0.05, 0.5),
          foodId: best.id,
          nutrients: scale(best, comp.grams),
        },
        candidates: search.fused,
      };
    }
  }

  return { resolution: null, candidates: search.fused };
}

/**
 * Runs `fn` over `items` at most `limit` at a time, in order, keeping every
 * result. A photo of a tray can come back with twenty components, and firing
 * twenty lookups at once puts twenty concurrent subrequests and twenty model
 * calls in flight: Workers AI queues them behind each other and the whole
 * analysis walks into the ten-minute wall. A small pool finishes sooner than
 * an unbounded fan-out that is being rate-limited.
 */
export async function mapPool<T, R>(
  items: readonly T[], limit: number, fn: (item: T, index: number) => Promise<R>,
): Promise<R[]> {
  const out = new Array<R>(items.length);
  let next = 0;
  const workers = Array.from({ length: Math.max(1, Math.min(limit, items.length)) }, async () => {
    for (let i = next++; i < items.length; i = next++) {
      out[i] = await fn(items[i]!, i);
    }
  });
  await Promise.all(workers);
  return out;
}

/**
 * The biggest components first, then the list cut to `max`. A busy plate can
 * come back with forty entries, most of them garnishes: each one is a lookup
 * and possibly an estimate, and the tail of the list is what pushes the run
 * past its budget while adding a few kcal. Dropping by weight keeps the bowl
 * of rice and loses the sprig of coriander.
 */
export function capComponents(
  items: DetectedComponent[], max: number,
): DetectedComponent[] {
  if (items.length <= max) return items;
  const order = new Map(items.map((c, i) => [c, i]));
  return [...items]
    .sort((a, b) => b.grams - a.grams || order.get(a)! - order.get(b)!)
    .slice(0, max)
    .sort((a, b) => order.get(a)! - order.get(b)!);
}

/** Names are matched back loosely: the model likes to re-case and re-space them. */
const estimateKey = (name: string) =>
  name.normalize('NFC').toLowerCase().replace(/\s+/g, ' ').trim();

/**
 * Per-100g values for a batch of names, keyed by [estimateKey]. Entries the
 * model skipped or garbled are simply absent — the caller decides what an
 * unpriced component becomes.
 */
export function parseEstimates(raw: unknown): Map<string, Nutrients & { servingSizeG: number }> {
  const arr = Array.isArray(raw)
    ? raw
    : (raw as { items?: unknown[] })?.items ?? (raw as { foods?: unknown[] })?.foods;
  const out = new Map<string, Nutrients & { servingSizeG: number }>();
  if (!Array.isArray(arr)) return out;

  for (const entry of arr) {
    const e = entry as Record<string, unknown>;
    const name = typeof e.name === 'string' ? e.name : '';
    if (!name.trim()) continue;
    const per100: Nutrients & { servingSizeG: number } = { servingSizeG: 100 };
    for (const key of NUTRIENT_KEYS) {
      const v = Number(e[key]);
      per100[key] = Number.isFinite(v) ? v : null;
    }
    out.set(estimateKey(name), per100);
  }
  return out;
}

/**
 * Last resort for everything the food base could not vouch for: one model call
 * per chunk of names rather than one per component. `deadlineAt` is the wall
 * the whole analysis has to land inside — once there is no time left for
 * another call the remaining chunks are given up on, and their components are
 * logged with no numbers instead of the run failing.
 */
async function estimateBatch(
  env: Bindings, names: string[], deadlineAt: number,
): Promise<Map<string, Nutrients & { servingSizeG: number }>> {
  const { chat, chatMaxTokens, mealEstimateTimeoutMs, mealEstimateBatchSize } = modelConfig(env);
  const merged = new Map<string, Nutrients & { servingSizeG: number }>();
  if (names.length === 0) return merged;

  const chunks: string[][] = [];
  for (let i = 0; i < names.length; i += mealEstimateBatchSize) {
    chunks.push(names.slice(i, i + mealEstimateBatchSize));
  }

  // Two at a time: enough to overlap the queueing, few enough not to be
  // rate-limited into serial anyway.
  const results = await mapPool(chunks, 2, async (chunk) => {
    const left = deadlineAt - Date.now() - WRITE_RESERVE_MS;
    if (left <= 5_000) {
      console.warn('meal analysis: out of budget, skipping estimate for', chunk.join(', '));
      return new Map<string, Nutrients & { servingSizeG: number }>();
    }
    try {
      const res = await withTimeout(
        env.AI.run(chat as never, {
          messages: [
            { role: 'system', content: renderPrompt(PROMPTS.mealEstimateSystem) },
            {
              role: 'user',
              content: renderPrompt(PROMPTS.mealEstimateUser, {
                names: chunk.map((n) => `- ${n}`).join('\n'),
              }),
            },
          ],
          max_tokens: chatMaxTokens,
          temperature: 0.2,
        } as never) as Promise<unknown>,
        Math.min(mealEstimateTimeoutMs, left),
        'meal nutrition estimate',
      );
      return parseEstimates(extractJson(aiText(res)));
    } catch (err) {
      // A failed estimate must not sink the whole meal: its components are
      // logged with no numbers.
      console.warn('meal analysis: estimate chunk failed', chunk.join(', '), err);
      return new Map<string, Nutrients & { servingSizeG: number }>();
    }
  });

  for (const map of results) for (const [k, v] of map) merged.set(k, v);
  return merged;
}

export interface AnalyzeResult {
  analysisId: string;
  itemCount: number;
}

/**
 * Full pipeline for one meal photo. Runs in the queue consumer (src/queue.ts), so it owns its own
 * error handling: every failure path must still close out the analysis row.
 */
export async function analyzeMealPhoto(
  db: Db,
  env: Bindings,
  opts: { mealLogId: string; userId: string; photoR2Key: string; analysisId: string },
): Promise<AnalyzeResult> {
  const { vision, visionMaxTokens } = modelConfig(env);

  return runAnalysis(db, env, opts, async () => {
    const object = await env.MEDIA.get(opts.photoR2Key);
    if (!object) throw new ApiError('NOT_FOUND', 'Meal photo missing from storage');
    const bytes = new Uint8Array(await object.arrayBuffer());

    // What the user typed next to the photo ("phở bò tái, ít bánh", "2 người
    // ăn chung") — the model cannot see sauces, fillings or who shared the plate.
    const noteRows = await db.select({ note: mealLogs.note }).from(mealLogs)
      .where(eq(mealLogs.id, opts.mealLogId)).limit(1);
    const note = noteRows[0]?.note?.trim();
    const prompt = note
      ? `${renderPrompt(PROMPTS.mealVision)}\n${renderPrompt(PROMPTS.mealVisionNote, { note })}`
      : renderPrompt(PROMPTS.mealVision);

    // Vision models read the photo as a data URI in a chat message. Reasoning
    // models spend most of their budget before writing an answer, so the token
    // ceiling is far higher than the array itself needs.
    return aiText(await env.AI.run(vision as never, {
      messages: [{
        role: 'user',
        content: [
          { type: 'text', text: prompt },
          { type: 'image_url', image_url: { url: toDataUri(bytes) } },
        ],
      }],
      max_tokens: visionMaxTokens,
    } as never));
  });
}

/**
 * Spoken meals ("trưa nay ăn hai bát cơm với thịt kho") go through the same
 * retrieval and correction machinery as photos — only the way the components are
 * detected differs, so the model call is the single parameter here.
 */
export async function analyzeMealFromSpeech(
  db: Db,
  env: Bindings,
  opts: { mealLogId: string; userId: string; transcript: string; analysisId: string },
): Promise<AnalyzeResult> {
  const { chat, chatMaxTokens } = modelConfig(env);

  return runAnalysis(db, env, opts, async () => aiText(await env.AI.run(chat as never, {
    messages: [
      { role: 'system', content: renderPrompt(PROMPTS.mealSpeech) },
      { role: 'user', content: opts.transcript },
    ],
    max_tokens: chatMaxTokens,
    temperature: 0.2,
  } as never)));
}

/**
 * A run that lost the race — timed out and retried, or swept by the cron —
 * must not write: its items would clobber the newer run's results, or the
 * corrections the user has made since. The newest still-active attempt for
 * the meal wins; every other live row is a zombie.
 */
async function isCurrentRun(db: Db, mealLogId: string, analysisId: string): Promise<boolean> {
  const rows = await db.select({ id: mealAiAnalyses.id }).from(mealAiAnalyses)
    .where(and(
      eq(mealAiAnalyses.mealLogId, mealLogId),
      inArray(mealAiAnalyses.status, ['pending', 'running']),
    ))
    .orderBy(desc(mealAiAnalyses.id))
    .limit(1);
  return rows[0]?.id === analysisId;
}

/**
 * Shared tail of every analysis: parse, resolve each component against the food
 * base, drop what nothing vouched for, replace the meal's items, and close out
 * the analysis row — including on failure, which is why the whole thing is
 * wrapped rather than left to each caller.
 */
async function runAnalysis(
  db: Db,
  env: Bindings,
  opts: { mealLogId: string; userId: string; analysisId: string },
  detect: () => Promise<string>,
): Promise<AnalyzeResult> {
  const {
    minItemConfidence, promptVersion, mealDetectTimeoutMs, mealMaxComponents,
    mealResolveConcurrency,
  } = modelConfig(env);
  const started = Date.now();
  let rawText = '';

  // The clock every reader judges this run by starts when the row was written,
  // not when the consumer picked the job up, so the budget is measured from
  // there. Everything inside aims to land before [MEAL_ANALYSIS_BUDGET_MS] —
  // a partial answer that arrives is worth more than a perfect one the timeout
  // throws away.
  const createdRows = await db.select({ createdAt: mealAiAnalyses.createdAt })
    .from(mealAiAnalyses).where(eq(mealAiAnalyses.id, opts.analysisId)).limit(1);
  const deadlineAt = (createdRows[0]?.createdAt ?? started) + MEAL_ANALYSIS_BUDGET_MS;
  const budgetLeft = () => deadlineAt - Date.now();

  try {
    // Workers AI fails transiently now and then ("8004: Internal server
    // error"); one more attempt is cheaper than the user retrying by hand — but
    // only while there is time for the rest of the pipeline afterwards.
    const detectOnce = () => withTimeout(
      detect(),
      Math.max(5_000, Math.min(mealDetectTimeoutMs, budgetLeft() - RESOLVE_RESERVE_MS)),
      'meal detection',
    );
    try {
      rawText = await detectOnce();
    } catch (err) {
      if (budgetLeft() < mealDetectTimeoutMs / 2 + RESOLVE_RESERVE_MS) throw err;
      console.warn('meal analysis model call failed, retrying once', opts.analysisId, err);
      await new Promise((r) => setTimeout(r, 1500));
      rawText = await detectOnce();
    }
    const parsed = extractJson(rawText);
    const dishName = parseDishName(parsed);
    const detected = capComponents(parseComponents(parsed), mealMaxComponents);

    // Phase 1, bounded fan-out: the food base is asked about each component.
    // A lookup that throws (D1 or Vectorize having a bad minute) is not fatal —
    // the component just falls through to phase 2 like an unmatched one.
    const looked = await mapPool(detected, mealResolveConcurrency, async (comp) => {
      try {
        return await lookupComponent(db, env, opts.userId, comp);
      } catch (err) {
        console.warn('meal analysis: lookup failed for', comp.name, err);
        return { resolution: null, candidates: [] as Candidate[] };
      }
    });

    // Phase 2: everything the food base could not vouch for, estimated together.
    const unmatched = detected.filter((_, i) => looked[i]!.resolution === null);
    const estimates = await estimateBatch(
      env, [...new Set(unmatched.map((c) => c.name))], deadlineAt,
    );

    const allResolutions = detected.map((comp, i) => {
      const found = looked[i]!;
      if (found.resolution) return found as { resolution: Resolution; candidates: Candidate[] };
      const per100 = estimates.get(estimateKey(comp.name));
      return {
        resolution: {
          source: 'ai_estimated' as const,
          confidence: Math.min(comp.confidence ?? 0.4, 0.5),
          // No estimate came back (the model skipped it, or the budget ran
          // out): the component is still listed, with nothing claimed about it.
          nutrients: per100 ? scale(per100, comp.grams) : { caloriesKcal: 0 },
        },
        candidates: found.candidates,
      };
    });

    // A component the food base could not vouch for at all is noise, not food:
    // it would put an invented number into the day's calorie total. The floor is
    // an env var because it trades missing calories against invented ones.
    const kept = detected
      .map((comp, i) => ({ comp, ...allResolutions[i]! }))
      .filter((r) => r.resolution.confidence >= minItemConfidence);

    const components = kept.map((k) => k.comp);
    const resolutions = kept;

    const now = Date.now();
    const rows = kept.map(({ comp, resolution }) => {
      const n = resolution.nutrients;
      return {
        mealLogId: opts.mealLogId,
        foodId: resolution.foodId ?? null,
        userFoodId: resolution.userFoodId ?? null,
        ingredientName: comp.name,
        quantityG: comp.grams,
        quantityLabel: comp.label ?? null,
        caloriesKcal: n.caloriesKcal ?? 0,
        proteinG: n.proteinG ?? null,
        carbsG: n.carbsG ?? null,
        fatG: n.fatG ?? null,
        saturatedFatG: n.saturatedFatG ?? null,
        fiberG: n.fiberG ?? null,
        sugarG: n.sugarG ?? null,
        sodiumMg: n.sodiumMg ?? null,
        cholesterolMg: n.cholesterolMg ?? null,
        waterMl: comp.waterMl ?? null,
        source: resolution.source,
        confidence: resolution.confidence,
        // The immutable original guess for this item — never overwritten later.
        aiPredictedJson: JSON.stringify({
          ingredientName: comp.name,
          quantityG: comp.grams,
          ...n,
          waterMl: comp.waterMl ?? null,
          source: resolution.source,
          confidence: resolution.confidence,
        }),
        isUserCorrected: false,
        createdAt: now,
      };
    });

    // Re-analysis replaces the items but never the previous analysis record.
    // A run that timed out and was retried (or was swept) has been superseded:
    // writing now would clobber the newer attempt's items or the user's
    // corrections, so the late answer is dropped instead.
    if (!(await isCurrentRun(db, opts.mealLogId, opts.analysisId))) {
      console.warn('meal analysis result discarded (superseded or timed out)', opts.analysisId);
      return { analysisId: opts.analysisId, itemCount: 0 };
    }
    await db.delete(mealItems).where(eq(mealItems.mealLogId, opts.mealLogId));
    await insertMany((chunk) => db.insert(mealItems).values(chunk), rows);

    await recomputeMealTotals(db, env, opts.mealLogId);

    if (dishName) {
      await db.update(mealLogs)
        .set({ dishName, updatedAt: Date.now() })
        .where(eq(mealLogs.id, opts.mealLogId));
    }

    const overall = resolutions.length
      ? resolutions.reduce((s, r) => s + r.resolution.confidence, 0) / resolutions.length
      : 0;

    // Conditional on `running`: a row the cron sweeper already closed must not
    // be resurrected by a late answer — if it closed the row between the guard
    // above and this write, the update simply matches nothing.
    const closed = await db.update(mealAiAnalyses).set({
      status: 'completed',
      rawResponseJson: rawText,
      retrievalJson: JSON.stringify(
        resolutions.map((r, i) => ({
          component: components[i]?.name,
          fused: r.candidates.map((c) => ({
            kind: c.kind, id: c.id, score: c.score,
            bm25Rank: c.bm25Rank, vectorRank: c.vectorRank,
          })),
        })),
      ),
      overallConfidence: Math.round(overall * 100) / 100,
      latencyMs: Date.now() - started,
      completedAt: Date.now(),
    }).where(and(
      eq(mealAiAnalyses.id, opts.analysisId),
      eq(mealAiAnalyses.status, 'running'),
    )).returning({ id: mealAiAnalyses.id });
    if (closed.length === 0) {
      console.warn('meal analysis result discarded (row already closed)', opts.analysisId);
    }

    return { analysisId: opts.analysisId, itemCount: rows.length };
  } catch (err) {
    // Same condition: a swept or superseded run stays failed no matter how it
    // eventually ended.
    await db.update(mealAiAnalyses).set({
      status: 'failed',
      errorMessage: err instanceof Error ? err.message : String(err),
      rawResponseJson: rawText,
      latencyMs: Date.now() - started,
      completedAt: Date.now(),
    }).where(and(
      eq(mealAiAnalyses.id, opts.analysisId),
      eq(mealAiAnalyses.status, 'running'),
    ));
    throw err;
  } finally {
    void promptVersion;
  }
}

/** Re-sums meal_items into meal_logs.total_*, then refreshes the daily rollup. */
export async function recomputeMealTotals(
  db: Db, env: Bindings, mealLogId: string,
): Promise<void> {
  const items = await db.select().from(mealItems).where(eq(mealItems.mealLogId, mealLogId));
  const sum = (pick: (i: typeof items[number]) => number | null) =>
    Math.round(items.reduce((s, i) => s + (pick(i) ?? 0), 0) * 100) / 100;

  const logRows = await db.select().from(mealLogs).where(eq(mealLogs.id, mealLogId)).limit(1);
  const log = logRows[0];
  if (!log) return;

  await db.update(mealLogs).set({
    totalCaloriesKcal: sum((i) => i.caloriesKcal),
    totalProteinG: sum((i) => i.proteinG),
    totalCarbsG: sum((i) => i.carbsG),
    totalFatG: sum((i) => i.fatG),
    totalFiberG: sum((i) => i.fiberG),
    totalSugarG: sum((i) => i.sugarG),
    totalSodiumMg: sum((i) => i.sodiumMg),
    // Null, not 0, when no item carries an estimate: an un-analysed meal has
    // nothing to say about fluid, and a 0 would read as "you drank nothing".
    totalWaterMl: items.some((i) => i.waterMl !== null)
      ? sum((i) => i.waterMl)
      : null,
    updatedAt: Date.now(),
  }).where(eq(mealLogs.id, mealLogId));

  await recomputeDailyNutritionSummary(db, env, log.userId, log.localDate);
}
