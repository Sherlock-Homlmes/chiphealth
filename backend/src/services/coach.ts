import { and, desc, eq, gte, inArray, sql } from 'drizzle-orm';
import {
  userProfiles, goals, chronicConditions, bodyMetricsLogs, workoutSessions,
  activityTypes, dailyNutritionSummaries, coachInsights,
  mealLogs, mealItems, mealAiAnalyses,
} from '../db/schema';
import { modelConfig } from '../config/models';
import { sleepDebtFor } from './sleepDebt';
import { effectiveAnalysis } from './mealAnalysis';
import { languageName } from '../lib/language';
import { localDate, localTime, ageFromDob } from '../lib/time';
import { newId } from '../lib/ids';
import { insertMany } from '../db/client';
import type { Db } from '../db/client';
import type { Bindings } from '../env';
import { aiText } from '../lib/aiText';
import { PROMPTS, renderPrompt } from '../prompts';

/** One meal of the day as the snapshot shows it: enough to answer "trưa nay ăn gì" without a tool call. */
export interface CoachContextMeal {
  type: string;
  /** Local wall-clock HH:mm. */
  at: string;
  dish: string | null;
  kcal: number | null;
  /** Fluid the meal itself carried, in ml — the broth, the drink, the rice. */
  waterMl: number | null;
  items: number;
  analysis: string | null;
}

export interface CoachContext {
  profile: {
    age: number | null;
    sex: string | null;
    weightKg: number | null;
    heightCm: number | null;
    activityLevel: string;
    /**
     * What the athlete set as their training focus on the progress tab, with
     * its meaning spelled out — the code alone ("event_training") tells a
     * model nothing, and this is the one line that says whether an answer
     * should push harder or hold back.
     */
    trainingFocus: { code: string; meaning: string };
  };
  goals: Array<{ type: string; target: number | null; unit: string | null; deadline: string | null }>;
  conditions: string[];
  today: {
    date: string;
    consumedKcal: number;
    tdeeKcal: number | null;
    balanceKcal: number | null;
    /**
     * The day's meals. Before this list existed the snapshot carried only the
     * calorie totals, and a model that was asked "trưa nay ăn vậy đủ chưa"
     * answered "bạn chưa liệt kê bữa nào" — flatly contradicting the
     * consumedKcal next to it — instead of calling get_day_summary.
     */
    meals: CoachContextMeal[];
    /**
     * Fluid from food, in ml, summed over the day's meals. Hand-logged water
     * lives on the phone and arrives separately (device_json); without this
     * half the assistant was answering "bạn mới uống 500 ml" to someone who
     * had just had two bowls of phở.
     */
    waterFromMealsMl: number;
  };
  training7d: { sessions: number; totalMinutes: number; totalKcal: number; types: string[] };
  sleep: { targetHours: number; debtHours: number };
}

/** Plain-language gloss for each focus code, in the app's source language. */
const FOCUS_MEANINGS: Record<string, string> = {
  improve_fitness: 'Nâng cao thể lực — cải thiện tốc độ, sức bền hoặc sức mạnh tổng thể',
  event_training: 'Tập luyện cho một sự kiện — chuẩn bị cho giải đua hoặc sự kiện sắp diễn ra',
  stay_active: 'Duy trì vận động — giữ thói quen tập luyện đều đặn hằng tuần',
  recovery: 'Hồi phục — tập nhẹ, quay lại dần sau thời gian nghỉ',
};

/**
 * Compact snapshot prepended to every coach turn and stored on the assistant
 * message, so an old answer can still be explained by the data it was given.
 */
export async function buildCoachContext(
  db: Db, env: Bindings, userId: string, timezone: string,
): Promise<CoachContext> {
  const today = localDate(Date.now(), timezone);
  const weekAgoMs = Date.now() - 7 * 86_400_000;

  const [profileRows, goalRows, conditionRows, metricRows, summaryRows, sessionRows, debt, mealRows] =
    await Promise.all([
      db.select().from(userProfiles).where(eq(userProfiles.userId, userId)).limit(1),
      db.select().from(goals)
        .where(and(eq(goals.userId, userId), eq(goals.status, 'active')))
        .orderBy(desc(goals.priority)),
      db.select().from(chronicConditions)
        .where(and(eq(chronicConditions.userId, userId), eq(chronicConditions.isActive, true))),
      db.select().from(bodyMetricsLogs).where(eq(bodyMetricsLogs.userId, userId))
        .orderBy(desc(bodyMetricsLogs.recordedAt)).limit(1),
      db.select().from(dailyNutritionSummaries).where(and(
        eq(dailyNutritionSummaries.userId, userId),
        eq(dailyNutritionSummaries.localDate, today),
      )).limit(1),
      db.select({
        durationSeconds: workoutSessions.durationSeconds,
        caloriesBurnedKcal: workoutSessions.caloriesBurnedKcal,
        activityTypeId: workoutSessions.activityTypeId,
      }).from(workoutSessions).where(and(
        eq(workoutSessions.userId, userId),
        eq(workoutSessions.isDeleted, false),
        gte(workoutSessions.startedAt, weekAgoMs),
      )),
      sleepDebtFor(db, env, userId, today),
      db.select().from(mealLogs).where(and(
        eq(mealLogs.userId, userId),
        eq(mealLogs.localDate, today),
      )).orderBy(mealLogs.loggedAt),
    ]);

  const profile = profileRows[0];
  const metric = metricRows[0];
  const summary = summaryRows[0];

  const typeIds = [...new Set(sessionRows.map((s) => s.activityTypeId))];
  const typeRows = typeIds.length
    ? await db.select({ id: activityTypes.id, code: activityTypes.code })
        .from(activityTypes).where(inArray(activityTypes.id, typeIds))
    : [];

  // Item counts and the effective analysis status per meal (a hung run reads
  // as failed after the 5-minute clock), same folding as the meals endpoint.
  const dayMeals = mealRows.slice(0, 20);
  const mealIds = dayMeals.map((m) => m.id);
  const [itemCounts, mealAnalyses] = mealIds.length
    ? await Promise.all([
        db.select({ mealLogId: mealItems.mealLogId, n: sql<number>`count(*)` })
          .from(mealItems).where(inArray(mealItems.mealLogId, mealIds))
          .groupBy(mealItems.mealLogId),
        db.select({
          mealLogId: mealAiAnalyses.mealLogId,
          status: mealAiAnalyses.status,
          createdAt: mealAiAnalyses.createdAt,
        }).from(mealAiAnalyses).where(inArray(mealAiAnalyses.mealLogId, mealIds))
          .orderBy(desc(mealAiAnalyses.id)),
      ])
    : [[] as { mealLogId: string; n: number }[], [] as { mealLogId: string; status: string; createdAt: number }[]];
  const itemsByMeal = new Map(itemCounts.map((r) => [r.mealLogId, Number(r.n)]));
  const analysisByMeal = new Map<string, string>();
  for (const a of mealAnalyses) {
    if (analysisByMeal.has(a.mealLogId)) continue;
    analysisByMeal.set(a.mealLogId, effectiveAnalysis({ status: a.status, createdAt: a.createdAt, errorMessage: null }).status);
  }

  return {
    profile: {
      age: profile?.dateOfBirth ? ageFromDob(profile.dateOfBirth) : null,
      sex: profile?.biologicalSex ?? null,
      weightKg: metric?.weightKg ?? null,
      heightCm: metric?.heightCm ?? null,
      activityLevel: profile?.activityLevel ?? 'moderate',
      trainingFocus: {
        code: profile?.trainingFocus ?? 'stay_active',
        meaning: FOCUS_MEANINGS[profile?.trainingFocus ?? 'stay_active']
          ?? FOCUS_MEANINGS.stay_active!,
      },
    },
    goals: goalRows.map((g) => ({
      type: g.goalType, target: g.targetValue, unit: g.targetUnit, deadline: g.deadline,
    })),
    conditions: conditionRows.map((c) => c.description),
    today: {
      date: today,
      consumedKcal: summary?.caloriesConsumedKcal ?? 0,
      tdeeKcal: summary?.tdeeKcal ?? null,
      balanceKcal: summary?.calorieBalanceKcal ?? null,
      meals: dayMeals.map((m) => ({
        type: m.mealType,
        at: localTime(m.loggedAt, timezone),
        dish: m.dishName,
        kcal: m.totalCaloriesKcal == null ? null : Math.round(m.totalCaloriesKcal),
        waterMl: m.totalWaterMl == null ? null : Math.round(m.totalWaterMl),
        items: itemsByMeal.get(m.id) ?? 0,
        analysis: analysisByMeal.get(m.id) ?? null,
      })),
      // Meals with nothing to say about fluid carry null, which adds nothing.
      waterFromMealsMl: Math.round(
        dayMeals.reduce((sum, m) => sum + (m.totalWaterMl ?? 0), 0),
      ),
    },
    training7d: {
      sessions: sessionRows.length,
      totalMinutes: Math.round(
        sessionRows.reduce((s, r) => s + (r.durationSeconds ?? 0), 0) / 60,
      ),
      totalKcal: Math.round(sessionRows.reduce((s, r) => s + (r.caloriesBurnedKcal ?? 0), 0)),
      types: typeRows.map((t) => t.code),
    },
    sleep: {
      targetHours: Math.round((debt.targetSeconds / 3600) * 10) / 10,
      debtHours: Math.round((debt.rollingDebtSeconds / 3600) * 10) / 10,
    },
  };
}

export function contextBlock(ctx: CoachContext): string {
  return renderPrompt(PROMPTS.coachContext, { context_json: JSON.stringify(ctx) });
}

export interface ChatTurn { role: 'user' | 'assistant' | 'system'; content: string }

/**
 * [locale] is the language the user picked in Settings; everything the coach
 * writes is read by them, so it is written in it. Defaults to Vietnamese for
 * the callers that have no user row in hand.
 */
export async function completeCoachReply(
  env: Bindings, ctx: CoachContext, history: ChatTurn[], locale?: string,
): Promise<string> {
  const { chat, chatMaxTokens, chatTemperature } = modelConfig(env);
  const res = await env.AI.run(chat as never, {
    messages: [
      {
        role: 'system',
        content: renderPrompt(PROMPTS.coachSystem, {
          language: languageName(locale),
        }),
      },
      { role: 'system', content: contextBlock(ctx) },
      ...history,
    ],
    max_tokens: chatMaxTokens,
    temperature: chatTemperature,
  } as never);
  return aiText(res);
}

/**
 * Nightly proactive coaching. Deterministic rules fire first — sleep debt and a
 * large calorie gap must be reported even if the model says nothing useful.
 */
export async function generateDailyInsights(
  db: Db, env: Bindings, userId: string, timezone: string, locale?: string,
): Promise<number> {
  const ctx = await buildCoachContext(db, env, userId, timezone);
  const today = localDate(Date.now(), timezone);
  const rows: Array<typeof coachInsights.$inferInsert> = [];
  const now = Date.now();

  if (ctx.sleep.debtHours >= 10) {
    rows.push({
      id: newId(), userId, domain: 'sleep', localDate: today, period: 'daily',
      title: `Nợ ngủ ${ctx.sleep.debtHours}h trong 14 ngày`,
      body: `Mục tiêu ${ctx.sleep.targetHours}h/đêm. Ngủ sớm hơn 30-60 phút vài đêm tới để kéo nợ xuống.`,
      severity: ctx.sleep.debtHours >= 20 ? 'alert' : 'warning',
      createdAt: now,
    });
  }

  if (ctx.today.balanceKcal !== null && Math.abs(ctx.today.balanceKcal) >= 700) {
    const over = ctx.today.balanceKcal > 0;
    rows.push({
      id: newId(), userId, domain: 'nutrition', localDate: today, period: 'daily',
      title: over ? 'Vượt TDEE nhiều' : 'Thâm hụt calo sâu',
      body: `Hôm nay ${Math.round(ctx.today.consumedKcal)} kcal so với TDEE ${Math.round(ctx.today.tdeeKcal ?? 0)} kcal.`,
      severity: 'warning',
      createdAt: now,
    });
  }

  try {
    const text = await completeCoachReply(
      env, ctx, [{ role: 'user', content: renderPrompt(PROMPTS.coachInsights) }], locale,
    );
    const start = text.indexOf('[');
    const end = text.lastIndexOf(']');
    if (start !== -1 && end > start) {
      const parsed = JSON.parse(text.slice(start, end + 1)) as Array<Record<string, string>>;
      for (const item of parsed.slice(0, 3)) {
        if (!item.title || !item.body) continue;
        rows.push({
          id: newId(), userId,
          domain: (item.domain as 'overall') ?? 'overall',
          localDate: today, period: 'daily',
          title: item.title, body: item.body,
          severity: (item.severity as 'info') ?? 'info',
          model: modelConfig(env).chat,
          createdAt: now,
        });
      }
    }
  } catch {
    // Model insights are a bonus; the rule-based ones above still get written.
  }

  await insertMany((chunk) => db.insert(coachInsights).values(chunk), rows);
  return rows.length;
}
