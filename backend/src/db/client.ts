import { drizzle } from 'drizzle-orm/d1';
import * as schema from './schema';

export function createDb(d1: D1Database) {
  return drizzle(d1, { schema });
}

export type Db = ReturnType<typeof createDb>;

/**
 * D1 rejects a statement with more than 100 bound parameters, so a bulk insert
 * of anything wider than a couple of columns has to be split. This is invisible
 * until a real payload arrives — a 14-split run or a 60-segment hypnogram — so
 * every multi-row insert goes through here rather than calling .values(rows).
 */
export const D1_MAX_BOUND_PARAMS = 100;

export async function insertMany<T extends Record<string, unknown>>(
  insert: (rows: T[]) => Promise<unknown>,
  rows: readonly T[],
): Promise<void> {
  if (rows.length === 0) return;

  const columns = Math.max(1, Object.keys(rows[0] as object).length);
  const perChunk = Math.max(1, Math.floor(D1_MAX_BOUND_PARAMS / columns));

  for (let i = 0; i < rows.length; i += perChunk) {
    await insert(rows.slice(i, i + perChunk) as T[]);
  }
}
