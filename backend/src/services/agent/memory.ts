import { and, asc, desc, eq, isNull, lt, or, gt, sql } from 'drizzle-orm';
import { userFacts } from '../../db/schema';
import { newId } from '../../lib/ids';
import type { Db } from '../../db/client';

export type FactCategory =
  'health' | 'nutrition' | 'training' | 'sleep' | 'preference' | 'other';

export interface UserFact {
  id: string;
  category: FactCategory;
  fact: string;
  /** Epoch ms, or null when the fact never expires. */
  expiresAt: number | null;
  createdAt: number;
  updatedAt: number;
}

/** How many facts ride along in the system prompt when no one asked for more. */
export const DEFAULT_FACT_LIMIT = 15;

/** Nothing longer than this is one fact; the model is told to keep it short. */
export const MAX_FACT_LENGTH = 300;

/** A fact may be parked at most this far out — past it, say "forever" instead. */
export const MAX_TTL_DAYS = 365 * 2;

/**
 * The uniqueness key for a fact: the same sentence said twice, in different
 * case or with different spacing or a trailing full stop, is one fact.
 *
 * Deliberately *not* diacritic-stripped: "bị đau" and "bi dau" are different
 * sentences in Vietnamese, and folding them would merge facts that are not the
 * same. Normalisation is Unicode NFC so that two spellings of the same
 * composed character do not become two rows.
 */
export function factKey(fact: string): string {
  return fact
    .normalize('NFC')
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .replace(/[.!?;,]+$/u, '')
    .trim();
}

/**
 * The half of the expiry contract that matters: a row counts as live when it
 * has no expiry at all, or its expiry is still ahead of us.
 *
 * Every read goes through this. The nightly purge is an optimisation, never
 * the thing that makes an expired fact stop being returned — a cron that did
 * not run must not put "nghỉ chạy 3 tuần" from last spring back in front of
 * the model.
 */
export function liveFactFilter(now: number) {
  return or(isNull(userFacts.expiresAt), gt(userFacts.expiresAt, now));
}

/** Turns a TTL in days into an absolute expiry, or null for "forever". */
export function expiryFromDays(
  days: number | null | undefined, now = Date.now(),
): number | null {
  if (days === null || days === undefined) return null;
  if (!Number.isFinite(days) || days <= 0) {
    throw new RangeError('expires_in_days must be a positive number of days');
  }
  return now + Math.min(days, MAX_TTL_DAYS) * 86_400_000;
}

function toFact(row: typeof userFacts.$inferSelect): UserFact {
  return {
    id: row.id,
    category: row.category,
    fact: row.fact,
    expiresAt: row.expiresAt,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  };
}

/**
 * The live facts for one user, permanent ones first.
 *
 * The ordering is the whole point of the cap: a chronic condition outranks
 * yesterday's passing note, so when only [limit] of them fit in the prompt it
 * is the temporary ones that fall off the end, not the allergy.
 */
export async function listFacts(
  db: Db,
  userId: string,
  opts: { limit?: number; category?: FactCategory; query?: string; now?: number } = {},
): Promise<UserFact[]> {
  const now = opts.now ?? Date.now();
  const limit = Math.max(1, Math.min(opts.limit ?? DEFAULT_FACT_LIMIT, 100));

  const where = [eq(userFacts.userId, userId), liveFactFilter(now)];
  if (opts.category) where.push(eq(userFacts.category, opts.category));

  const needle = opts.query?.trim().toLowerCase();
  if (needle) {
    // LIKE on the normalised key, so a search matches the same way the
    // uniqueness does. `escape` because a query may legitimately contain % or _.
    const escaped = needle.replace(/[\\%_]/g, (c) => `\\${c}`);
    where.push(sql`${userFacts.factKey} LIKE ${`%${escaped}%`} ESCAPE '\\'`);
  }

  const rows = await db.select().from(userFacts)
    .where(and(...where))
    // Permanent first (expires_at NULL sorts first in SQLite's ASC), then the
    // most recently learned.
    .orderBy(asc(userFacts.expiresAt), desc(userFacts.updatedAt))
    .limit(limit);

  return rows.map(toFact);
}

/**
 * Writes a fact, or updates the one that says the same thing.
 *
 * Re-remembering is how a fact is corrected: the same sentence with a new
 * expiry moves the deadline, and passing no expiry makes a temporary fact
 * permanent. Both are things the user can actually say out loud ("gối đỡ rồi,
 * nhưng vẫn phải cẩn thận"), so neither is an error.
 */
export async function rememberFact(
  db: Db,
  userId: string,
  input: {
    fact: string;
    category?: FactCategory;
    expiresAt?: number | null;
    conversationId?: string | null;
  },
): Promise<UserFact> {
  const fact = input.fact.trim().replace(/\s+/g, ' ');
  if (!fact) throw new RangeError('fact must not be empty');
  if (fact.length > MAX_FACT_LENGTH) {
    throw new RangeError(`fact must be at most ${MAX_FACT_LENGTH} characters`);
  }

  const now = Date.now();
  const values = {
    id: newId(),
    userId,
    category: input.category ?? 'other' as FactCategory,
    fact,
    factKey: factKey(fact),
    expiresAt: input.expiresAt ?? null,
    source: 'assistant',
    conversationId: input.conversationId ?? null,
    createdAt: now,
    updatedAt: now,
  };

  await db.insert(userFacts).values(values).onConflictDoUpdate({
    target: [userFacts.userId, userFacts.factKey],
    set: {
      category: values.category,
      fact: values.fact,
      expiresAt: values.expiresAt,
      conversationId: values.conversationId,
      updatedAt: now,
    },
  });

  const rows = await db.select().from(userFacts)
    .where(and(eq(userFacts.userId, userId), eq(userFacts.factKey, values.factKey)))
    .limit(1);
  return toFact(rows[0]!);
}

/** Returns false when the id is not this user's, so a caller can say "not found". */
export async function forgetFact(
  db: Db, userId: string, id: string,
): Promise<boolean> {
  const gone = await db.delete(userFacts)
    .where(and(eq(userFacts.id, id), eq(userFacts.userId, userId)))
    .returning({ id: userFacts.id });
  return gone.length > 0;
}

/**
 * Housekeeping only. Reads already ignore expired rows; this reclaims the
 * space, and keeps a user's memory from growing without bound over years of
 * three-week injuries.
 */
export async function purgeExpiredFacts(db: Db, now = Date.now()): Promise<number> {
  const gone = await db.delete(userFacts)
    .where(lt(userFacts.expiresAt, now))
    .returning({ id: userFacts.id });
  return gone.length;
}
