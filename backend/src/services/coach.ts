import { and, desc, eq, gte, inArray } from 'drizzle-orm';
import {
  userProfiles, goals, chronicConditions, bodyMetricsLogs, workoutSessions,
  activityTypes, dailyNutritionSummaries, coachInsights,
} from '../db/schema';
import { modelConfig } from '../config/models';
import { sleepDebtFor } from './sleepDebt';
import { localDate, ageFromDob } from '../lib/time';
import { newId } from '../lib/ids';
import { insertMany } from '../db/client';
import type { Db } from '../db/client';
import type { Bindings } from '../env';
import { aiText } from '../lib/aiText';

export interface CoachContext {
  profile: {
    age: number | null;
    sex: string | null;
    weightKg: number | null;
    heightCm: number | null;
    activityLevel: string;
  };
  goals: Array<{ type: string; target: number | null; unit: string | null; deadline: string | null }>;
  conditions: string[];
  today: { date: string; consumedKcal: number; tdeeKcal: number | null; balanceKcal: number | null };
  training7d: { sessions: number; totalMinutes: number; totalKcal: number; types: string[] };
  sleep: { targetHours: number; debtHours: number };
}

/**
 * Compact snapshot prepended to every coach turn and stored on the assistant
 * message, so an old answer can still be explained by the data it was given.
 */
export async function buildCoachContext(
  db: Db, env: Bindings, userId: string, timezone: string,
): Promise<CoachContext> {
  const today = localDate(Date.now(), timezone);
  const weekAgoMs = Date.now() - 7 * 86_400_000;

  const [profileRows, goalRows, conditionRows, metricRows, summaryRows, sessionRows, debt] =
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
    ]);

  const profile = profileRows[0];
  const metric = metricRows[0];
  const summary = summaryRows[0];

  const typeIds = [...new Set(sessionRows.map((s) => s.activityTypeId))];
  const typeRows = typeIds.length
    ? await db.select({ id: activityTypes.id, code: activityTypes.code })
        .from(activityTypes).where(inArray(activityTypes.id, typeIds))
    : [];

  return {
    profile: {
      age: profile?.dateOfBirth ? ageFromDob(profile.dateOfBirth) : null,
      sex: profile?.biologicalSex ?? null,
      weightKg: metric?.weightKg ?? null,
      heightCm: metric?.heightCm ?? null,
      activityLevel: profile?.activityLevel ?? 'moderate',
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

export const COACH_SYSTEM_PROMPT = `Bạn là huấn luyện viên sức khỏe cá nhân của người dùng.
Trả lời ngắn gọn, cụ thể, dựa trên số liệu được cung cấp. Luôn dùng đơn vị mét (kg, cm, km).
Nếu người dùng có bệnh nền, mọi lời khuyên về ăn uống và tập luyện phải tính đến bệnh đó.
Không chẩn đoán bệnh, không kê thuốc; khi vấn đề vượt quá phạm vi, khuyên đi khám bác sĩ.`;

export function contextBlock(ctx: CoachContext): string {
  return `[DỮ LIỆU NGƯỜI DÙNG]\n${JSON.stringify(ctx)}`;
}

export interface ChatTurn { role: 'user' | 'assistant' | 'system'; content: string }

/** Streams a coach reply. The caller persists the assistant row when the stream ends. */
export async function streamCoachReply(
  env: Bindings, ctx: CoachContext, history: ChatTurn[],
): Promise<ReadableStream> {
  const { chat, chatMaxTokens, chatTemperature } = modelConfig(env);
  const messages: ChatTurn[] = [
    { role: 'system', content: COACH_SYSTEM_PROMPT },
    { role: 'system', content: contextBlock(ctx) },
    ...history,
  ];
  return (await env.AI.run(chat as never, {
    messages, max_tokens: chatMaxTokens, temperature: chatTemperature, stream: true,
  } as never)) as unknown as ReadableStream;
}

export async function completeCoachReply(
  env: Bindings, ctx: CoachContext, history: ChatTurn[],
): Promise<string> {
  const { chat, chatMaxTokens, chatTemperature } = modelConfig(env);
  const res = await env.AI.run(chat as never, {
    messages: [
      { role: 'system', content: COACH_SYSTEM_PROMPT },
      { role: 'system', content: contextBlock(ctx) },
      ...history,
    ],
    max_tokens: chatMaxTokens,
    temperature: chatTemperature,
  } as never);
  return aiText(res);
}

const INSIGHT_PROMPT = `Dựa trên dữ liệu, viết tối đa 3 nhận xét ngắn cho hôm nay.
Trả về DUY NHẤT JSON: [{"domain":"nutrition|training|sleep|body|overall","title":"...","body":"...","severity":"info|warning|alert"}]`;

/**
 * Nightly proactive coaching. Deterministic rules fire first — sleep debt and a
 * large calorie gap must be reported even if the model says nothing useful.
 */
export async function generateDailyInsights(
  db: Db, env: Bindings, userId: string, timezone: string,
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
    const text = await completeCoachReply(env, ctx, [{ role: 'user', content: INSIGHT_PROMPT }]);
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
