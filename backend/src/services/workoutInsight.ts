import { and, eq } from 'drizzle-orm';
import type { Db } from '../db/client';
import { INSIGHT_KINDS, workoutInsights } from '../db/schema';
import { modelConfig } from '../config/models';
import { aiText, withTimeout } from '../lib/aiText';
import { languageName, type SupportedLocale } from '../lib/language';
import { PROMPTS, promptSections, renderPrompt } from '../prompts';
import type { Bindings } from '../env';

export type InsightKind = typeof INSIGHT_KINDS[number];

export const isInsightKind = (v: string): v is InsightKind =>
  (INSIGHT_KINDS as readonly string[]).includes(v);

/** Hard ceiling on the generated line, in characters, before it is thrown away. */
const MAX_INSIGHT_CHARS = 220;

/*
 * The model is shown pace as "7:47/km" rather than as 467 seconds per
 * kilometre. Reading it out of the raw number is work it does out loud, and it
 * thinks in the same token budget it answers in — handed ten raw splits it
 * spent the whole budget converting them and returned an empty message.
 */

/** Seconds per kilometre as "m:ss/km". */
export function paceText(secPerKm: number | null | undefined): string | null {
  if (secPerKm == null || !Number.isFinite(secPerKm) || secPerKm <= 0) return null;
  const s = Math.round(secPerKm);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}/km`;
}

/** Seconds as "h:mm:ss", or "m:ss" under an hour. */
export function durationText(seconds: number | null | undefined): string | null {
  if (seconds == null || !Number.isFinite(seconds) || seconds < 0) return null;
  const s = Math.round(seconds);
  const mm = String(Math.floor((s % 3600) / 60));
  const ss = String(s % 60).padStart(2, '0');
  return s >= 3600 ? `${Math.floor(s / 3600)}:${mm.padStart(2, '0')}:${ss}` : `${mm}:${ss}`;
}

/** Metres as "10.59 km", or "400 m" under a kilometre. */
export function distanceText(metres: number | null | undefined): string | null {
  if (metres == null || !Number.isFinite(metres) || metres < 0) return null;
  return metres < 1000 ? `${Math.round(metres)} m` : `${(metres / 1000).toFixed(2)} km`;
}

/**
 * A digest of exactly the numbers the model was shown. A crop or a re-upload
 * changes them and the cached line is regenerated; opening the screen again
 * does not.
 */
async function hashInput(payload: string): Promise<string> {
  const bytes = new TextEncoder().encode(payload);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest)].slice(0, 16)
    .map((b) => b.toString(16).padStart(2, '0')).join('');
}

/**
 * The model answers in prose however hard the prompt pushes, so the line is
 * cleaned up here: surrounding quotes dropped, newlines collapsed, markdown
 * emphasis stripped. An empty or over-long result is treated as a failure.
 */
export function tidyInsight(raw: string): string | null {
  const text = raw
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/[*_#`]/g, '')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/^["'«»“”]+|["'«»“”]+$/g, '')
    .trim();
  if (text.length === 0 || text.length > MAX_INSIGHT_CHARS) return null;
  return text;
}

/**
 * One coach's line about a run, generated once and cached per (run, kind,
 * language).
 *
 * Returns null rather than throwing when the model is slow, unreachable or
 * answers with something unusable: the card is decoration on a screen full of
 * real numbers, and the app hides it instead of showing an error where a
 * sentence should be.
 */
export async function workoutInsight(
  db: Db,
  env: Bindings,
  sessionId: string,
  kind: InsightKind,
  locale: SupportedLocale,
  data: unknown,
): Promise<{ body: string; cached: boolean } | null> {
  const payload = JSON.stringify(data);
  const inputHash = await hashInput(`${kind}:${locale}:${payload}`);

  const rows = await db.select().from(workoutInsights).where(and(
    eq(workoutInsights.workoutSessionId, sessionId),
    eq(workoutInsights.kind, kind),
    eq(workoutInsights.language, locale),
  )).limit(1);
  const held = rows[0];
  if (held && held.inputHash === inputHash) return { body: held.body, cached: true };

  const focus = promptSections(PROMPTS.workoutInsightFocus).get(kind);
  if (focus === undefined) throw new Error(`prompts/workout/insight_focus.md has no section ${kind}`);

  const { chat, chatTemperature, workoutInsightTimeoutMs, workoutInsightMaxTokens } =
    modelConfig(env);

  let body: string | null = null;
  try {
    const res = await withTimeout(
      env.AI.run(chat, {
        messages: [
          {
            role: 'system',
            content: renderPrompt(PROMPTS.workoutInsightSystem, { language: languageName(locale) }),
          },
          {
            role: 'user',
            content: renderPrompt(PROMPTS.workoutInsightUser, { focus, data: payload }),
          },
        ],
        max_tokens: workoutInsightMaxTokens,
        temperature: chatTemperature,
      } as never),
      workoutInsightTimeoutMs,
      'workout insight',
    );
    const answer = aiText(res);
    body = tidyInsight(answer);
    if (body === null) console.warn('workout insight unusable:', JSON.stringify(answer).slice(0, 400));
  } catch (err) {
    console.warn('workout insight failed:', err instanceof Error ? err.message : err);
    body = null;
  }
  if (body === null) return null;

  await db.insert(workoutInsights).values({
    workoutSessionId: sessionId,
    kind,
    language: locale,
    body,
    inputHash,
    createdAt: Date.now(),
  }).onConflictDoUpdate({
    target: [workoutInsights.workoutSessionId, workoutInsights.kind, workoutInsights.language],
    set: { body, inputHash, createdAt: Date.now() },
  });

  return { body, cached: false };
}
