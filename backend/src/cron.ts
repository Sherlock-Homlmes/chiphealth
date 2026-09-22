import { and, eq, inArray, isNull, lt, sql } from 'drizzle-orm';
import { createDb } from './db/client';
import {
  users, mediaAssets, sleepReminders, foodKbDocuments, foods, mealAiAnalyses,
} from './db/schema';
import { localDate, localTime, localWeekday, addDays } from './lib/time';
import { recomputeSleepDebt } from './services/sleepDebt';
import { recomputeDailyNutritionSummary } from './services/nutritionMath';
import { generateDailyInsights } from './services/coach';
import { purgeExpiredFacts } from './services/agent/memory';
import { sendPush } from './services/push';
import { upsertVector } from './services/vectorize';
import { modelConfig } from './config/models';
import {
  MEAL_ANALYSIS_TIMEOUT_MS, ANALYSIS_TIMEOUT_MESSAGE,
} from './services/mealAnalysis';
import type { Bindings } from './env';
import type { Db } from './db/client';

/** One user's failure must never abort the whole run. */
async function safely(label: string, fn: () => Promise<unknown>): Promise<void> {
  try {
    await fn();
  } catch (err) {
    console.error(`cron ${label} failed`, err);
  }
}

async function activeUsers(db: Db) {
  return db.select({
    id: users.id, timezone: users.timezone, locale: users.locale,
  }).from(users).where(isNull(users.deletedAt));
}

/**
 * Reminders are stored in the user's local wall-clock time, so the only way to
 * fire them correctly is to evaluate each user's own timezone. The 15-minute
 * cadence means a match is anything inside the last 15 minutes, and
 * `last_fired_at` stops a double send.
 */
async function fireDueReminders(db: Db, env: Bindings): Promise<number> {
  const now = Date.now();
  const rows = await db.select({
    reminder: sleepReminders,
    timezone: users.timezone,
  }).from(sleepReminders)
    .innerJoin(users, eq(sleepReminders.userId, users.id))
    .where(and(eq(sleepReminders.isEnabled, true), isNull(users.deletedAt)));

  let sent = 0;
  for (const { reminder, timezone } of rows) {
    const weekday = localWeekday(now, timezone);
    if (!reminder.daysOfWeek.split(',').map((d) => d.trim()).includes(weekday)) continue;

    const nowMinutes = toMinutes(localTime(now, timezone));
    const dueMinutes = toMinutes(reminder.remindAtLocal);
    if (nowMinutes === null || dueMinutes === null) continue;

    const delta = nowMinutes - dueMinutes;
    if (delta < 0 || delta >= 15) continue;
    if (reminder.lastFiredAt && now - reminder.lastFiredAt < 12 * 3600_000) continue;

    await safely(`reminder ${reminder.id}`, async () => {
      await sendPush(db, env, reminder.userId, {
        title: reminder.reminderType === 'wakeup' ? 'Dậy thôi!' : 'Đến giờ ngủ',
        body: reminder.reminderType === 'bedtime'
          ? 'Ngủ đúng giờ hôm nay để kéo nợ ngủ xuống.'
          : 'Nhắc nhở từ ChipHealth.',
        data: { type: reminder.reminderType },
      });
      await db.update(sleepReminders).set({ lastFiredAt: now, updatedAt: now })
        .where(eq(sleepReminders.id, reminder.id));
      sent++;
    });
  }
  return sent;
}

function toMinutes(hhmm: string): number | null {
  const [h, m] = hhmm.split(':').map(Number);
  if (h === undefined || m === undefined || !Number.isFinite(h) || !Number.isFinite(m)) return null;
  return h * 60 + m;
}

/** Uploads that were never attached to a meal/moment/event are dead weight in R2. */
async function sweepOrphanMedia(db: Db, env: Bindings): Promise<number> {
  const ttlHours = Number(env.ORPHAN_ASSET_TTL_HOURS ?? 24);
  const cutoff = Date.now() - ttlHours * 3600_000;

  const rows = await db.select().from(mediaAssets)
    .where(and(eq(mediaAssets.isOrphan, true), lt(mediaAssets.createdAt, cutoff)))
    .limit(200);

  let deleted = 0;
  for (const asset of rows) {
    await safely(`orphan ${asset.id}`, async () => {
      await env.MEDIA.delete(asset.r2Key);
      await db.delete(mediaAssets).where(eq(mediaAssets.id, asset.id));
      deleted++;
    });
  }
  return deleted;
}

/**
 * Closes out analyses whose run never came back — a hung model or a queue consumer
 * the platform killed. Reads already fold the timeout in (effectiveAnalysis),
 * so this exists to persist the verdict: without it the row would sit
 * `running` forever, and a late answer could still write items.
 *
 * The attempt is what gets closed; the meal is never touched. Nothing here
 * deletes a meal whose analysis failed — it stays in the diary, failed and
 * retryable, until the user says otherwise. (There used to be a sweeper that
 * threw away failed spoken and typed drafts after a few hours, on the grounds
 * that their clip was gone and nothing could be re-run. The transcript is kept
 * on the attempt now, so they can be re-run — and a meal vanishing on its own
 * was never what the user wanted anyway.)
 */
async function sweepStaleMealAnalyses(db: Db): Promise<number> {
  const swept = await db.update(mealAiAnalyses).set({
    status: 'failed',
    errorMessage: ANALYSIS_TIMEOUT_MESSAGE,
    completedAt: Date.now(),
  }).where(and(
    inArray(mealAiAnalyses.status, ['pending', 'running']),
    lt(mealAiAnalyses.createdAt, Date.now() - MEAL_ANALYSIS_TIMEOUT_MS),
  )).returning({ id: mealAiAnalyses.id });
  return swept.length;
}

/** Drains rows whose embedding failed or was never produced. */
async function drainEmbeddingQueue(db: Db, env: Bindings): Promise<number> {
  const { embedding } = modelConfig(env);
  let done = 0;

  const docs = await db.select().from(foodKbDocuments).where(and(
    eq(foodKbDocuments.isActive, true),
    sql`(${foodKbDocuments.embeddingStatus} is null or ${foodKbDocuments.embeddingStatus} != 'indexed')`,
  )).limit(25);

  for (const doc of docs) {
    await safely(`kb embed ${doc.id}`, async () => {
      const vid = await upsertVector(env, 'kb', doc.id, `${doc.title}\n${doc.content}`, {
        title: doc.title, locale: doc.locale,
      });
      await db.update(foodKbDocuments)
        .set({ vectorizeId: vid, embeddingModel: embedding, embeddingStatus: 'indexed' })
        .where(eq(foodKbDocuments.id, doc.id));
      done++;
    });
  }

  const pendingFoods = await db.select().from(foods)
    .where(sql`${foods.embeddingStatus} is null or ${foods.embeddingStatus} != 'indexed'`)
    .limit(25);

  for (const food of pendingFoods) {
    await safely(`food embed ${food.id}`, async () => {
      const text = [food.name, food.brand, food.category].filter(Boolean).join(' · ');
      await upsertVector(env, 'food', food.id, text, {
        title: food.name, verified: food.isVerified,
      });
      await db.update(foods).set({ embeddingStatus: 'indexed' }).where(eq(foods.id, food.id));
      done++;
    });
  }

  return done;
}

/** Nightly rollups, then proactive coaching, per user in their own local day. */
async function nightlyRollups(db: Db, env: Bindings): Promise<number> {
  const people = await activeUsers(db);
  let processed = 0;

  for (const person of people) {
    await safely(`rollup ${person.id}`, async () => {
      const today = localDate(Date.now(), person.timezone);
      const yesterday = addDays(today, -1);

      await recomputeDailyNutritionSummary(db, env, person.id, yesterday);
      await recomputeDailyNutritionSummary(db, env, person.id, today);
      await recomputeSleepDebt(db, env, person.id, today);
      await generateDailyInsights(db, env, person.id, person.timezone, person.locale);
      processed++;
    });
  }
  return processed;
}

export async function runScheduled(
  event: ScheduledController, env: Bindings, ctx: ExecutionContext,
): Promise<void> {
  const db = createDb(env.DB);

  const work = async () => {
    if (event.cron === '0 19 * * *') {
      const processed = await nightlyRollups(db, env);
      // Housekeeping only: every read already filters expired facts out, so a
      // night this does not run costs space, never correctness.
      const facts = await purgeExpiredFacts(db).catch(() => 0);
      console.log(`cron nightly: ${processed} users, ${facts} expired facts purged`);
      return;
    }

    const [reminders, orphans, embeddings, stale] = await Promise.all([
      fireDueReminders(db, env).catch(() => 0),
      sweepOrphanMedia(db, env).catch(() => 0),
      drainEmbeddingQueue(db, env).catch(() => 0),
      sweepStaleMealAnalyses(db).catch(() => 0),
    ]);
    console.log(
      `cron 15m: ${reminders} reminders, ${orphans} orphans, `
      + `${embeddings} embeddings, ${stale} timed-out analyses`,
    );
  };

  ctx.waitUntil(work());
}
