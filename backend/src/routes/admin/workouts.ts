import { Hono } from 'hono';
import { and, asc, eq, gt, isNotNull } from 'drizzle-orm';
import { z } from 'zod';
import { mediaAssets, workoutSessions, workoutStreams } from '../../db/schema';
import { parseBody } from '../../lib/http';
import { applyStream } from '../training';
import type { AppEnv } from '../../env';

const app = new Hono<AppEnv>();

/**
 * Replay stored streams through the current derivation.
 *
 * Every number on the run detail screen except the raw samples themselves is
 * derived, and the derivation has been wrong: total ascent added up GPS noise
 * (a flat 7.3 km run recorded 534.5 m of climb on a route whose highest point
 * was 7.9 m), and moving time was never separated from elapsed time because the
 * recorder did not send a pause flag. Fixing the algorithm fixes new runs; the
 * ones already recorded need replaying, and the full-fidelity samples are still
 * in R2, so nothing has to be guessed.
 *
 * Batched and cursored rather than a single sweep: each session costs an R2
 * read plus a dozen writes, and a Worker invocation is not the place to do a
 * few thousand of those. The caller walks `nextCursor` until it comes back
 * null. It is idempotent — running it twice lands on the same numbers — and
 * personal-best RANKS are deliberately left as they were, so replaying history
 * does not rewrite the board.
 */
app.post('/rederive-streams', async (c) => {
  const body = await parseBody(c, z.object({
    /** Session id to resume after; sessions are walked in id order. */
    cursor: z.string().nullish(),
    limit: z.number().int().min(1).max(50).default(20),
    /** Report what would change without writing anything. */
    dryRun: z.boolean().default(false),
  }));
  const db = c.get('db');

  const rows = await db
    .select({
      session: workoutSessions,
      assetId: mediaAssets.id,
      r2Key: mediaAssets.r2Key,
    })
    .from(workoutStreams)
    .innerJoin(workoutSessions, eq(workoutSessions.id, workoutStreams.workoutSessionId))
    .innerJoin(mediaAssets, eq(mediaAssets.id, workoutStreams.r2AssetId))
    .where(and(
      isNotNull(workoutStreams.r2AssetId),
      body.cursor ? gt(workoutSessions.id, body.cursor) : undefined,
    ))
    .orderBy(asc(workoutSessions.id))
    .limit(body.limit);

  const changed: {
    id: string;
    elevationGainM: [number | null, number];
    movingSeconds: [number | null, number];
    stoppedSeconds: number;
  }[] = [];
  const failed: { id: string; reason: string }[] = [];

  for (const row of rows) {
    try {
      const object = await c.env.MEDIA.get(row.r2Key);
      if (!object) {
        failed.push({ id: row.session.id, reason: 'stream object missing' });
        continue;
      }
      const text = await object.text();
      if (body.dryRun) {
        const { deriveFromSamples, normaliseSamples, parseSampleStream } =
          await import('../../services/workoutStream');
        const totals = deriveFromSamples(normaliseSamples(parseSampleStream(text))).totals;
        changed.push({
          id: row.session.id,
          elevationGainM: [row.session.elevationGainM, totals.elevationGainM],
          movingSeconds: [row.session.movingSeconds, totals.movingSeconds],
          stoppedSeconds: totals.stoppedSeconds,
        });
        continue;
      }
      const { derivation } = await applyStream(
        db, row.session.userId, row.session, row.assetId, text,
      );
      changed.push({
        id: row.session.id,
        elevationGainM: [row.session.elevationGainM, derivation.totals.elevationGainM],
        movingSeconds: [row.session.movingSeconds, derivation.totals.movingSeconds],
        stoppedSeconds: derivation.totals.stoppedSeconds,
      });
    } catch (err) {
      failed.push({ id: row.session.id, reason: err instanceof Error ? err.message : String(err) });
    }
  }

  const last = rows[rows.length - 1];
  return c.json({
    scanned: rows.length,
    changed,
    failed,
    nextCursor: rows.length === body.limit && last ? last.session.id : null,
  });
});

export default app;
