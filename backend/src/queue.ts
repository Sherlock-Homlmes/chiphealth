import { and, desc, eq, gt, lt } from 'drizzle-orm';
import { createDb, type Db } from './db/client';
import { mealAiAnalyses, mealLogs, mediaAssets } from './db/schema';
import {
  analyzeMealFromSpeech, analyzeMealPhoto, MEAL_ANALYSIS_TIMEOUT_MS, retryableInput,
} from './services/mealAnalysis';
import type { Bindings } from './env';

/**
 * One meal analysis to run. The analysis row is created by the request that
 * enqueues this, so the client can start polling straight away.
 *
 * Why a queue and not waitUntil: waitUntil lives at most 30 s past the response,
 * and the vision model alone takes 30-60 s — the run was cut off mid-flight and
 * sat `running` until the 15-minute timeout called it failed. A queue consumer
 * gets minutes, and a consumer that dies (deploy, dev hot-reload) leaves the
 * message unacked, so it is delivered again instead of lost.
 */
export type MealAnalysisJob =
  | { kind: 'photo'; mealLogId: string; userId: string; analysisId: string; photoR2Key: string }
  | { kind: 'speech'; mealLogId: string; userId: string; analysisId: string; transcript: string };

export async function runMealAnalysisBatch(
  batch: MessageBatch<MealAnalysisJob>, env: Bindings,
): Promise<void> {
  const db = createDb(env.DB);

  for (const msg of batch.messages) {
    const job = msg.body;
    // A redelivered job whose row is no longer running was finished, swept or
    // superseded in the meantime — running it again would only be discarded.
    const row = await db.select({ id: mealAiAnalyses.id }).from(mealAiAnalyses)
      .where(and(eq(mealAiAnalyses.id, job.analysisId), eq(mealAiAnalyses.status, 'running')))
      .limit(1);
    if (!row[0]) {
      msg.ack();
      continue;
    }

    try {
      if (job.kind === 'photo') {
        await analyzeMealPhoto(db, env, job);
      } else {
        await analyzeMealFromSpeech(db, env, job);
      }
    } catch (err) {
      // The pipeline has already closed the row as failed with its reason; the
      // user retries from the app. Retrying here would run on a failed row.
      console.error('meal analysis failed', job.analysisId, err);
    }
    msg.ack();
  }
}

let recovered = false;
/** Runs created after this belong to the new isolate and still have their job. */
const bootedAt = Date.now();

/**
 * Local dev only. `wrangler dev` keeps its queue in memory and reloads the
 * Worker whenever a source file changes, so a reload in the middle of an
 * analysis drops the job for good and the meal sits "analysing" until the
 * 15-minute timeout. In production the queue is durable and redelivers on its
 * own; here there is a single isolate, so the first request a fresh one serves
 * knows every run still marked `running` lost its job, and puts it back.
 *
 * Both kinds are re-queued: a photo run still has its photo, and a spoken run
 * still has the transcript the request wrote onto its attempt row — the clip is
 * gone, but the words the model is actually given are not.
 */
export async function requeueOrphanedAnalyses(env: Bindings, db: Db): Promise<void> {
  if (recovered || env.ENVIRONMENT !== 'development') return;
  recovered = true;

  const rows = await db.select({
      analysisId: mealAiAnalyses.id,
      mealLogId: mealLogs.id,
      userId: mealLogs.userId,
      photoR2Key: mediaAssets.r2Key,
      inputText: mealAiAnalyses.inputText,
    })
    .from(mealAiAnalyses)
    .innerJoin(mealLogs, eq(mealLogs.id, mealAiAnalyses.mealLogId))
    .leftJoin(mediaAssets, eq(mediaAssets.id, mealLogs.photoAssetId))
    .where(and(
      eq(mealAiAnalyses.status, 'running'),
      gt(mealAiAnalyses.createdAt, Date.now() - MEAL_ANALYSIS_TIMEOUT_MS),
      lt(mealAiAnalyses.createdAt, bootedAt),
    ))
    .orderBy(desc(mealAiAnalyses.id));

  for (const r of rows) {
    const input = retryableInput(r.photoR2Key, r.inputText);
    if (input) {
      console.log('dev reload: re-queueing meal analysis', r.analysisId);
      await env.MEAL_ANALYSIS.send({
        ...input,
        mealLogId: r.mealLogId,
        userId: r.userId,
        analysisId: r.analysisId,
      });
    } else {
      // Nothing left to run: an attempt from before input_text existed. Failed
      // now rather than left to the 15-minute clock — and the meal stays put, so
      // the user still has the row and can log it again from there.
      await db.update(mealAiAnalyses).set({
        status: 'failed',
        errorMessage: 'Máy chủ khởi động lại giữa chừng — hãy ghi lại',
        completedAt: Date.now(),
      }).where(and(
        eq(mealAiAnalyses.id, r.analysisId),
        eq(mealAiAnalyses.status, 'running'),
      ));
    }
  }
}
