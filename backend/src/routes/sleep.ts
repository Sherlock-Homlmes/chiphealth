import { Hono } from 'hono';
import { and, asc, desc, eq, gte, inArray, isNull, lte, sql } from 'drizzle-orm';
import { z } from 'zod';
import {
  sleepSessions, sleepStageSegments, sleepAudioEvents, sleepReminders, sleepPhotos,
  mediaAssets,
} from '../db/schema';
import { parseBody, parseQuery, paginationSchema, page, isoDateSchema } from '../lib/http';
import { ApiError, notFound } from '../lib/errors';
import { newId } from '../lib/ids';
import { localDate } from '../lib/time';
import { recomputeSleepDebt, sleepDebtFor } from '../services/sleepDebt';
import { accountLocale } from '../lib/language';
import { transcribeAudio } from '../services/speech';
import { insertMany } from '../db/client';
import type { AppEnv } from '../env';

const app = new Hono<AppEnv>();

const STAGES = ['awake', 'light', 'deep', 'rem'] as const;
const EVENT_TYPES = ['snore', 'sleep_talk', 'cough', 'movement', 'apnea_suspect', 'other'] as const;

const sessionSchema = z.object({
  id: z.string().uuid().optional(),
  source: z.enum(['health_sync', 'phone_mic', 'manual']),
  externalId: z.string().max(200).nullish(),
  startedAt: z.number().int().positive(),
  endedAt: z.number().int().positive(),
  inBedSeconds: z.number().int().nonnegative().nullish(),
  sleepLatencySeconds: z.number().int().nonnegative().nullish(),
  avgHeartRate: z.number().int().nullish(),
  audioRecordingEnabled: z.boolean().default(false),
  stages: z.array(z.object({
    stage: z.enum(STAGES),
    startedAt: z.number().int().positive(),
    endedAt: z.number().int().positive(),
    confidence: z.number().min(0).max(1).nullish(),
  })).default([]),
  events: z.array(z.object({
    eventType: z.enum(EVENT_TYPES),
    occurredAt: z.number().int().positive(),
    durationMs: z.number().int().nonnegative().nullish(),
    peakDb: z.number().nullish(),
    confidence: z.number().min(0).max(1).nullish(),
    audioAssetId: z.string().uuid().nullish(),
    transcript: z.string().max(2000).nullish(),
  })).default([]),
});

/** Stage seconds are derived from the segments, never trusted from the client. */
function stageTotals(stages: { stage: typeof STAGES[number]; startedAt: number; endedAt: number }[]) {
  const totals = { awake: 0, light: 0, deep: 0, rem: 0 };
  for (const s of stages) {
    const seconds = Math.max(0, Math.round((s.endedAt - s.startedAt) / 1000));
    totals[s.stage] += seconds;
  }
  const asleep = totals.light + totals.deep + totals.rem;
  return { ...totals, asleep };
}

/** Which stage covers an instant — denormalized onto each audio event. */
function stageAt(
  stages: z.infer<typeof sessionSchema>['stages'], at: number,
): typeof STAGES[number] | null {
  return stages.find((s) => at >= s.startedAt && at < s.endedAt)?.stage ?? null;
}

/**
 * One sleep arrives in one request — a night, or a nap; a day can hold several
 * and they do not replace each other. What makes a write an UPDATE rather than
 * an INSERT is the id: either the one the client minted for this recording, or
 * the row already holding this (source, external_id) when a wearable re-syncs
 * a night it has sent before.
 */
app.post('/sessions', async (c) => {
  const body = await parseBody(c, sessionSchema);
  const user = c.get('user');
  const db = c.get('db');

  if (body.endedAt <= body.startedAt) {
    throw new ApiError('VALIDATION_ERROR', 'endedAt must be after startedAt');
  }

  const day = localDate(body.endedAt, user.timezone);
  const totals = stageTotals(body.stages);
  const inBed = body.inBedSeconds ?? Math.round((body.endedAt - body.startedAt) / 1000);
  const totalSleep = totals.asleep > 0
    ? totals.asleep
    : Math.max(0, inBed - (body.sleepLatencySeconds ?? 0));

  // A re-synced wearable night is the same night: match it on its external id.
  const resynced = body.externalId
    ? await db.select({ id: sleepSessions.id }).from(sleepSessions)
      .where(and(
        eq(sleepSessions.userId, user.id),
        eq(sleepSessions.source, body.source),
        eq(sleepSessions.externalId, body.externalId),
      )).limit(1)
    : [];

  // A client-minted id that already belongs to someone else is not writable
  // through here: the upsert below would overwrite that row.
  if (!resynced[0] && body.id) {
    const owner = await db.select({ userId: sleepSessions.userId }).from(sleepSessions)
      .where(eq(sleepSessions.id, body.id)).limit(1);
    if (owner[0] && owner[0].userId !== user.id) throw notFound('Sleep session');
  }

  const id = resynced[0]?.id ?? body.id ?? newId();
  const now = Date.now();
  const efficiency = inBed > 0 ? Math.round((totalSleep / inBed) * 1000) / 1000 : null;

  const values = {
    userId: user.id,
    source: body.source,
    externalId: body.externalId ?? null,
    startedAt: body.startedAt,
    endedAt: body.endedAt,
    localDate: day,
    inBedSeconds: inBed,
    totalSleepSeconds: totalSleep,
    awakeSeconds: totals.awake,
    lightSeconds: totals.light,
    deepSeconds: totals.deep,
    remSeconds: totals.rem,
    sleepLatencySeconds: body.sleepLatencySeconds ?? null,
    sleepEfficiency: efficiency,
    sleepScore: sleepScore(totals, totalSleep, efficiency),
    avgHeartRate: body.avgHeartRate ?? null,
    // Phone-mic nights infer stages from audio + motion, so flag them as estimates.
    stagesAreEstimated: body.source === 'phone_mic',
    audioRecordingEnabled: body.audioRecordingEnabled,
    updatedAt: now,
  };

  await db.insert(sleepSessions).values({ id, createdAt: now, ...values })
    .onConflictDoUpdate({ target: sleepSessions.id, set: values });

  await db.delete(sleepStageSegments).where(eq(sleepStageSegments.sleepSessionId, id));
  if (body.stages.length > 0) {
    await insertMany(
      (chunk) => db.insert(sleepStageSegments).values(chunk),
      body.stages.map((s) => ({
        sleepSessionId: id,
        stage: s.stage,
        startedAt: s.startedAt,
        endedAt: s.endedAt,
        confidence: s.confidence ?? null,
      })),
    );
  }

  await db.delete(sleepAudioEvents).where(eq(sleepAudioEvents.sleepSessionId, id));
  if (body.events.length > 0) {
    const assetIds = body.events.map((e) => e.audioAssetId).filter((x): x is string => Boolean(x));
    if (assetIds.length > 0) {
      await db.update(mediaAssets).set({ isOrphan: false })
        .where(sql`${mediaAssets.id} in ${assetIds}`);
    }
    await insertMany(
      (chunk) => db.insert(sleepAudioEvents).values(chunk),
      body.events.map((e) => ({
        sleepSessionId: id,
        eventType: e.eventType,
        occurredAt: e.occurredAt,
        durationMs: e.durationMs ?? null,
        peakDb: e.peakDb ?? null,
        confidence: e.confidence ?? null,
        audioAssetId: e.audioAssetId ?? null,
        transcript: e.transcript ?? null,
        stageAtEvent: stageAt(body.stages, e.occurredAt),
        createdAt: now,
      })),
    );
  }

  await recomputeSleepDebt(db, c.env, user.id, day);

  const rows = await db.select().from(sleepSessions).where(eq(sleepSessions.id, id)).limit(1);
  return c.json(rows[0], 201);
});

/** 0-100: duration against target dominates, efficiency and deep+REM share adjust. */
function sleepScore(
  totals: { deep: number; rem: number },
  totalSleep: number,
  efficiency: number | null,
): number {
  const durationScore = Math.min(1, totalSleep / (8 * 3600)) * 60;
  const efficiencyScore = (efficiency ?? 0.85) * 20;
  const restorative = totalSleep > 0 ? (totals.deep + totals.rem) / totalSleep : 0;
  // 45% deep+REM is the top of the normal adult range; treat that as full marks.
  const qualityScore = Math.min(1, restorative / 0.45) * 20;
  return Math.round(durationScore + efficiencyScore + qualityScore);
}

app.get('/sessions', async (c) => {
  const q = parseQuery(c, paginationSchema.extend({
    from: isoDateSchema.optional(),
    to: isoDateSchema.optional(),
  }));
  const filters = [eq(sleepSessions.userId, c.get('user').id)];
  if (q.from) filters.push(gte(sleepSessions.localDate, q.from));
  if (q.to) filters.push(lte(sleepSessions.localDate, q.to));
  // Newest sleep first, by when it *started*. The id is a UUIDv7 minted when
  // the recording was uploaded, so ordering by it put a night typed in this
  // morning above the nap that actually came after it, and a day with a nap
  // and a night read in the wrong order. The id stays in the sort as the
  // tiebreak, which is what keeps the keyset cursor below unambiguous.
  if (q.cursor) {
    const [cursorStart, cursorId] = splitSleepCursor(q.cursor);
    filters.push(sql`(${sleepSessions.startedAt} < ${cursorStart}
      or (${sleepSessions.startedAt} = ${cursorStart} and ${sleepSessions.id} < ${cursorId}))`);
  }

  const rows = await c.get('db').select().from(sleepSessions)
    .where(and(...filters))
    .orderBy(desc(sleepSessions.startedAt), desc(sleepSessions.id))
    .limit(q.limit + 1);

  const hasMore = rows.length > q.limit;
  const items = hasMore ? rows.slice(0, q.limit) : rows;
  const last = items[items.length - 1];
  return c.json({
    items,
    nextCursor: hasMore && last ? `${last.startedAt}.${last.id}` : null,
  });
});

/**
 * `<startedAt>.<id>`, the keyset the list pages on. An old client's plain id
 * cursor still parses — it just pages from the top, which is the safe way to
 * be wrong: the page repeats rows rather than skipping them.
 */
function splitSleepCursor(cursor: string): [number, string] {
  const dot = cursor.indexOf('.');
  if (dot === -1) return [Number.MAX_SAFE_INTEGER, cursor];
  return [Number(cursor.slice(0, dot)) || 0, cursor.slice(dot + 1)];
}

async function ownedSession(db: AppEnv['Variables']['db'], userId: string, id: string) {
  const rows = await db.select().from(sleepSessions)
    .where(and(eq(sleepSessions.id, id), eq(sleepSessions.userId, userId))).limit(1);
  const session = rows[0];
  if (!session) throw notFound('Sleep session');
  return session;
}

/**
 * Full-replace, the same semantics as the workout photo strip: the client
 * sends the ordered list it wants. An asset only counts as unreferenced once
 * this night has let go of it, so the orphan sweep runs last.
 */
async function setSleepPhotos(
  db: AppEnv['Variables']['db'], userId: string, sessionId: string, ids: string[],
) {
  const unique = [...new Set(ids)];
  const previous = (await db.select({ assetId: sleepPhotos.assetId })
    .from(sleepPhotos).where(eq(sleepPhotos.sleepSessionId, sessionId)))
    .map((r) => r.assetId);
  const added = unique.filter((id) => !previous.includes(id));

  if (added.length > 0) {
    const assets = await db.select().from(mediaAssets)
      .where(and(inArray(mediaAssets.id, added), eq(mediaAssets.userId, userId)));
    if (assets.length !== added.length) throw notFound('Photo asset');
    // Photos are uploaded as 'meal_photo': media_assets' kind CHECK cannot be
    // widened on D1, and that kind already gives images-only, owner-only reads.
    if (assets.some((a) => a.kind !== 'meal_photo')) {
      throw new ApiError('VALIDATION_ERROR', 'Only photo assets can be attached');
    }
  }

  await db.delete(sleepPhotos).where(eq(sleepPhotos.sleepSessionId, sessionId));
  if (unique.length > 0) {
    await insertMany(
      (chunk) => db.insert(sleepPhotos).values(chunk),
      unique.map((assetId, sortOrder) => ({
        sleepSessionId: sessionId,
        assetId,
        sortOrder,
        createdAt: Date.now(),
      })),
    );
    await db.update(mediaAssets).set({ isOrphan: false })
      .where(inArray(mediaAssets.id, unique));
  }

  const removed = previous.filter((id) => !unique.includes(id));
  if (removed.length > 0) {
    const stillLinked = (await db.select({ assetId: sleepPhotos.assetId })
      .from(sleepPhotos).where(inArray(sleepPhotos.assetId, removed)))
      .map((r) => r.assetId);
    const loose = removed.filter((id) => !stillLinked.includes(id));
    if (loose.length > 0) {
      await db.update(mediaAssets).set({ isOrphan: true })
        .where(inArray(mediaAssets.id, loose));
    }
  }
}

async function photosFor(
  db: AppEnv['Variables']['db'], sessionId: string,
): Promise<string[]> {
  const rows = await db.select({ assetId: sleepPhotos.assetId })
    .from(sleepPhotos)
    .where(eq(sleepPhotos.sleepSessionId, sessionId))
    .orderBy(asc(sleepPhotos.sortOrder));
  return rows.map((r) => r.assetId);
}

app.get('/sessions/:id', async (c) => {
  const db = c.get('db');
  const session = await ownedSession(db, c.get('user').id, c.req.param('id'));

  const [stages, events, photoAssetIds] = await Promise.all([
    db.select().from(sleepStageSegments)
      .where(eq(sleepStageSegments.sleepSessionId, session.id))
      .orderBy(asc(sleepStageSegments.startedAt)),
    db.select().from(sleepAudioEvents)
      .where(and(
        eq(sleepAudioEvents.sleepSessionId, session.id),
        isNull(sleepAudioEvents.deletedAt),
      ))
      .orderBy(asc(sleepAudioEvents.occurredAt)),
    photosFor(db, session.id),
  ]);

  return c.json({ ...session, stages, events, photoAssetIds });
});

/**
 * Moves bedtime / wake-up. Anything recorded outside the new window — stage
 * segments, snore / sleep-talk events and their clips — is cut away, and the
 * totals and score are derived again from what is left.
 */
app.patch('/sessions/:id', async (c) => {
  const body = await parseBody(c, z.object({
    startedAt: z.number().int().positive().optional(),
    endedAt: z.number().int().positive().optional(),
    title: z.string().max(200).nullish(),
    notes: z.string().max(2000).nullish(),
    photoAssetIds: z.array(z.string().uuid()).max(5).optional(),
  }));
  const db = c.get('db');
  const user = c.get('user');
  const session = await ownedSession(db, user.id, c.req.param('id'));

  const startedAt = body.startedAt ?? session.startedAt;
  const endedAt = body.endedAt ?? session.endedAt ?? startedAt;
  if (endedAt <= startedAt) {
    throw new ApiError('VALIDATION_ERROR', 'endedAt must be after startedAt');
  }
  const oldDay = session.localDate;
  const day = localDate(endedAt, user.timezone);
  if (day !== oldDay) {
    const clash = await db.select({ id: sleepSessions.id }).from(sleepSessions)
      .where(and(eq(sleepSessions.userId, user.id), eq(sleepSessions.localDate, day)))
      .limit(1);
    if (clash[0]) throw new ApiError('CONFLICT', 'Another night already ends on that day');
  }

  // Clip the hypnogram to the new window.
  const segments = await db.select().from(sleepStageSegments)
    .where(eq(sleepStageSegments.sleepSessionId, session.id))
    .orderBy(asc(sleepStageSegments.startedAt));
  const kept = segments
    .map((s) => ({ ...s, startedAt: Math.max(s.startedAt, startedAt), endedAt: Math.min(s.endedAt, endedAt) }))
    .filter((s) => s.endedAt > s.startedAt);
  await db.delete(sleepStageSegments).where(eq(sleepStageSegments.sleepSessionId, session.id));
  if (kept.length > 0) {
    await insertMany(
      (chunk) => db.insert(sleepStageSegments).values(chunk),
      kept.map((s) => ({
        sleepSessionId: session.id,
        stage: s.stage,
        startedAt: s.startedAt,
        endedAt: s.endedAt,
        confidence: s.confidence,
      })),
    );
  }

  // Events outside the window go, clips included.
  const outside = and(
    eq(sleepAudioEvents.sleepSessionId, session.id),
    sql`(${sleepAudioEvents.occurredAt} < ${startedAt} or ${sleepAudioEvents.occurredAt} > ${endedAt})`,
  );
  const dropped = await db.select({ assetId: sleepAudioEvents.audioAssetId })
    .from(sleepAudioEvents).where(outside);
  await db.delete(sleepAudioEvents).where(outside);
  await orphanClips(db, dropped.map((e) => e.assetId));

  const totals = stageTotals(kept);
  const inBed = Math.round((endedAt - startedAt) / 1000);
  const totalSleep = totals.asleep > 0
    ? totals.asleep
    : Math.max(0, inBed - (session.sleepLatencySeconds ?? 0));
  const efficiency = inBed > 0 ? Math.round((totalSleep / inBed) * 1000) / 1000 : null;

  await db.update(sleepSessions).set({
    startedAt,
    endedAt,
    localDate: day,
    inBedSeconds: inBed,
    totalSleepSeconds: totalSleep,
    awakeSeconds: totals.awake,
    lightSeconds: totals.light,
    deepSeconds: totals.deep,
    remSeconds: totals.rem,
    sleepEfficiency: efficiency,
    sleepScore: sleepScore(totals, totalSleep, efficiency),
    ...(body.title !== undefined ? { title: body.title?.trim() || null } : {}),
    ...(body.notes !== undefined ? { notes: body.notes?.trim() || null } : {}),
    updatedAt: Date.now(),
  }).where(eq(sleepSessions.id, session.id));

  if (body.photoAssetIds !== undefined) {
    await setSleepPhotos(db, user.id, session.id, body.photoAssetIds);
  }

  await recomputeSleepDebt(db, c.env, user.id, day);
  if (day !== oldDay) await recomputeSleepDebt(db, c.env, user.id, oldDay);

  const rows = await db.select().from(sleepSessions)
    .where(eq(sleepSessions.id, session.id)).limit(1);
  return c.json(rows[0]);
});

/** A whole night, with its stages, events and clips. */
app.delete('/sessions/:id', async (c) => {
  const db = c.get('db');
  const user = c.get('user');
  const session = await ownedSession(db, user.id, c.req.param('id'));

  const clips = await db.select({ assetId: sleepAudioEvents.audioAssetId })
    .from(sleepAudioEvents).where(eq(sleepAudioEvents.sleepSessionId, session.id));
  await db.delete(sleepAudioEvents).where(eq(sleepAudioEvents.sleepSessionId, session.id));
  await db.delete(sleepStageSegments).where(eq(sleepStageSegments.sleepSessionId, session.id));
  await db.delete(sleepSessions).where(eq(sleepSessions.id, session.id));
  await orphanClips(db, clips.map((e) => e.assetId));

  await recomputeSleepDebt(db, c.env, user.id, session.localDate);
  return c.body(null, 204);
});

/** Hands clips nobody points at any more to the orphan sweeper. */
async function orphanClips(db: AppEnv['Variables']['db'], ids: (string | null)[]) {
  const assetIds = ids.filter((x): x is string => Boolean(x));
  if (assetIds.length === 0) return;
  await db.update(mediaAssets).set({ isOrphan: true })
    .where(sql`${mediaAssets.id} in ${assetIds}`);
}

app.get('/debt', async (c) => {
  const q = parseQuery(c, z.object({ date: isoDateSchema.optional() }));
  const user = c.get('user');
  const day = q.date ?? localDate(Date.now(), user.timezone);
  return c.json(await sleepDebtFor(c.get('db'), c.env, user.id, day));
});

/**
 * Hides one event from the night. Soft: the row and its clip stay, because the
 * clip is a recording of the user's own night and the label on it is training
 * data — what the user is asking for is to stop being shown it.
 */
app.delete('/events/:id', async (c) => {
  const db = c.get('db');
  const eventId = Number(c.req.param('id'));

  const rows = await db.select({ id: sleepAudioEvents.id })
    .from(sleepAudioEvents)
    .innerJoin(sleepSessions, eq(sleepAudioEvents.sleepSessionId, sleepSessions.id))
    .where(and(
      eq(sleepAudioEvents.id, eventId),
      eq(sleepSessions.userId, c.get('user').id),
    ))
    .limit(1);
  if (!rows[0]) throw notFound('Sleep event');

  await db.update(sleepAudioEvents)
    .set({ deletedAt: Date.now() })
    .where(eq(sleepAudioEvents.id, eventId));
  return c.body(null, 204);
});

/** Sleep-talk clips only; the clip itself is kept forever either way. */
app.post('/events/:id/transcribe', async (c) => {
  const db = c.get('db');
  const eventId = Number(c.req.param('id'));

  const rows = await db.select({
    event: sleepAudioEvents,
    session: sleepSessions,
    asset: mediaAssets,
  }).from(sleepAudioEvents)
    .innerJoin(sleepSessions, eq(sleepAudioEvents.sleepSessionId, sleepSessions.id))
    .leftJoin(mediaAssets, eq(sleepAudioEvents.audioAssetId, mediaAssets.id))
    .where(and(eq(sleepAudioEvents.id, eventId), eq(sleepSessions.userId, c.get('user').id)))
    .limit(1);

  const row = rows[0];
  if (!row) throw notFound('Sleep event');
  if (!row.asset) throw new ApiError('VALIDATION_ERROR', 'Event has no audio clip');

  const object = await c.env.MEDIA.get(row.asset.r2Key);
  if (!object) throw notFound('Audio object');

  // Sleep talk is the user's own voice in their own language, so it listens
  // for the language they set rather than guessing per clip.
  const { text } = await transcribeAudio(
    c.env,
    new Uint8Array(await object.arrayBuffer()),
    {
      locale: await accountLocale(db, c.get('user')),
      mimeType: row.asset.mimeType,
    },
  );

  const transcript = text;
  await db.update(sleepAudioEvents).set({ transcript })
    .where(eq(sleepAudioEvents.id, eventId));

  return c.json({ eventId, transcript });
});

// ------------------------------------------------------------ reminders

const reminderSchema = z.object({
  reminderType: z.enum(['bedtime', 'wakeup', 'wind_down']),
  remindAtLocal: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/, 'Expected HH:MM'),
  daysOfWeek: z.string().min(3),
  isEnabled: z.boolean().default(true),
});

app.get('/reminders', async (c) => {
  const rows = await c.get('db').select().from(sleepReminders)
    .where(eq(sleepReminders.userId, c.get('user').id));
  return c.json({ items: rows });
});

app.post('/reminders', async (c) => {
  const body = await parseBody(c, reminderSchema);
  const id = newId();
  const now = Date.now();

  await c.get('db').insert(sleepReminders).values({
    id,
    userId: c.get('user').id,
    reminderType: body.reminderType,
    remindAtLocal: body.remindAtLocal,
    daysOfWeek: body.daysOfWeek,
    isEnabled: body.isEnabled,
    createdAt: now,
    updatedAt: now,
  });

  const rows = await c.get('db').select().from(sleepReminders)
    .where(eq(sleepReminders.id, id)).limit(1);
  return c.json(rows[0], 201);
});

app.patch('/reminders/:id', async (c) => {
  const body = await parseBody(c, reminderSchema.partial());
  const db = c.get('db');

  await db.update(sleepReminders)
    .set({ ...body, updatedAt: Date.now() })
    .where(and(
      eq(sleepReminders.id, c.req.param('id')),
      eq(sleepReminders.userId, c.get('user').id),
    ));

  const rows = await db.select().from(sleepReminders)
    .where(eq(sleepReminders.id, c.req.param('id'))).limit(1);
  if (!rows[0]) throw notFound('Reminder');
  return c.json(rows[0]);
});

app.delete('/reminders/:id', async (c) => {
  await c.get('db').delete(sleepReminders).where(and(
    eq(sleepReminders.id, c.req.param('id')),
    eq(sleepReminders.userId, c.get('user').id),
  ));
  return c.body(null, 204);
});

export default app;
