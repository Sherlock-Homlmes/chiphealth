import { Hono } from 'hono';
import { and, eq, gte, sql } from 'drizzle-orm';
import {
  users, foods, barcodeScanMisses, foodKbDocuments, mealAiAnalyses,
} from '../../db/schema';
import { localDate } from '../../lib/time';
import type { AppEnv } from '../../env';

const app = new Hono<AppEnv>();

app.get('/', async (c) => {
  const db = c.get('db');
  const today = localDate(Date.now(), c.get('user').timezone);
  const dayStart = Date.parse(`${today}T00:00:00Z`);

  const count = sql<number>`count(*)`;

  const [
    userRows, foodRows, verifiedRows, pendingBarcodeRows, kbRows,
    kbPendingRows, analysesToday, failedToday,
  ] = await Promise.all([
    db.select({ n: count }).from(users),
    db.select({ n: count }).from(foods),
    db.select({ n: count }).from(foods).where(eq(foods.isVerified, true)),
    db.select({ n: count }).from(barcodeScanMisses)
      .where(eq(barcodeScanMisses.status, 'pending')),
    db.select({ n: count }).from(foodKbDocuments),
    db.select({ n: count }).from(foodKbDocuments)
      .where(sql`${foodKbDocuments.embeddingStatus} is null or ${foodKbDocuments.embeddingStatus} != 'indexed'`),
    db.select({ n: count }).from(mealAiAnalyses).where(gte(mealAiAnalyses.createdAt, dayStart)),
    db.select({ n: count }).from(mealAiAnalyses).where(and(
      gte(mealAiAnalyses.createdAt, dayStart),
      eq(mealAiAnalyses.status, 'failed'),
    )),
  ]);

  const analysed = analysesToday[0]?.n ?? 0;
  const failed = failedToday[0]?.n ?? 0;

  return c.json({
    users: userRows[0]?.n ?? 0,
    foods: foodRows[0]?.n ?? 0,
    foodsVerified: verifiedRows[0]?.n ?? 0,
    pendingBarcodeMisses: pendingBarcodeRows[0]?.n ?? 0,
    kbDocuments: kbRows[0]?.n ?? 0,
    kbDocumentsPending: kbPendingRows[0]?.n ?? 0,
    mealsAnalysedToday: analysed,
    // 0..1 fraction; the UI renders the percentage.
    aiFailureRate: analysed > 0 ? Math.round((failed / analysed) * 1000) / 1000 : 0,
  });
});

export default app;
