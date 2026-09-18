import { Hono } from 'hono';
import { and, desc, eq, gte, lte, inArray, sql } from 'drizzle-orm';
import { z } from 'zod';
import {
  foods, userFoods, userFoodIngredients, mealLogs, mealItems, mealAiAnalyses,
  mealPlans, dailyNutritionSummaries, barcodeScanMisses, mediaAssets,
} from '../db/schema';
import { parseBody, parseQuery, isoDateSchema, paginationSchema, page } from '../lib/http';
import { ApiError, notFound } from '../lib/errors';
import { newId } from '../lib/ids';
import { localDate } from '../lib/time';
import { hybridFoodSearch } from '../services/foodSearch';
import { effectiveAnalysis, recomputeMealTotals } from '../services/mealAnalysis';
import type { MealAnalysisJob } from '../queue';
import {
  loadTdeeInputs, computeBmrTdee, recomputeDailyNutritionSummary,
} from '../services/nutritionMath';
import { modelConfig } from '../config/models';
import type { Bindings } from '../env';
import { insertMany } from '../db/client';
import { buildCoachContext, completeCoachReply } from '../services/coach';
import type { AppEnv } from '../env';

const app = new Hono<AppEnv>();

const MEAL_TYPES = ['breakfast', 'lunch', 'dinner', 'snack'] as const;

const nutrientFields = {
  caloriesKcal: z.number().nonnegative(),
  proteinG: z.number().nonnegative().nullish(),
  carbsG: z.number().nonnegative().nullish(),
  fatG: z.number().nonnegative().nullish(),
  saturatedFatG: z.number().nonnegative().nullish(),
  fiberG: z.number().nonnegative().nullish(),
  sugarG: z.number().nonnegative().nullish(),
  sodiumMg: z.number().nonnegative().nullish(),
  cholesterolMg: z.number().nonnegative().nullish(),
};

// ---------------------------------------------------------------- meals

const createMealSchema = z.object({
  id: z.string().uuid().optional(),
  mealType: z.enum(MEAL_TYPES),
  photoAssetId: z.string().uuid().nullish(),
  loggedAt: z.number().int().positive(),
  note: z.string().max(500).nullish(),
});

/** Offline-first: the client may mint the id, so POST is an upsert scoped to the caller. */
app.post('/meals', async (c) => {
  const body = await parseBody(c, createMealSchema);
  const user = c.get('user');
  const db = c.get('db');
  const id = body.id ?? newId();
  const now = Date.now();
  const day = localDate(body.loggedAt, user.timezone);

  // Kept from before the write: if this upsert moves the meal to another day,
  // the day it left has to be re-summed as well.
  const previousRows = await db.select({ localDate: mealLogs.localDate }).from(mealLogs)
    .where(and(eq(mealLogs.id, id), eq(mealLogs.userId, user.id))).limit(1);
  const previous = previousRows[0];

  if (body.photoAssetId) {
    const asset = await db.select().from(mediaAssets)
      .where(and(eq(mediaAssets.id, body.photoAssetId), eq(mediaAssets.userId, user.id)))
      .limit(1);
    if (!asset[0]) throw notFound('Photo asset');
    await db.update(mediaAssets).set({ isOrphan: false })
      .where(eq(mediaAssets.id, body.photoAssetId));
  }

  await db.insert(mealLogs).values({
    id,
    userId: user.id,
    mealType: body.mealType,
    photoAssetId: body.photoAssetId ?? null,
    loggedAt: body.loggedAt,
    localDate: day,
    note: body.note ?? null,
    createdAt: now,
    updatedAt: now,
  }).onConflictDoUpdate({
    target: mealLogs.id,
    set: {
      mealType: body.mealType,
      photoAssetId: body.photoAssetId ?? null,
      loggedAt: body.loggedAt,
      localDate: day,
      note: body.note ?? null,
      updatedAt: now,
    },
    where: eq(mealLogs.userId, user.id),
  });

  const rows = await db.select().from(mealLogs).where(eq(mealLogs.id, id)).limit(1);

  // An upsert can move a meal to another day; both days then have a stale sum.
  const days = new Set([day, ...(previous ? [previous.localDate] : [])]);
  for (const d of days) await recomputeDailyNutritionSummary(db, c.env, user.id, d);

  return c.json(rows[0], 201);
});

/**
 * The list views show a meal without its components: how many there are, and
 * whether the analysis is still running or failed. Both are one extra query for
 * the whole page rather than one per meal.
 */
async function summariseMeals(
  db: AppEnv['Variables']['db'], meals: Array<typeof mealLogs.$inferSelect>,
) {
  if (meals.length === 0) return [];
  const ids = meals.map((m) => m.id);

  const [counts, analyses] = await Promise.all([
    db.select({ mealLogId: mealItems.mealLogId, n: sql<number>`count(*)` })
      .from(mealItems).where(inArray(mealItems.mealLogId, ids))
      .groupBy(mealItems.mealLogId),
    db.select({
      mealLogId: mealAiAnalyses.mealLogId,
      status: mealAiAnalyses.status,
      id: mealAiAnalyses.id,
      createdAt: mealAiAnalyses.createdAt,
    }).from(mealAiAnalyses).where(inArray(mealAiAnalyses.mealLogId, ids))
      .orderBy(desc(mealAiAnalyses.id)),
  ]);

  const countByMeal = new Map(counts.map((r) => [r.mealLogId, r.n]));
  // Ordered newest first, so the first row seen for a meal is its latest run.
  // The effective status folds the 3-minute timeout in, so a meal whose model
  // hung reads as failed here too, not just on the detail endpoint.
  const statusByMeal = new Map<string, { status: string; timedOut: boolean }>();
  for (const a of analyses) {
    if (statusByMeal.has(a.mealLogId)) continue;
    const eff = effectiveAnalysis({ status: a.status, createdAt: a.createdAt, errorMessage: null });
    statusByMeal.set(a.mealLogId, { status: eff.status, timedOut: eff.timedOut });
  }

  return meals.map((m) => ({
    ...m,
    itemCount: countByMeal.get(m.id) ?? 0,
    analysis: statusByMeal.has(m.id) ? statusByMeal.get(m.id) : null,
  }));
}

/**
 * The meal timeline: every meal, newest first, grouped by day in the client.
 *
 * Ordered by `loggedAt` rather than by id because a meal can be logged for a
 * time other than the moment it was created (a breakfast typed up at noon), and
 * the timeline is a diary, not a creation log. That makes the cursor a pair —
 * `loggedAt:id` — with the id breaking ties so no meal is skipped or repeated
 * when two land on the same millisecond.
 */
app.get('/meals', async (c) => {
  const q = parseQuery(c, paginationSchema.extend({
    from: isoDateSchema.optional(),
    to: isoDateSchema.optional(),
  }));
  const user = c.get('user');

  const filters = [eq(mealLogs.userId, user.id)];
  if (q.from) filters.push(gte(mealLogs.localDate, q.from));
  if (q.to) filters.push(lte(mealLogs.localDate, q.to));
  if (q.cursor) {
    const sep = q.cursor.indexOf(':');
    if (sep === -1) throw new ApiError('VALIDATION_ERROR', 'Malformed cursor');
    const at = Number(q.cursor.slice(0, sep));
    const id = q.cursor.slice(sep + 1);
    if (!Number.isFinite(at)) throw new ApiError('VALIDATION_ERROR', 'Malformed cursor');
    filters.push(sql`(${mealLogs.loggedAt} < ${at} OR (${mealLogs.loggedAt} = ${at} AND ${mealLogs.id} < ${id}))`);
  }

  const rows = await c.get('db').select().from(mealLogs)
    .where(and(...filters))
    .orderBy(desc(mealLogs.loggedAt), desc(mealLogs.id))
    .limit(q.limit + 1);

  const hasMore = rows.length > q.limit;
  const slice = hasMore ? rows.slice(0, q.limit) : rows;
  const last = slice[slice.length - 1];

  return c.json({
    items: await summariseMeals(c.get('db'), slice),
    nextCursor: hasMore && last ? `${last.loggedAt}:${last.id}` : null,
  });
});

async function ownedMeal(db: AppEnv['Variables']['db'], userId: string, id: string) {
  const rows = await db.select().from(mealLogs)
    .where(and(eq(mealLogs.id, id), eq(mealLogs.userId, userId))).limit(1);
  const meal = rows[0];
  if (!meal) throw notFound('Meal');
  return meal;
}

app.get('/meals/:id', async (c) => {
  const db = c.get('db');
  const meal = await ownedMeal(db, c.get('user').id, c.req.param('id'));

  const [items, analyses] = await Promise.all([
    db.select().from(mealItems).where(eq(mealItems.mealLogId, meal.id)),
    db.select().from(mealAiAnalyses).where(eq(mealAiAnalyses.mealLogId, meal.id))
      .orderBy(desc(mealAiAnalyses.id)).limit(1),
  ]);

  // The poll endpoint applies the timeout clock, so a run whose model hung is
  // reported as failed (timedOut) here the moment it passes 3 minutes — that
  // is what flips the client from "Đang phân tích…" to the retry screen.
  return c.json({
    ...meal,
    items,
    analysis: analyses[0] ? effectiveAnalysis(analyses[0]) : null,
  });
});

/**
 * The meal's own fields, as opposed to its components: what the dish is called,
 * which meal it counts as, when it was eaten. The vision model's name is a
 * guess like any other, so the correction surface has to reach it.
 *
 * Moving the meal in time moves it between days, so both the day it left and
 * the day it landed on are re-summed.
 */
app.patch('/meals/:id', async (c) => {
  const body = await parseBody(c, z.object({
    mealType: z.enum(MEAL_TYPES).optional(),
    dishName: z.string().max(200).nullish(),
    note: z.string().max(500).nullish(),
    loggedAt: z.number().int().positive().optional(),
  }));
  const db = c.get('db');
  const user = c.get('user');
  const meal = await ownedMeal(db, user.id, c.req.param('id'));

  const loggedAt = body.loggedAt ?? meal.loggedAt;
  const day = localDate(loggedAt, user.timezone);
  const dishName = body.dishName === undefined
    ? meal.dishName
    : (body.dishName?.trim() || null);

  await db.update(mealLogs).set({
    mealType: body.mealType ?? meal.mealType,
    dishName,
    note: body.note === undefined ? meal.note : (body.note?.trim() || null),
    loggedAt,
    localDate: day,
    updatedAt: Date.now(),
  }).where(eq(mealLogs.id, meal.id));

  for (const d of new Set([day, meal.localDate])) {
    await recomputeDailyNutritionSummary(db, c.env, user.id, d);
  }

  const rows = await db.select().from(mealLogs).where(eq(mealLogs.id, meal.id)).limit(1);
  return c.json(rows[0]);
});

/**
 * The thumb under the analysis. Kept on the analysis row rather than the meal:
 * it judges one attempt, and a re-analysis deserves its own verdict. `null`
 * clears it, which is what tapping the lit thumb again means.
 */
app.post('/meals/:id/feedback', async (c) => {
  const body = await parseBody(c, z.object({
    vote: z.enum(['up', 'down']).nullish(),
  }));
  const db = c.get('db');
  const meal = await ownedMeal(db, c.get('user').id, c.req.param('id'));

  const latest = await db.select({ id: mealAiAnalyses.id }).from(mealAiAnalyses)
    .where(eq(mealAiAnalyses.mealLogId, meal.id))
    .orderBy(desc(mealAiAnalyses.id)).limit(1);
  if (!latest[0]) throw notFound('Meal analysis');

  const vote = body.vote ?? null;
  await db.update(mealAiAnalyses)
    .set({ userFeedback: vote, feedbackAt: vote === null ? null : Date.now() })
    .where(eq(mealAiAnalyses.id, latest[0].id));

  return c.json({ userFeedback: vote });
});

app.delete('/meals/:id', async (c) => {
  const db = c.get('db');
  const meal = await ownedMeal(db, c.get('user').id, c.req.param('id'));
  await db.delete(mealLogs).where(eq(mealLogs.id, meal.id));
  // The day rollup is a stored sum, not a view: dropping the meal has to take
  // its calories out of the day too, or the deleted meal keeps being counted.
  await recomputeDailyNutritionSummary(db, c.env, meal.userId, meal.localDate);
  return c.body(null, 204);
});

/**
 * Analysis is slow (vision model + retrieval, 30-60 s), so the row is created
 * synchronously and the work runs on the meal-analysis queue — not waitUntil,
 * which is cut off 30 s after the response. The client polls GET /meals/:id.
 */
app.post('/meals/:id/analyze', async (c) => {
  const db = c.get('db');
  const meal = await ownedMeal(db, c.get('user').id, c.req.param('id'));
  if (!meal.photoAssetId) throw new ApiError('VALIDATION_ERROR', 'Meal has no photo');

  const assetRows = await db.select().from(mediaAssets)
    .where(eq(mediaAssets.id, meal.photoAssetId)).limit(1);
  const asset = assetRows[0];
  if (!asset) throw notFound('Photo asset');

  const { vision, promptVersion } = modelConfig(c.env);
  const analysisId = newId();
  await db.insert(mealAiAnalyses).values({
    id: analysisId,
    mealLogId: meal.id,
    status: 'running',
    model: vision,
    promptVersion,
    createdAt: Date.now(),
  });

  await enqueueAnalysis(db, c.env, {
    kind: 'photo',
    mealLogId: meal.id,
    userId: meal.userId,
    photoR2Key: asset.r2Key,
    analysisId,
  });

  return c.json({ analysisId, status: 'running' }, 202);
});

/**
 * Spoken meal logging. The clip is sent as the raw request body (`Content-Type:
 * audio/*`) and never stored: a voice memo used to log lunch has no value once
 * it has been transcribed, and keeping it would mean a new media kind, a new
 * folder and another orphan to sweep. Send `{"transcript": "..."}` as JSON
 * instead to skip ASR — that is what the typed "nhập tay" flow uses.
 *
 * Extraction is slow, so it goes through the same queue and polling contract as
 * the photo path: the client polls GET /meals/:id. ASR runs here in the request
 * instead — it takes seconds, and the clip is too big for a queue message.
 */
app.post('/meals/:id/voice', async (c) => {
  const db = c.get('db');
  const meal = await ownedMeal(db, c.get('user').id, c.req.param('id'));
  const contentType = c.req.header('content-type') ?? '';

  let transcript: string | null = null;
  let audio: number[] | null = null;

  if (contentType.startsWith('audio/')) {
    const buf = await c.req.arrayBuffer();
    const maxBytes = Number(c.env.MAX_MEAL_AUDIO_BYTES) || 4 * 1024 * 1024;
    if (buf.byteLength === 0) throw new ApiError('VALIDATION_ERROR', 'Empty audio body');
    if (buf.byteLength > maxBytes) {
      throw new ApiError('UPLOAD_TOO_LARGE', `Max ${maxBytes} bytes for a voice clip`);
    }
    audio = [...new Uint8Array(buf)];
  } else {
    const body = await parseBody(c, z.object({
      transcript: z.string().trim().min(1).max(2000),
    }));
    transcript = body.transcript;
  }

  const { chat, asr, promptVersion } = modelConfig(c.env);
  const analysisId = newId();
  await db.insert(mealAiAnalyses).values({
    id: analysisId,
    mealLogId: meal.id,
    status: 'running',
    model: transcript ? chat : `${asr} + ${chat}`,
    promptVersion,
    createdAt: Date.now(),
  });

  let text: string;
  try {
    text = transcript ?? await transcribe(c.env, audio!);
  } catch (err) {
    // The pipeline closes its own row; a failure in ASR happens before it is
    // ever reached, so that case is closed out here.
    await failAnalysis(db, analysisId, err);
    throw err;
  }

  await enqueueAnalysis(db, c.env, {
    kind: 'speech',
    mealLogId: meal.id,
    userId: meal.userId,
    transcript: text,
    analysisId,
  });

  return c.json({ analysisId, status: 'running' }, 202);
});

async function failAnalysis(
  db: AppEnv['Variables']['db'], analysisId: string, err: unknown,
): Promise<void> {
  await db.update(mealAiAnalyses)
    .set({
      status: 'failed',
      errorMessage: err instanceof Error ? err.message : String(err),
      completedAt: Date.now(),
    })
    .where(and(eq(mealAiAnalyses.id, analysisId), eq(mealAiAnalyses.status, 'running')));
}

/** A job that never reached the queue must not leave its row `running`. */
async function enqueueAnalysis(
  db: AppEnv['Variables']['db'], env: Bindings, job: MealAnalysisJob,
): Promise<void> {
  try {
    await env.MEAL_ANALYSIS.send(job);
  } catch (err) {
    await failAnalysis(db, job.analysisId, err);
    throw err;
  }
}

/**
 * Dictation for the typed "nhập tay" box: the clip comes back as text and
 * nothing else happens. The user reads, fixes and appends to it before sending
 * the whole transcript through /meals/:id/voice, so no meal is created here.
 */
app.post('/meals/transcribe', async (c) => {
  const contentType = c.req.header('content-type') ?? '';
  if (!contentType.startsWith('audio/')) {
    throw new ApiError('VALIDATION_ERROR', 'Expected an audio/* body');
  }
  const buf = await c.req.arrayBuffer();
  const maxBytes = Number(c.env.MAX_MEAL_AUDIO_BYTES) || 4 * 1024 * 1024;
  if (buf.byteLength === 0) throw new ApiError('VALIDATION_ERROR', 'Empty audio body');
  if (buf.byteLength > maxBytes) {
    throw new ApiError('UPLOAD_TOO_LARGE', `Max ${maxBytes} bytes for a voice clip`);
  }
  const transcript = await transcribe(c.env, [...new Uint8Array(buf)]);
  return c.json({ transcript });
});

/** Whisper on the raw clip. Same model the sleep-talk transcripts use. */
async function transcribe(env: Bindings, audio: number[]): Promise<string> {
  // whisper-large-v3-turbo takes the clip as base64, not a byte array.
  let binary = '';
  for (let i = 0; i < audio.length; i += 0x8000) {
    binary += String.fromCharCode(...audio.slice(i, i + 0x8000));
  }
  const result = (await env.AI.run(
    modelConfig(env).asr as never,
    { audio: btoa(binary), language: 'vi' } as never,
  )) as unknown as { text?: string };
  const text = (result.text ?? '').trim();
  if (!text) throw new ApiError('UPSTREAM_AI_ERROR', 'Không nghe rõ nội dung');
  return text;
}

// ------------------------------------------------------- item corrections

const itemSchema = z.object({
  ingredientName: z.string().min(1).max(200),
  quantityG: z.number().positive(),
  quantityLabel: z.string().max(100).nullish(),
  foodId: z.string().uuid().nullish(),
  userFoodId: z.string().uuid().nullish(),
  ...nutrientFields,
});

/** Copies the pre-correction values into ai_predicted_json exactly once. */
function preserveAiPrediction(item: typeof mealItems.$inferSelect): string {
  if (item.aiPredictedJson) return item.aiPredictedJson;
  return JSON.stringify({
    ingredientName: item.ingredientName,
    quantityG: item.quantityG,
    caloriesKcal: item.caloriesKcal,
    proteinG: item.proteinG,
    carbsG: item.carbsG,
    fatG: item.fatG,
    saturatedFatG: item.saturatedFatG,
    fiberG: item.fiberG,
    sugarG: item.sugarG,
    sodiumMg: item.sodiumMg,
    cholesterolMg: item.cholesterolMg,
    source: item.source,
    confidence: item.confidence,
  });
}

/** Learns the correction into the caller's own food base for next time. */
async function learnUserFood(
  db: AppEnv['Variables']['db'], userId: string, body: z.infer<typeof itemSchema>,
): Promise<void> {
  const per100 = (v: number | null | undefined) =>
    typeof v === 'number' ? Math.round((v / body.quantityG) * 100 * 100) / 100 : null;

  const existing = await db.select().from(userFoods)
    .where(and(eq(userFoods.userId, userId), eq(userFoods.name, body.ingredientName)))
    .limit(1);

  const values = {
    servingSizeG: 100,
    caloriesKcal: per100(body.caloriesKcal) ?? 0,
    proteinG: per100(body.proteinG),
    carbsG: per100(body.carbsG),
    fatG: per100(body.fatG),
    saturatedFatG: per100(body.saturatedFatG),
    fiberG: per100(body.fiberG),
    sugarG: per100(body.sugarG),
    sodiumMg: per100(body.sodiumMg),
    cholesterolMg: per100(body.cholesterolMg),
    updatedAt: Date.now(),
  };

  const found = existing[0];
  if (found) {
    await db.update(userFoods)
      .set({ ...values, usageCount: found.usageCount + 1, lastUsedAt: Date.now() })
      .where(eq(userFoods.id, found.id));
    return;
  }

  await db.insert(userFoods).values({
    id: newId(),
    userId,
    basedOnFoodId: body.foodId ?? null,
    name: body.ingredientName,
    usageCount: 1,
    lastUsedAt: Date.now(),
    createdAt: Date.now(),
    ...values,
  });
}

app.post('/meals/:id/items', async (c) => {
  const db = c.get('db');
  const user = c.get('user');
  const meal = await ownedMeal(db, user.id, c.req.param('id'));
  const body = await parseBody(c, itemSchema);
  const learn = c.req.query('learn') !== 'false';

  const inserted = await db.insert(mealItems).values({
    mealLogId: meal.id,
    foodId: body.foodId ?? null,
    userFoodId: body.userFoodId ?? null,
    ingredientName: body.ingredientName,
    quantityG: body.quantityG,
    quantityLabel: body.quantityLabel ?? null,
    caloriesKcal: body.caloriesKcal,
    proteinG: body.proteinG ?? null,
    carbsG: body.carbsG ?? null,
    fatG: body.fatG ?? null,
    saturatedFatG: body.saturatedFatG ?? null,
    fiberG: body.fiberG ?? null,
    sugarG: body.sugarG ?? null,
    sodiumMg: body.sodiumMg ?? null,
    cholesterolMg: body.cholesterolMg ?? null,
    // Added by hand, so there is no AI prediction to preserve for this row.
    source: 'ai_estimated',
    isUserCorrected: true,
    correctedAt: Date.now(),
    createdAt: Date.now(),
  }).returning();

  if (learn) await learnUserFood(db, user.id, body);
  await recomputeMealTotals(db, c.env, meal.id);
  return c.json(inserted[0], 201);
});

app.patch('/meals/:id/items/:itemId', async (c) => {
  const db = c.get('db');
  const user = c.get('user');
  const meal = await ownedMeal(db, user.id, c.req.param('id'));
  const body = await parseBody(c, itemSchema);
  const learn = c.req.query('learn') !== 'false';

  const itemId = Number(c.req.param('itemId'));
  const rows = await db.select().from(mealItems)
    .where(and(eq(mealItems.id, itemId), eq(mealItems.mealLogId, meal.id))).limit(1);
  const item = rows[0];
  if (!item) throw notFound('Meal item');

  await db.update(mealItems).set({
    ingredientName: body.ingredientName,
    quantityG: body.quantityG,
    quantityLabel: body.quantityLabel ?? null,
    foodId: body.foodId ?? item.foodId,
    userFoodId: body.userFoodId ?? item.userFoodId,
    caloriesKcal: body.caloriesKcal,
    proteinG: body.proteinG ?? null,
    carbsG: body.carbsG ?? null,
    fatG: body.fatG ?? null,
    saturatedFatG: body.saturatedFatG ?? null,
    fiberG: body.fiberG ?? null,
    sugarG: body.sugarG ?? null,
    sodiumMg: body.sodiumMg ?? null,
    cholesterolMg: body.cholesterolMg ?? null,
    // Written once, then frozen: this is the ground-truth pair for fine-tuning.
    aiPredictedJson: preserveAiPrediction(item),
    isUserCorrected: true,
    correctedAt: Date.now(),
  }).where(eq(mealItems.id, itemId));

  if (learn) await learnUserFood(db, user.id, body);
  await recomputeMealTotals(db, c.env, meal.id);

  const updated = await db.select().from(mealItems).where(eq(mealItems.id, itemId)).limit(1);
  return c.json(updated[0]);
});

app.delete('/meals/:id/items/:itemId', async (c) => {
  const db = c.get('db');
  const meal = await ownedMeal(db, c.get('user').id, c.req.param('id'));
  const itemId = Number(c.req.param('itemId'));

  await db.delete(mealItems)
    .where(and(eq(mealItems.id, itemId), eq(mealItems.mealLogId, meal.id)));
  await recomputeMealTotals(db, c.env, meal.id);
  return c.body(null, 204);
});

// ---------------------------------------------------------------- foods

app.get('/foods/search', async (c) => {
  const q = parseQuery(c, z.object({ q: z.string().min(1).max(200) }));
  const db = c.get('db');
  const user = c.get('user');

  const [search, personal] = await Promise.all([
    hybridFoodSearch(c.env, q.q),
    db.select().from(userFoods).where(and(
      eq(userFoods.userId, user.id),
      sql`lower(${userFoods.name}) like ${'%' + q.q.toLowerCase() + '%'}`,
    )).orderBy(desc(userFoods.usageCount)).limit(10),
  ]);

  const foodIds = search.fused.filter((x) => x.kind === 'food').map((x) => x.id);
  const globalRows = foodIds.length
    ? await db.select().from(foods).where(inArray(foods.id, foodIds))
    : [];
  const byId = new Map(globalRows.map((r) => [r.id, r]));

  // Personal rows first: the same dish genuinely differs between households.
  return c.json({
    personal: personal.map((f) => ({ ...f, kind: 'user_food' as const })),
    global: foodIds.flatMap((id) => {
      const row = byId.get(id);
      return row ? [{ ...row, kind: 'food' as const }] : [];
    }),
    kbHits: search.fused.filter((x) => x.kind === 'kb'),
  });
});

/**
 * Barcode data is admin-entered only. A miss returns 404 and records demand so an
 * admin can add the product; the app shows "chưa có dữ liệu".
 */
app.get('/foods/barcode/:code', async (c) => {
  const code = c.req.param('code');
  const db = c.get('db');
  const user = c.get('user');

  const rows = await db.select().from(foods).where(eq(foods.barcode, code)).limit(1);
  if (rows[0]) return c.json(rows[0]);

  const now = Date.now();
  await db.insert(barcodeScanMisses).values({
    id: newId(),
    barcode: code,
    scanCount: 1,
    firstScannedBy: user.id,
    status: 'pending',
    firstScannedAt: now,
    lastScannedAt: now,
  }).onConflictDoUpdate({
    target: barcodeScanMisses.barcode,
    set: {
      scanCount: sql`${barcodeScanMisses.scanCount} + 1`,
      lastScannedAt: now,
    },
  });

  throw new ApiError('BARCODE_NOT_FOUND', 'Chưa có dữ liệu cho mã vạch này');
});

/**
 * After a scan miss the user can tell us what the product was and attach a photo
 * of the packaging. That is what turns the queue from a list of bare numbers into
 * something an admin can actually type up without owning the product.
 */
app.post('/foods/barcode/:code/report', async (c) => {
  const body = await parseBody(c, z.object({
    productNameHint: z.string().max(200).nullish(),
    photoAssetId: z.string().uuid().nullish(),
  }));
  const code = c.req.param('code');
  const db = c.get('db');
  const user = c.get('user');

  if (body.photoAssetId) {
    const asset = await db.select().from(mediaAssets).where(and(
      eq(mediaAssets.id, body.photoAssetId), eq(mediaAssets.userId, user.id),
    )).limit(1);
    if (!asset[0]) throw notFound('Photo asset');
    await db.update(mediaAssets).set({ isOrphan: false })
      .where(eq(mediaAssets.id, body.photoAssetId));
  }

  const now = Date.now();
  await db.insert(barcodeScanMisses).values({
    id: newId(),
    barcode: code,
    scanCount: 1,
    firstScannedBy: user.id,
    productNameHint: body.productNameHint ?? null,
    photoAssetId: body.photoAssetId ?? null,
    status: 'pending',
    firstScannedAt: now,
    lastScannedAt: now,
  }).onConflictDoUpdate({
    target: barcodeScanMisses.barcode,
    set: {
      // Never clobber an existing hint with an empty one.
      productNameHint: body.productNameHint ?? sql`${barcodeScanMisses.productNameHint}`,
      photoAssetId: body.photoAssetId ?? sql`${barcodeScanMisses.photoAssetId}`,
      lastScannedAt: now,
    },
  });

  return c.json({ barcode: code, reported: true }, 201);
});

const userFoodSchema = z.object({
  name: z.string().min(1).max(200),
  servingSizeG: z.number().positive().default(100),
  servingLabel: z.string().max(100).nullish(),
  basedOnFoodId: z.string().uuid().nullish(),
  isRecipe: z.boolean().default(false),
  notes: z.string().max(1000).nullish(),
  ingredients: z.array(z.object({
    ingredientName: z.string().min(1),
    quantityG: z.number().positive(),
    foodId: z.string().uuid().nullish(),
  })).optional(),
  ...nutrientFields,
});

app.get('/me/foods', async (c) => {
  const q = parseQuery(c, paginationSchema);
  const filters = [eq(userFoods.userId, c.get('user').id)];
  if (q.cursor) filters.push(sql`${userFoods.id} < ${q.cursor}`);

  const rows = await c.get('db').select().from(userFoods)
    .where(and(...filters)).orderBy(desc(userFoods.id)).limit(q.limit + 1);
  return c.json(page(rows, q.limit));
});

app.post('/me/foods', async (c) => {
  const body = await parseBody(c, userFoodSchema);
  const db = c.get('db');
  const id = newId();
  const now = Date.now();

  await db.insert(userFoods).values({
    id,
    userId: c.get('user').id,
    basedOnFoodId: body.basedOnFoodId ?? null,
    name: body.name,
    servingSizeG: body.servingSizeG,
    servingLabel: body.servingLabel ?? null,
    caloriesKcal: body.caloriesKcal,
    proteinG: body.proteinG ?? null,
    carbsG: body.carbsG ?? null,
    fatG: body.fatG ?? null,
    saturatedFatG: body.saturatedFatG ?? null,
    fiberG: body.fiberG ?? null,
    sugarG: body.sugarG ?? null,
    sodiumMg: body.sodiumMg ?? null,
    cholesterolMg: body.cholesterolMg ?? null,
    isRecipe: body.isRecipe,
    notes: body.notes ?? null,
    createdAt: now,
    updatedAt: now,
  });

  if (body.ingredients?.length) {
    await insertMany(
      (chunk) => db.insert(userFoodIngredients).values(chunk),
      body.ingredients.map((i) => ({
        userFoodId: id,
        foodId: i.foodId ?? null,
        ingredientName: i.ingredientName,
        quantityG: i.quantityG,
        createdAt: now,
      })),
    );
  }

  const rows = await db.select().from(userFoods).where(eq(userFoods.id, id)).limit(1);
  return c.json(rows[0], 201);
});

app.delete('/me/foods/:id', async (c) => {
  const db = c.get('db');
  const res = await db.delete(userFoods).where(and(
    eq(userFoods.id, c.req.param('id')),
    eq(userFoods.userId, c.get('user').id),
  ));
  void res;
  return c.body(null, 204);
});

// ------------------------------------------------------ daily & planning

app.get('/nutrition/daily', async (c) => {
  const q = parseQuery(c, z.object({ date: isoDateSchema.optional() }));
  const user = c.get('user');
  const db = c.get('db');
  const day = q.date ?? localDate(Date.now(), user.timezone);

  const [summaryRows, meals, inputs] = await Promise.all([
    db.select().from(dailyNutritionSummaries).where(and(
      eq(dailyNutritionSummaries.userId, user.id),
      eq(dailyNutritionSummaries.localDate, day),
    )).limit(1),
    db.select().from(mealLogs).where(and(
      eq(mealLogs.userId, user.id), eq(mealLogs.localDate, day),
    )).orderBy(mealLogs.loggedAt),
    loadTdeeInputs(db, user.id),
  ]);

  const summary = summaryRows[0];
  const energy = computeBmrTdee(inputs, summary?.caloriesBurnedWorkoutKcal ?? 0);

  return c.json({
    date: day,
    summary: summary ?? null,
    // Counts, not components: the day view says "3 thành phần" without paying
    // for every ingredient of every meal.
    meals: await summariseMeals(db, meals),
    energy,
  });
});

app.get('/nutrition/range', async (c) => {
  const q = parseQuery(c, z.object({ from: isoDateSchema, to: isoDateSchema }));
  const rows = await c.get('db').select().from(dailyNutritionSummaries).where(and(
    eq(dailyNutritionSummaries.userId, c.get('user').id),
    gte(dailyNutritionSummaries.localDate, q.from),
    lte(dailyNutritionSummaries.localDate, q.to),
  )).orderBy(dailyNutritionSummaries.localDate);
  return c.json({ items: rows });
});

app.get('/meal-plans', async (c) => {
  const q = parseQuery(c, z.object({ date: isoDateSchema.optional() }));
  const user = c.get('user');
  const day = q.date ?? localDate(Date.now(), user.timezone);

  const rows = await c.get('db').select().from(mealPlans).where(and(
    eq(mealPlans.userId, user.id), eq(mealPlans.planDate, day),
  ));
  return c.json({ items: rows });
});

const generatePlanSchema = z.object({
  date: isoDateSchema,
  mealTypes: z.array(z.enum(MEAL_TYPES)).min(1).default(['breakfast', 'lunch', 'dinner']),
});

app.post('/meal-plans/generate', async (c) => {
  const body = await parseBody(c, generatePlanSchema);
  const user = c.get('user');
  const db = c.get('db');

  const ctx = await buildCoachContext(db, c.env, user.id, user.timezone);
  const prompt = `Lên thực đơn ngày ${body.date} cho các bữa: ${body.mealTypes.join(', ')}.
Món ăn phải phù hợp khẩu vị Việt Nam, tính đến bệnh nền và mục tiêu.
Trả về DUY NHẤT JSON:
[{"mealType":"breakfast","title":"...","description":"...","targetCaloriesKcal":0,"targetProteinG":0,"targetCarbsG":0,"targetFatG":0,"rationale":"vì sao chọn món này"}]`;

  const text = await completeCoachReply(c.env, ctx, [{ role: 'user', content: prompt }]);
  const start = text.indexOf('[');
  const end = text.lastIndexOf(']');
  if (start === -1 || end <= start) {
    throw new ApiError('UPSTREAM_AI_ERROR', 'Model did not return a plan');
  }

  let parsed: Array<Record<string, unknown>>;
  try {
    parsed = JSON.parse(text.slice(start, end + 1)) as Array<Record<string, unknown>>;
  } catch {
    throw new ApiError('UPSTREAM_AI_ERROR', 'Plan JSON is malformed');
  }

  const now = Date.now();
  const rows = parsed.flatMap((p) => {
    const mealType = String(p.mealType ?? '');
    if (!MEAL_TYPES.includes(mealType as typeof MEAL_TYPES[number])) return [];
    const numOrNull = (v: unknown) => (Number.isFinite(Number(v)) ? Number(v) : null);
    return [{
      id: newId(),
      userId: user.id,
      planDate: body.date,
      mealType: mealType as typeof MEAL_TYPES[number],
      title: String(p.title ?? 'Bữa ăn'),
      description: p.description ? String(p.description) : null,
      targetCaloriesKcal: numOrNull(p.targetCaloriesKcal),
      targetProteinG: numOrNull(p.targetProteinG),
      targetCarbsG: numOrNull(p.targetCarbsG),
      targetFatG: numOrNull(p.targetFatG),
      rationale: p.rationale ? String(p.rationale) : null,
      generatedByModel: modelConfig(c.env).chat,
      status: 'suggested' as const,
      createdAt: now,
      updatedAt: now,
    }];
  });

  if (rows.length === 0) throw new ApiError('UPSTREAM_AI_ERROR', 'Plan contained no valid meals');

  await db.delete(mealPlans).where(and(
    eq(mealPlans.userId, user.id),
    eq(mealPlans.planDate, body.date),
    eq(mealPlans.status, 'suggested'),
  ));
  await db.insert(mealPlans).values(rows);

  return c.json({ items: rows }, 201);
});

app.patch('/meal-plans/:id', async (c) => {
  const body = await parseBody(c, z.object({
    status: z.enum(['suggested', 'accepted', 'skipped', 'expired']),
  }));
  const db = c.get('db');

  await db.update(mealPlans).set({ status: body.status, updatedAt: Date.now() })
    .where(and(eq(mealPlans.id, c.req.param('id')), eq(mealPlans.userId, c.get('user').id)));

  const rows = await db.select().from(mealPlans).where(eq(mealPlans.id, c.req.param('id'))).limit(1);
  if (!rows[0]) throw notFound('Meal plan');
  return c.json(rows[0]);
});

export default app;
