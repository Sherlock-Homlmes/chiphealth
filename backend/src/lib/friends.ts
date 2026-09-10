import { and, eq, or } from 'drizzle-orm';
import { friendships } from '../db/schema';
import type { AppEnv } from '../env';

/**
 * A friendship row is directional (requester -> addressee) but the relationship is
 * not, so every friend query must look at BOTH columns. Getting this wrong is the
 * classic bug here: half the friends silently disappear.
 */
export async function friendIds(
  db: AppEnv['Variables']['db'], userId: string,
): Promise<string[]> {
  const rows = await db.select({
    requesterId: friendships.requesterId,
    addresseeId: friendships.addresseeId,
  }).from(friendships).where(and(
    eq(friendships.status, 'accepted'),
    or(eq(friendships.requesterId, userId), eq(friendships.addresseeId, userId)),
  ));

  return rows.map((r) => (r.requesterId === userId ? r.addresseeId : r.requesterId));
}
