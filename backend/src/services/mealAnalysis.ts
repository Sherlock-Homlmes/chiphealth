import { and, desc, eq, inArray } from 'drizzle-orm';
import {
  foods, userFoods, mealLogs, mealItems, mealAiAnalyses,
} from '../db/schema';
import { modelConfig } from '../config/models';
import { hybridFoodSearch, type Candidate } from './foodSearch';
import { recomputeDailyNutritionSummary } from './nutritionMath';
import { ApiError } from '../lib/errors';
import { insertMany } from '../db/client';
import { aiText, toDataUri } from '../lib/aiText';
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
export const MEAL_ANALYSIS_TIMEOUT_MS = 3 * 60_000;

export const ANALYSIS_TIMEOUT_MESSAGE = 'Phân tích kéo dài quá 3 phút';

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
 * Models wrap JSON in prose or fences no matter how firm the instruction is, so
 * pull out the first balanced JSON value instead of trusting the whole response.
 */
export function extractJson(text: string): unknown {
  const start = text.search(/[[{]/);
  if (start === -1) throw new ApiError('UPSTREAM_AI_ERROR', 'Model returned no JSON');

  const open = text[start] as '[' | '{';
  const close = open === '[' ? ']' : '}';
  let depth = 0;
  let inString = false;
  let escaped = false;

  for (let i = start; i < text.length; i++) {
    const ch = text[i]!;
    if (inString) {
      if (escaped) escaped = false;
      else if (ch === '\\') escaped = true;
      else if (ch === '"') inString = false;
      continue;
    }
    if (ch === '"') inString = true;
    else if (ch === open) depth++;
    else if (ch === close) {
      depth--;
      if (depth === 0) {
        try {
          return JSON.parse(text.slice(start, i + 1));
        } catch {
          throw new ApiError('UPSTREAM_AI_ERROR', 'Model JSON is malformed');
        }
      }
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
 */
async function resolveComponent(
  db: Db, env: Bindings, userId: string, comp: DetectedComponent,
): Promise<{ resolution: Resolution; candidates: Candidate[] }> {
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

  const estimated = await estimateNutrition(env, comp);
  return {
    resolution: {
      source: 'ai_estimated',
      confidence: Math.min(comp.confidence ?? 0.4, 0.5),
      nutrients: estimated,
    },
    candidates: search.fused,
  };
}

/** Last resort: ask the chat model for per-100g values and scale them. */
async function estimateNutrition(env: Bindings, comp: DetectedComponent): Promise<Nutrients> {
  const { chat, chatMaxTokens } = modelConfig(env);
  const res = await env.AI.run(chat as never, {
    messages: [
      { role: 'system', content: renderPrompt(PROMPTS.mealEstimateSystem) },
      { role: 'user', content: renderPrompt(PROMPTS.mealEstimateUser, { name: comp.name }) },
    ],
    max_tokens: chatMaxTokens,
    temperature: 0.2,
  } as never);

  try {
    const parsed = extractJson(aiText(res)) as Record<string, unknown>;
    const per100: Nutrients & { servingSizeG: number } = { servingSizeG: 100 };
    for (const key of NUTRIENT_KEYS) {
      const v = Number(parsed[key]);
      per100[key] = Number.isFinite(v) ? v : null;
    }
    return scale(per100, comp.grams);
  } catch {
    // A failed estimate must not sink the whole meal: log the item with no numbers.
    return { caloriesKcal: 0 };
  }
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
  const { minItemConfidence, promptVersion } = modelConfig(env);
  const started = Date.now();
  let rawText = '';

  try {
    // Workers AI fails transiently now and then ("8004: Internal server
    // error"); one more attempt is cheaper than the user retrying by hand.
    try {
      rawText = await detect();
    } catch (err) {
      console.warn('meal analysis model call failed, retrying once', opts.analysisId, err);
      await new Promise((r) => setTimeout(r, 1500));
      rawText = await detect();
    }
    const parsed = extractJson(rawText);
    const dishName = parseDishName(parsed);
    const detected = parseComponents(parsed);

    const allResolutions = await Promise.all(
      detected.map((c) => resolveComponent(db, env, opts.userId, c)),
    );

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
