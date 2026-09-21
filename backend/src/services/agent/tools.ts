import { z } from 'zod';
import { callApi, type ApiCaller } from '../../lib/internalApi';
import { addDays, localDate, localDateTimeToEpoch, localTime } from '../../lib/time';
import { PROMPTS, promptSections } from '../../prompts';
import type { AuthUser } from '../../env';

/**
 * The assistant's tools. Two kinds:
 *
 *  - read  — run straight away inside the agent loop; the result goes back to
 *            the model as JSON.
 *  - write — never run by the agent. `propose` validates the arguments against
 *            the live data and writes the confirm-card text; `execute` only runs
 *            when the user taps "Xác nhận" (routes/coach.ts).
 *
 * Every tool reaches data through the public API with the user's own token
 * (lib/internalApi.ts), so the agent can do exactly what the app can and no more.
 * Descriptions come from prompts/agent/tools.md; argument schemas live here.
 */

export interface ToolContext {
  caller: ApiCaller;
  user: AuthUser;
  /** The conversation this turn belongs to, recorded on anything it remembers. */
  conversationId?: string;
  /** Per-turn memo for lookups several tools share (the sport catalogue). */
  memo: Map<string, Promise<unknown>>;
}

/** A failure the model can act on: the message goes back as the tool result. */
export class ToolError extends Error {}

export interface Proposal {
  summary: string;
  details?: string[];
}

/** Applied by the app, not the server — water lives on the device. */
export type ClientEffect = { type: 'water_add'; date: string; ml: number };

export interface Execution {
  result?: unknown;
  clientEffect?: ClientEffect;
  /** Lets the app open what was just written. */
  link?: { type: 'meal' | 'workout' | 'sleep'; id: string };
}

interface ToolBase<S extends z.ZodTypeAny> {
  name: string;
  args: S;
}
export interface ReadTool<S extends z.ZodTypeAny = z.ZodTypeAny> extends ToolBase<S> {
  kind: 'read';
  run(ctx: ToolContext, args: z.infer<S>): Promise<unknown>;
}
export interface WriteTool<S extends z.ZodTypeAny = z.ZodTypeAny> extends ToolBase<S> {
  kind: 'write';
  propose(ctx: ToolContext, args: z.infer<S>): Promise<Proposal>;
  execute(ctx: ToolContext, args: z.infer<S>): Promise<Execution>;
}
export type AgentTool = ReadTool | WriteTool;

const read = <S extends z.ZodTypeAny>(t: Omit<ReadTool<S>, 'kind'>): ReadTool =>
  ({ kind: 'read', ...t }) as unknown as ReadTool;
const write = <S extends z.ZodTypeAny>(t: Omit<WriteTool<S>, 'kind'>): WriteTool =>
  ({ kind: 'write', ...t }) as unknown as WriteTool;

/* ------------------------------------------------------------ arg helpers */

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
// Local wall-clock, strict form YYYY-MM-DDTHH:mm. Models keep appending :00
// seconds (OpenAI-style datetimes); production trace 2026-09-19: create_workout
// was rejected 4× on "started_at: Invalid" and burned the whole step budget.
// Accept seconds (even fractional) and a space separator, then normalise.
const DATETIME_RE = /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?$/;

const dateTime = (d: string) =>
  z.string()
    .regex(DATETIME_RE, 'chưa đúng định dạng — giờ địa phương YYYY-MM-DDTHH:mm, ví dụ 2026-09-19T18:30 (không kèm giây)')
    .transform((v) => {
      const [day, clock] = v.split(/[T ]/) as [string, string];
      return `${day}T${clock.slice(0, 5)}`;
    })
    .describe(`${d} (YYYY-MM-DDTHH:mm, giờ địa phương)`);

/** Models send `null` for "not given" as often as they omit the key. */
const opt = <T extends z.ZodTypeAny>(t: T) =>
  t.nullish().transform((v) => v ?? undefined).describe(t.description ?? '');

const date = (d: string) => z.string().regex(DATE_RE).describe(`${d} (YYYY-MM-DD)`);
const id = (d: string) => z.string().trim().min(1).max(64).describe(d);
const num = (d: string, min: number, max: number) => z.coerce.number().min(min).max(max).describe(d);
const int = (d: string, min: number, max: number) =>
  z.coerce.number().int().min(min).max(max).describe(d);
const text = (d: string, max: number) => z.string().trim().min(1).max(max).describe(d);

const MEAL_TYPES = ['breakfast', 'lunch', 'dinner', 'snack'] as const;
const MEAL_LABEL: Record<string, string> = {
  breakfast: 'bữa sáng', lunch: 'bữa trưa', dinner: 'bữa tối', snack: 'bữa phụ',
};
const mealType = z.enum(MEAL_TYPES).describe('breakfast | lunch | dinner | snack');

const rangeArgs = z.object({
  from: date('Ngày bắt đầu'),
  to: date('Ngày kết thúc (tính cả ngày này)'),
});

function checkRange(from: string, to: string, maxDays: number): void {
  if (from > to) throw new ToolError('from phải trước hoặc bằng to');
  if (addDays(from, maxDays - 1) < to) throw new ToolError(`Khoảng tối đa ${maxDays} ngày`);
}

/* -------------------------------------------------------------- formatting */

const r0 = (v: unknown) => (typeof v === 'number' ? Math.round(v) : null);
const r1 = (v: unknown) => (typeof v === 'number' ? Math.round(v * 10) / 10 : null);

/** "2026-09-18 12:30" — what the model reads and writes back. */
function at(ms: number | null | undefined, tz: string): string | null {
  if (ms == null) return null;
  return `${localDate(ms, tz)} ${localTime(ms, tz)}`;
}

/** "12:30 18/09" — what the user reads on a confirm card. */
function human(ms: number, tz: string): string {
  const [, m, d] = localDate(ms, tz).split('-');
  return `${localTime(ms, tz)} ${d}/${m}`;
}

function humanDate(iso: string): string {
  const [y, m, d] = iso.split('-');
  return `${d}/${m}/${y}`;
}

function toEpoch(value: string, tz: string): number {
  const [d, t] = value.replace(' ', 'T').split('T') as [string, string];
  return localDateTimeToEpoch(d, t, tz);
}

/* ------------------------------------------------------------ API shapes */

type Row = Record<string, unknown>;

interface MealRow extends Row {
  id: string;
  mealType: string;
  loggedAt: number;
  dishName: string | null;
  note: string | null;
  totalCaloriesKcal: number | null;
  totalProteinG: number | null;
  totalCarbsG: number | null;
  totalFatG: number | null;
  totalWaterMl: number | null;
  itemCount?: number;
  analysis?: { status: string } | null;
}

interface MealItemRow extends Row {
  id: number;
  ingredientName: string;
  quantityG: number;
  quantityLabel: string | null;
  foodId: string | null;
  userFoodId: string | null;
  caloriesKcal: number | null;
}

interface MealDetail extends MealRow {
  items: MealItemRow[];
}

interface WorkoutRow extends Row {
  id: string;
  activityTypeId: number;
  title: string | null;
  startedAt: number;
  durationSeconds: number | null;
  distanceM: number | null;
  caloriesBurnedKcal: number | null;
  avgHeartRate: number | null;
  source: string;
  notes: string | null;
}

interface SleepRow extends Row {
  id: string;
  localDate: string;
  startedAt: number;
  endedAt: number;
  totalSleepSeconds: number | null;
  inBedSeconds: number | null;
  sleepEfficiency: number | null;
  sleepScore: number | null;
  source: string;
}

interface ActivityType { id: number; code: string; name: string }

const NUTRIENTS = [
  'caloriesKcal', 'proteinG', 'carbsG', 'fatG', 'saturatedFatG',
  'fiberG', 'sugarG', 'sodiumMg', 'cholesterolMg',
  // Fluid scales with the portion like everything else on the row.
  'waterMl',
] as const;

/* ------------------------------------------------------------- briefs */

function mealBrief(m: MealRow, tz: string) {
  return {
    meal_id: m.id,
    type: m.mealType,
    at: at(m.loggedAt, tz),
    dish: m.dishName,
    note: m.note,
    kcal: r0(m.totalCaloriesKcal),
    protein_g: r1(m.totalProteinG),
    carbs_g: r1(m.totalCarbsG),
    fat_g: r1(m.totalFatG),
    water_ml: r0(m.totalWaterMl),
    item_count: m.itemCount ?? (m as Partial<MealDetail>).items?.length ?? null,
    analysis: m.analysis?.status ?? null,
  };
}

function mealLabel(m: MealRow, tz: string): string {
  const dish = m.dishName ? ` · ${m.dishName}` : '';
  return `${MEAL_LABEL[m.mealType] ?? m.mealType} ${human(m.loggedAt, tz)}${dish}`;
}

interface FactRow extends Row {
  id: string;
  category: string;
  fact: string;
  expiresAt: number | null;
}

/**
 * A remembered fact as the model sees it. The expiry is spelled out rather
 * than left as an epoch: "đến 2026-10-12" is something the model can reason
 * about against today's date, a millisecond count is not.
 */
function factBrief(f: FactRow, tz: string) {
  return {
    fact_id: f.id,
    category: f.category,
    fact: f.fact,
    expires_at: f.expiresAt === null ? null : at(f.expiresAt, tz),
  };
}

function workoutBrief(w: WorkoutRow, types: Map<number, ActivityType>, tz: string) {
  return {
    workout_id: w.id,
    activity: types.get(w.activityTypeId)?.name ?? w.activityTypeId,
    activity_type_id: w.activityTypeId,
    title: w.title,
    started_at: at(w.startedAt, tz),
    duration_min: w.durationSeconds == null ? null : Math.round(w.durationSeconds / 60),
    distance_km: w.distanceM == null ? null : r1(w.distanceM / 1000),
    kcal: r0(w.caloriesBurnedKcal),
    avg_hr: w.avgHeartRate,
    source: w.source,
    notes: w.notes,
  };
}

function sleepBrief(s: SleepRow, tz: string) {
  return {
    sleep_id: s.id,
    wake_date: s.localDate,
    bedtime: at(s.startedAt, tz),
    wake_time: at(s.endedAt, tz),
    asleep_h: s.totalSleepSeconds == null ? null : r1(s.totalSleepSeconds / 3600),
    in_bed_h: s.inBedSeconds == null ? null : r1(s.inBedSeconds / 3600),
    efficiency: s.sleepEfficiency,
    score: s.sleepScore,
    source: s.source,
  };
}

/**
 * Generic trim for rows the model only needs to read: no ids of other tables,
 * no bookkeeping, no blobs, timestamps as local time, seconds as minutes.
 */
function compact(row: Row, tz: string): Row {
  const out: Row = {};
  for (const [key, value] of Object.entries(row)) {
    if (value === null || value === undefined) continue;
    if (key === 'userId' || key === 'createdAt' || key === 'updatedAt' || key.endsWith('Json')) continue;
    if (typeof value === 'number' && key.endsWith('At')) out[key] = at(value, tz);
    else if (typeof value === 'number' && key.endsWith('Seconds')) {
      out[key.replace(/Seconds$/, 'Minutes')] = Math.round(value / 60);
    } else if (typeof value === 'number') out[key] = r1(value);
    else out[key] = value;
  }
  return out;
}

/* ------------------------------------------------------------- lookups */

const api = <T>(ctx: ToolContext, method: Parameters<typeof callApi>[1], path: string, body?: unknown) =>
  callApi<T>(ctx.caller, method, path, body);

async function activityTypes(ctx: ToolContext): Promise<Map<number, ActivityType>> {
  let pending = ctx.memo.get('activityTypes') as Promise<Map<number, ActivityType>> | undefined;
  if (!pending) {
    pending = api<{ items: ActivityType[] }>(ctx, 'GET', '/v1/catalog/activity-types?locale=vi')
      .then((res) => new Map(res.items.map((t) => [t.id, t])));
    ctx.memo.set('activityTypes', pending);
  }
  return pending;
}

async function activityName(ctx: ToolContext, typeId: number): Promise<string> {
  const type = (await activityTypes(ctx)).get(typeId);
  if (!type) throw new ToolError(`activity_type_id ${typeId} không tồn tại — xem list_activity_types`);
  return type.name;
}

const getMeal = (ctx: ToolContext, mealId: string) =>
  api<MealDetail>(ctx, 'GET', `/v1/meals/${encodeURIComponent(mealId)}`);

async function getMealItem(ctx: ToolContext, mealId: string, itemId: number) {
  const meal = await getMeal(ctx, mealId);
  const item = meal.items.find((i) => i.id === itemId);
  if (!item) throw new ToolError(`item_id ${itemId} không thuộc bữa ${mealId} — xem get_meal`);
  return { meal, item };
}

const getWorkout = (ctx: ToolContext, workoutId: string) =>
  api<WorkoutRow>(ctx, 'GET', `/v1/workouts/${encodeURIComponent(workoutId)}`);

const getSleep = (ctx: ToolContext, sleepId: string) =>
  api<SleepRow>(ctx, 'GET', `/v1/sleep/sessions/${encodeURIComponent(sleepId)}`);

const q = (params: Record<string, string | number | undefined>) =>
  new URLSearchParams(
    Object.entries(params)
      // An omitted optional argument must not become "?q=undefined".
      .filter((e): e is [string, string | number] => e[1] !== undefined)
      .map(([k, v]): [string, string] => [k, String(v)]),
  ).toString();

/* --------------------------------------------------------------- tools */

const TOOLS: AgentTool[] = [
  read({
    name: 'get_profile',
    args: z.object({}),
    async run(ctx) {
      const [me, tdee] = await Promise.all([
        api<Row & {
          user: Row; profile: Row | null; latestBodyMetrics: Row | null;
          activeGoals: Row[]; activeConditions: Row[];
        }>(ctx, 'GET', '/v1/me'),
        api<Row & { inputs: Row; missingInputs: string[] }>(ctx, 'GET', '/v1/me/tdee'),
      ]);
      return {
        name: me.user.displayName ?? null,
        age: tdee.inputs.age,
        sex: tdee.inputs.biologicalSex,
        height_cm: tdee.inputs.heightCm,
        weight_kg: tdee.inputs.weightKg,
        weight_recorded_at: at(tdee.inputs.weightRecordedAt as number | null, ctx.user.timezone),
        body_fat_percent: me.latestBodyMetrics?.bodyFatPercent ?? null,
        waist_cm: me.latestBodyMetrics?.waistCm ?? null,
        activity_level: tdee.inputs.activityLevel,
        bmr_kcal: r0(tdee.bmrKcal),
        tdee_kcal_today: r0(tdee.tdeeKcal),
        daily_calorie_override_kcal: tdee.inputs.dailyCalorieOverrideKcal ?? null,
        missing_inputs: tdee.missingInputs,
        target_sleep_minutes: me.profile?.targetSleepMinutes ?? null,
        training_focus: me.profile?.trainingFocus ?? null,
        resting_heart_rate: me.profile?.restingHeartRate ?? null,
        goals: me.activeGoals.map((g) => ({
          type: g.goalType, target: g.targetValue, unit: g.targetUnit,
          start: g.startValue, deadline: g.deadline,
        })),
        conditions: me.activeConditions.map((c) => ({
          description: c.description, diagnosed_on: c.diagnosedOn, notes: c.notes,
        })),
      };
    },
  }),

  read({
    name: 'get_day_summary',
    args: z.object({ date: date('Ngày cần xem') }),
    async run(ctx, { date: day }) {
      const tz = ctx.user.timezone;
      const [daily, workouts, sleep, types] = await Promise.all([
        api<{ summary: Row | null; meals: MealRow[]; energy: Row }>(
          ctx, 'GET', `/v1/nutrition/daily?${q({ date: day })}`),
        api<{ items: WorkoutRow[] }>(ctx, 'GET', `/v1/workouts?${q({ from: day, to: day })}`),
        api<{ items: SleepRow[] }>(ctx, 'GET', `/v1/sleep/sessions?${q({ from: day, to: day })}`),
        activityTypes(ctx),
      ]);
      const s = daily.summary;
      return {
        date: day,
        nutrition: {
          consumed_kcal: r0(s?.caloriesConsumedKcal ?? 0),
          protein_g: r1(s?.proteinG), carbs_g: r1(s?.carbsG), fat_g: r1(s?.fatG),
          fiber_g: r1(s?.fiberG), sugar_g: r1(s?.sugarG), sodium_mg: r0(s?.sodiumMg),
          workout_kcal: r0(s?.caloriesBurnedWorkoutKcal ?? 0),
          tdee_kcal: r0(daily.energy?.tdeeKcal ?? s?.tdeeKcal),
          balance_kcal: r0(s?.calorieBalanceKcal),
        },
        meals: daily.meals.map((m) => mealBrief(m, tz)),
        workouts: workouts.items.map((w) => workoutBrief(w, types, tz)),
        sleep: sleep.items.map((x) => sleepBrief(x, tz)),
      };
    },
  }),

  read({
    name: 'get_nutrition_range',
    args: rangeArgs,
    async run(ctx, { from, to }) {
      checkRange(from, to, 62);
      const res = await api<{ items: Row[] }>(ctx, 'GET', `/v1/nutrition/range?${q({ from, to })}`);
      return {
        days: res.items.map((d) => ({
          date: d.localDate,
          consumed_kcal: r0(d.caloriesConsumedKcal),
          protein_g: r1(d.proteinG), carbs_g: r1(d.carbsG), fat_g: r1(d.fatG),
          workout_kcal: r0(d.caloriesBurnedWorkoutKcal),
          tdee_kcal: r0(d.tdeeKcal),
          balance_kcal: r0(d.calorieBalanceKcal),
          meals: d.mealsLogged,
        })),
        note: 'Ngày không có trong danh sách = chưa ghi gì.',
      };
    },
  }),

  read({
    name: 'list_meals',
    args: rangeArgs,
    async run(ctx, { from, to }) {
      checkRange(from, to, 31);
      const res = await api<{ items: MealRow[] }>(
        ctx, 'GET', `/v1/meals?${q({ from, to, limit: 150 })}`);
      return { meals: res.items.map((m) => mealBrief(m, ctx.user.timezone)) };
    },
  }),

  read({
    name: 'get_meal',
    args: z.object({ meal_id: id('meal_id') }),
    async run(ctx, { meal_id }) {
      const meal = await getMeal(ctx, meal_id);
      return {
        ...mealBrief(meal, ctx.user.timezone),
        items: meal.items.map((i) => ({
          item_id: i.id,
          name: i.ingredientName,
          grams: r0(i.quantityG),
          label: i.quantityLabel,
          kcal: r0(i.caloriesKcal),
          protein_g: r1(i.proteinG), carbs_g: r1(i.carbsG), fat_g: r1(i.fatG),
        })),
      };
    },
  }),

  read({
    name: 'search_foods',
    args: z.object({ query: text('Tên thực phẩm / món ăn', 100) }),
    async run(ctx, { query }) {
      const res = await api<{ personal: Row[]; global: Row[] }>(
        ctx, 'GET', `/v1/foods/search?${q({ q: query })}`);
      const per100 = (f: Row) => {
        const serving = Number(f.servingSizeG) || 100;
        const k = 100 / serving;
        return {
          name: f.name,
          brand: f.brand ?? null,
          mine: f.kind === 'user_food',
          per_100g: {
            kcal: r0(Number(f.caloriesKcal) * k),
            protein_g: r1(Number(f.proteinG ?? 0) * k),
            carbs_g: r1(Number(f.carbsG ?? 0) * k),
            fat_g: r1(Number(f.fatG ?? 0) * k),
            fiber_g: r1(Number(f.fiberG ?? 0) * k),
          },
          serving: f.servingLabel ? `${f.servingLabel} (${serving} g)` : `${serving} g`,
        };
      };
      return { foods: [...res.personal, ...res.global].slice(0, 8).map(per100) };
    },
  }),

  read({
    name: 'list_workouts',
    args: rangeArgs,
    async run(ctx, { from, to }) {
      checkRange(from, to, 62);
      const [res, types] = await Promise.all([
        api<{ items: WorkoutRow[] }>(ctx, 'GET', `/v1/workouts?${q({ from, to, limit: 150 })}`),
        activityTypes(ctx),
      ]);
      return { workouts: res.items.map((w) => workoutBrief(w, types, ctx.user.timezone)) };
    },
  }),

  read({
    name: 'list_activity_types',
    args: z.object({}),
    async run(ctx) {
      const types = await activityTypes(ctx);
      return { types: [...types.values()].map((t) => ({ activity_type_id: t.id, code: t.code, name: t.name })) };
    },
  }),

  read({
    name: 'get_training_records',
    args: z.object({}),
    async run(ctx) {
      const [res, types] = await Promise.all([
        api<{ items: Row[] }>(ctx, 'GET', '/v1/training/records'),
        activityTypes(ctx),
      ]);
      return {
        records: res.items.map((r) => ({
          ...compact(r, ctx.user.timezone),
          activity: types.get(Number(r.activityTypeId))?.name ?? null,
        })),
      };
    },
  }),

  read({
    name: 'list_sleep',
    args: rangeArgs,
    async run(ctx, { from, to }) {
      checkRange(from, to, 62);
      const res = await api<{ items: SleepRow[] }>(
        ctx, 'GET', `/v1/sleep/sessions?${q({ from, to, limit: 100 })}`);
      return { nights: res.items.map((s) => sleepBrief(s, ctx.user.timezone)) };
    },
  }),

  read({
    name: 'get_sleep_debt',
    args: z.object({}),
    async run(ctx) {
      const res = await api<{
        targetSeconds: number; windowDays: number; rollingDebtSeconds: number;
        daysRecorded: number; byDay: Array<Row & { localDate: string; actualSleepSeconds: number; hasData: boolean }>;
      }>(ctx, 'GET', '/v1/sleep/debt');
      return {
        target_h: r1(res.targetSeconds / 3600),
        window_days: res.windowDays,
        debt_h: r1(res.rollingDebtSeconds / 3600),
        days_recorded: res.daysRecorded,
        by_day: res.byDay.map((d) => ({
          date: d.localDate,
          slept_h: d.hasData ? r1(d.actualSleepSeconds / 3600) : null,
        })),
      };
    },
  }),

  read({
    name: 'list_body_metrics',
    args: rangeArgs,
    async run(ctx, { from, to }) {
      checkRange(from, to, 366);
      const res = await api<{ items: Row[] }>(
        ctx, 'GET', `/v1/me/body-metrics?${q({ from, to, limit: 100 })}`);
      return { entries: res.items.map((m) => compact(m, ctx.user.timezone)) };
    },
  }),

  /* ------------------------------------------------------------ writes */

  write({
    name: 'create_meal',
    args: z.object({
      meal_type: mealType,
      eaten_at: opt(dateTime('Thời điểm ăn; bỏ trống = bây giờ')),
      description: text('Mô tả món và khẩu phần, vd "1 tô phở bò tái, 1 ly trà đá"', 1000),
      note: opt(text('Ghi chú kèm bữa', 300)),
    }),
    async propose(ctx, a) {
      const when = a.eaten_at ? toEpoch(a.eaten_at, ctx.user.timezone) : Date.now();
      if (when > Date.now() + 10 * 60_000) throw new ToolError('Không ghi bữa ăn ở tương lai');
      return {
        summary: `Ghi ${MEAL_LABEL[a.meal_type]} lúc ${human(when, ctx.user.timezone)}: ${a.description}`,
        details: ['Thành phần và dinh dưỡng được tính tự động từ kho thực phẩm, như khi nhập tay.'],
      };
    },
    async execute(ctx, a) {
      const loggedAt = a.eaten_at ? toEpoch(a.eaten_at, ctx.user.timezone) : Date.now();
      const meal = await api<{ id: string }>(ctx, 'POST', '/v1/meals', {
        mealType: a.meal_type, loggedAt, note: a.note ?? null,
      });
      try {
        await api(ctx, 'POST', `/v1/meals/${meal.id}/voice`, { transcript: a.description });
      } catch (err) {
        // A meal with nothing to analyse is an empty card on the timeline.
        await api(ctx, 'DELETE', `/v1/meals/${meal.id}`).catch(() => undefined);
        throw err;
      }
      return { result: { meal_id: meal.id }, link: { type: 'meal', id: meal.id } };
    },
  }),

  write({
    name: 'update_meal',
    args: z.object({
      meal_id: id('meal_id'),
      meal_type: opt(mealType),
      eaten_at: opt(dateTime('Thời điểm ăn mới')),
      dish_name: opt(text('Tên món mới', 200)),
      note: opt(z.string().trim().max(300).describe('Ghi chú mới; chuỗi rỗng để xoá ghi chú')),
    }),
    async propose(ctx, a) {
      const tz = ctx.user.timezone;
      const meal = await getMeal(ctx, a.meal_id);
      const changes: string[] = [];
      if (a.meal_type) changes.push(`loại bữa → ${MEAL_LABEL[a.meal_type]}`);
      if (a.eaten_at) changes.push(`giờ ăn → ${human(toEpoch(a.eaten_at, tz), tz)}`);
      if (a.dish_name) changes.push(`tên món → ${a.dish_name}`);
      if (a.note !== undefined) changes.push(a.note ? `ghi chú → ${a.note}` : 'xoá ghi chú');
      if (changes.length === 0) throw new ToolError('Không có gì để sửa');
      return { summary: `Sửa ${mealLabel(meal, tz)}: ${changes.join('; ')}` };
    },
    async execute(ctx, a) {
      await api(ctx, 'PATCH', `/v1/meals/${encodeURIComponent(a.meal_id)}`, {
        mealType: a.meal_type,
        loggedAt: a.eaten_at ? toEpoch(a.eaten_at, ctx.user.timezone) : undefined,
        dishName: a.dish_name,
        note: a.note,
      });
      return { link: { type: 'meal', id: a.meal_id } };
    },
  }),

  write({
    name: 'update_meal_item',
    args: z.object({
      meal_id: id('meal_id'),
      item_id: int('item_id (từ get_meal)', 1, Number.MAX_SAFE_INTEGER),
      quantity_g: num('Khối lượng mới (gram)', 1, 5000),
    }),
    async propose(ctx, a) {
      const { meal, item } = await getMealItem(ctx, a.meal_id, a.item_id);
      if (!(item.quantityG > 0)) throw new ToolError('Thành phần này không có khối lượng gốc để quy đổi');
      const kcal = item.caloriesKcal == null ? null : Math.round(item.caloriesKcal * a.quantity_g / item.quantityG);
      const kcalText = kcal == null ? '' : ` (~${r0(item.caloriesKcal)} → ${kcal} kcal)`;
      return {
        summary: `Đổi ${item.ingredientName} trong ${mealLabel(meal, ctx.user.timezone)}: ${r0(item.quantityG)} g → ${r0(a.quantity_g)} g${kcalText}`,
      };
    },
    async execute(ctx, a) {
      const { item } = await getMealItem(ctx, a.meal_id, a.item_id);
      if (!(item.quantityG > 0)) throw new ToolError('Thành phần này không có khối lượng gốc để quy đổi');
      const k = a.quantity_g / item.quantityG;
      const scaled: Record<string, number | null> = {};
      for (const key of NUTRIENTS) {
        const v = item[key];
        scaled[key] = typeof v === 'number' ? Math.round(v * k * 10) / 10 : null;
      }
      // learn=false: a portion change says nothing new about the food itself.
      await api(ctx, 'PATCH', `/v1/meals/${encodeURIComponent(a.meal_id)}/items/${item.id}?learn=false`, {
        ingredientName: item.ingredientName,
        quantityG: a.quantity_g,
        quantityLabel: null,
        foodId: item.foodId,
        userFoodId: item.userFoodId,
        ...scaled,
        caloriesKcal: scaled.caloriesKcal ?? 0,
      });
      return { link: { type: 'meal', id: a.meal_id } };
    },
  }),

  write({
    name: 'delete_meal_item',
    args: z.object({
      meal_id: id('meal_id'),
      item_id: int('item_id (từ get_meal)', 1, Number.MAX_SAFE_INTEGER),
    }),
    async propose(ctx, a) {
      const { meal, item } = await getMealItem(ctx, a.meal_id, a.item_id);
      return {
        summary: `Xoá ${item.ingredientName} (${r0(item.quantityG)} g, ${r0(item.caloriesKcal) ?? '?'} kcal) khỏi ${mealLabel(meal, ctx.user.timezone)}`,
      };
    },
    async execute(ctx, a) {
      await api(ctx, 'DELETE', `/v1/meals/${encodeURIComponent(a.meal_id)}/items/${a.item_id}`);
      return { link: { type: 'meal', id: a.meal_id } };
    },
  }),

  write({
    name: 'add_meal_items',
    args: z.object({
      meal_id: id('meal_id'),
      description: text('Món cần thêm và khẩu phần, vd "1 quả trứng ốp la"', 500),
    }),
    async propose(ctx, a) {
      const meal = await getMeal(ctx, a.meal_id);
      if (meal.analysis?.status === 'running' || meal.analysis?.status === 'pending') {
        throw new ToolError('Bữa này đang được phân tích, đợi xong rồi thử lại');
      }
      return {
        summary: `Thêm vào ${mealLabel(meal, ctx.user.timezone)}: ${a.description}`,
        details: ['Cả bữa sẽ được phân tích lại từ các thành phần hiện có cộng món mới; số liệu sửa tay trước đó của bữa này sẽ được tính lại.'],
      };
    },
    async execute(ctx, a) {
      const meal = await getMeal(ctx, a.meal_id);
      // The analysis replaces every item, so the current ones go back in as text.
      const existing = meal.items.map((i) => `${i.ingredientName} ${r0(i.quantityG)}g`);
      const transcript = [...existing, a.description].join(', ');
      await api(ctx, 'POST', `/v1/meals/${encodeURIComponent(a.meal_id)}/voice`, { transcript });
      return { link: { type: 'meal', id: a.meal_id } };
    },
  }),

  write({
    name: 'delete_meal',
    args: z.object({ meal_id: id('meal_id') }),
    async propose(ctx, a) {
      const meal = await getMeal(ctx, a.meal_id);
      const kcal = r0(meal.totalCaloriesKcal);
      return { summary: `Xoá ${mealLabel(meal, ctx.user.timezone)}${kcal == null ? '' : ` (${kcal} kcal)`}` };
    },
    async execute(ctx, a) {
      await api(ctx, 'DELETE', `/v1/meals/${encodeURIComponent(a.meal_id)}`);
      return {};
    },
  }),

  write({
    name: 'log_water',
    args: z.object({
      amount_ml: int('Lượng nước (ml); số âm để bớt', -3000, 3000),
      date: opt(date('Ngày; bỏ trống = hôm nay')),
    }),
    async propose(ctx, a) {
      if (a.amount_ml === 0) throw new ToolError('amount_ml phải khác 0');
      const day = a.date ?? localDate(Date.now(), ctx.user.timezone);
      const verb = a.amount_ml > 0 ? 'Thêm' : 'Bớt';
      return { summary: `${verb} ${Math.abs(a.amount_ml)} ml nước vào ngày ${humanDate(day)}` };
    },
    async execute(ctx, a) {
      const day = a.date ?? localDate(Date.now(), ctx.user.timezone);
      return { clientEffect: { type: 'water_add', date: day, ml: a.amount_ml } };
    },
  }),

  write({
    name: 'create_workout',
    args: z.object({
      activity_type_id: int('activity_type_id (từ list_activity_types)', 1, 1_000_000),
      started_at: dateTime('Thời điểm bắt đầu'),
      duration_min: num('Thời lượng (phút)', 1, 1440),
      distance_km: opt(num('Quãng đường (km)', 0, 1000)),
      calories_kcal: opt(num('Calo tiêu hao nếu người dùng biết; bỏ trống để tự ước tính', 0, 10000)),
      title: opt(text('Tiêu đề', 200)),
      notes: opt(text('Ghi chú', 1000)),
    }),
    async propose(ctx, a) {
      const tz = ctx.user.timezone;
      const name = await activityName(ctx, a.activity_type_id);
      const start = toEpoch(a.started_at, tz);
      if (start > Date.now() + 10 * 60_000) throw new ToolError('Không ghi buổi tập ở tương lai');
      const parts = [`${Math.round(a.duration_min)} phút`];
      if (a.distance_km) parts.push(`${a.distance_km} km`);
      parts.push(a.calories_kcal != null ? `${Math.round(a.calories_kcal)} kcal` : 'calo tự ước tính');
      return { summary: `Ghi buổi ${name} lúc ${human(start, tz)}: ${parts.join(', ')}` };
    },
    async execute(ctx, a) {
      const startedAt = toEpoch(a.started_at, ctx.user.timezone);
      const durationSeconds = Math.round(a.duration_min * 60);
      const row = await api<{ id: string }>(ctx, 'POST', '/v1/workouts', {
        activityTypeId: a.activity_type_id,
        source: 'manual_entry',
        startedAt,
        endedAt: startedAt + durationSeconds * 1000,
        durationSeconds,
        distanceM: a.distance_km == null ? null : Math.round(a.distance_km * 1000),
        caloriesBurnedKcal: a.calories_kcal ?? null,
        caloriesAreEstimated: a.calories_kcal == null,
        title: a.title ?? null,
        notes: a.notes ?? null,
      });
      return { result: { workout_id: row.id }, link: { type: 'workout', id: row.id } };
    },
  }),

  write({
    name: 'update_workout',
    args: z.object({
      workout_id: id('workout_id'),
      activity_type_id: opt(int('Môn mới (activity_type_id)', 1, 1_000_000)),
      duration_min: opt(num('Thời lượng mới (phút)', 1, 1440)),
      distance_km: opt(num('Quãng đường mới (km)', 0, 1000)),
      calories_kcal: opt(num('Calo mới', 0, 10000)),
      title: opt(text('Tiêu đề mới', 200)),
      notes: opt(text('Ghi chú mới', 1000)),
    }),
    async propose(ctx, a) {
      const tz = ctx.user.timezone;
      const w = await getWorkout(ctx, a.workout_id);
      const changes: string[] = [];
      if (a.activity_type_id) changes.push(`môn → ${await activityName(ctx, a.activity_type_id)}`);
      if (a.duration_min) changes.push(`thời lượng → ${Math.round(a.duration_min)} phút`);
      if (a.distance_km != null) changes.push(`quãng đường → ${a.distance_km} km`);
      if (a.calories_kcal != null) changes.push(`calo → ${Math.round(a.calories_kcal)} kcal`);
      if (a.title) changes.push(`tiêu đề → ${a.title}`);
      if (a.notes) changes.push('ghi chú mới');
      if (changes.length === 0) throw new ToolError('Không có gì để sửa');
      const name = await activityName(ctx, w.activityTypeId).catch(() => 'buổi tập');
      return { summary: `Sửa buổi ${name} lúc ${human(w.startedAt, tz)}: ${changes.join('; ')}` };
    },
    async execute(ctx, a) {
      const w = await getWorkout(ctx, a.workout_id);
      const durationSeconds = a.duration_min ? Math.round(a.duration_min * 60) : undefined;
      await api(ctx, 'PATCH', `/v1/workouts/${encodeURIComponent(a.workout_id)}`, {
        activityTypeId: a.activity_type_id,
        durationSeconds,
        endedAt: durationSeconds ? w.startedAt + durationSeconds * 1000 : undefined,
        distanceM: a.distance_km == null ? undefined : Math.round(a.distance_km * 1000),
        caloriesBurnedKcal: a.calories_kcal,
        title: a.title,
        notes: a.notes,
      });
      return { link: { type: 'workout', id: a.workout_id } };
    },
  }),

  write({
    name: 'delete_workout',
    args: z.object({ workout_id: id('workout_id') }),
    async propose(ctx, a) {
      const w = await getWorkout(ctx, a.workout_id);
      if (w.isDeleted) throw new ToolError('Buổi tập này đã bị xoá');
      const name = await activityName(ctx, w.activityTypeId).catch(() => 'buổi tập');
      const minutes = w.durationSeconds ? `, ${Math.round(w.durationSeconds / 60)} phút` : '';
      return { summary: `Xoá buổi ${name} lúc ${human(w.startedAt, ctx.user.timezone)}${minutes}` };
    },
    async execute(ctx, a) {
      await api(ctx, 'DELETE', `/v1/workouts/${encodeURIComponent(a.workout_id)}`);
      return {};
    },
  }),

  write({
    name: 'log_sleep',
    args: z.object({
      bedtime: dateTime('Giờ đi ngủ'),
      wake_time: dateTime('Giờ thức dậy'),
      latency_min: opt(int('Số phút nằm chờ ngủ', 0, 240)),
    }),
    async propose(ctx, a) {
      const tz = ctx.user.timezone;
      const start = toEpoch(a.bedtime, tz);
      const end = toEpoch(a.wake_time, tz);
      if (end <= start) throw new ToolError('wake_time phải sau bedtime');
      if (end - start > 16 * 3_600_000) throw new ToolError('Một giấc ngủ tối đa 16 giờ');
      if (end > Date.now() + 10 * 60_000) throw new ToolError('Không ghi giấc ngủ ở tương lai');
      const wakeDay = localDate(end, tz);
      const existing = await api<{ items: SleepRow[] }>(
        ctx, 'GET', `/v1/sleep/sessions?${q({ from: wakeDay, to: wakeDay })}`);
      const hours = r1((end - start) / 3_600_000);
      return {
        summary: `Ghi giấc ngủ ${human(start, tz)} → ${human(end, tz)} (${hours} giờ trên giường)`,
        details: existing.items.length > 0
          ? [`Đêm thức dậy ngày ${humanDate(wakeDay)} đã có dữ liệu — sẽ bị thay bằng bản ghi này.`]
          : undefined,
      };
    },
    async execute(ctx, a) {
      const tz = ctx.user.timezone;
      const row = await api<{ id: string }>(ctx, 'POST', '/v1/sleep/sessions', {
        source: 'manual',
        startedAt: toEpoch(a.bedtime, tz),
        endedAt: toEpoch(a.wake_time, tz),
        sleepLatencySeconds: a.latency_min == null ? null : a.latency_min * 60,
      });
      return { link: { type: 'sleep', id: row.id } };
    },
  }),

  write({
    name: 'update_sleep',
    args: z.object({
      sleep_id: id('sleep_id'),
      bedtime: opt(dateTime('Giờ đi ngủ mới')),
      wake_time: opt(dateTime('Giờ thức dậy mới')),
    }),
    async propose(ctx, a) {
      const tz = ctx.user.timezone;
      if (!a.bedtime && !a.wake_time) throw new ToolError('Không có gì để sửa');
      const s = await getSleep(ctx, a.sleep_id);
      const start = a.bedtime ? toEpoch(a.bedtime, tz) : s.startedAt;
      const end = a.wake_time ? toEpoch(a.wake_time, tz) : s.endedAt;
      if (end <= start) throw new ToolError('wake_time phải sau bedtime');
      if (end - start > 16 * 3_600_000) throw new ToolError('Một giấc ngủ tối đa 16 giờ');
      return {
        summary: `Sửa giấc ngủ ${human(s.startedAt, tz)} → ${human(s.endedAt, tz)} thành ${human(start, tz)} → ${human(end, tz)}`,
      };
    },
    async execute(ctx, a) {
      const tz = ctx.user.timezone;
      await api(ctx, 'PATCH', `/v1/sleep/sessions/${encodeURIComponent(a.sleep_id)}`, {
        startedAt: a.bedtime ? toEpoch(a.bedtime, tz) : undefined,
        endedAt: a.wake_time ? toEpoch(a.wake_time, tz) : undefined,
      });
      return { link: { type: 'sleep', id: a.sleep_id } };
    },
  }),

  write({
    name: 'log_body_metrics',
    args: z.object({
      weight_kg: opt(num('Cân nặng (kg)', 20, 400)),
      height_cm: opt(num('Chiều cao (cm)', 80, 260)),
      body_fat_percent: opt(num('% mỡ cơ thể', 1, 75)),
      muscle_mass_kg: opt(num('Khối cơ (kg)', 1, 200)),
      waist_cm: opt(num('Vòng eo (cm)', 30, 250)),
      measured_at: opt(dateTime('Thời điểm đo; bỏ trống = bây giờ')),
    }),
    async propose(ctx, a) {
      const parts: string[] = [];
      if (a.weight_kg != null) parts.push(`cân nặng ${a.weight_kg} kg`);
      if (a.height_cm != null) parts.push(`chiều cao ${a.height_cm} cm`);
      if (a.body_fat_percent != null) parts.push(`mỡ ${a.body_fat_percent}%`);
      if (a.muscle_mass_kg != null) parts.push(`khối cơ ${a.muscle_mass_kg} kg`);
      if (a.waist_cm != null) parts.push(`vòng eo ${a.waist_cm} cm`);
      if (parts.length === 0) throw new ToolError('Cần ít nhất một chỉ số');
      const when = a.measured_at ? toEpoch(a.measured_at, ctx.user.timezone) : Date.now();
      return { summary: `Ghi chỉ số lúc ${human(when, ctx.user.timezone)}: ${parts.join(', ')}` };
    },
    async execute(ctx, a) {
      await api(ctx, 'POST', '/v1/me/body-metrics', {
        recordedAt: a.measured_at ? toEpoch(a.measured_at, ctx.user.timezone) : undefined,
        weightKg: a.weight_kg,
        heightCm: a.height_cm,
        bodyFatPercent: a.body_fat_percent,
        muscleMassKg: a.muscle_mass_kg,
        waistCm: a.waist_cm,
      });
      return {};
    },
  }),

  /* ------------------------------------------------------------- memory */

  read({
    name: 'remember_fact',
    args: z.object({
      fact: z.string().trim().min(3).max(300)
        .describe('một câu ngắn, ngôi thứ ba, vd "dị ứng hải sản" hoặc "tập gym tối thứ 3, 5, 7"'),
      category: z.enum(['health', 'nutrition', 'training', 'sleep', 'preference', 'other'])
        .default('other')
        .describe('health | nutrition | training | sleep | preference | other'),
      expires_in_days: z.number().positive().max(730).nullish()
        .describe('số ngày thông tin còn đúng; bỏ trống nếu đúng mãi mãi'),
    }),
    async run(ctx, a) {
      const saved = await api<{ id: string; fact: string; expiresAt: number | null }>(
        ctx, 'POST', '/v1/me/facts',
        {
          fact: a.fact,
          category: a.category,
          expiresInDays: a.expires_in_days ?? null,
          conversationId: ctx.conversationId ?? null,
        },
      );
      return {
        fact_id: saved.id,
        fact: saved.fact,
        expires_at: saved.expiresAt === null
          ? null
          : at(saved.expiresAt, ctx.user.timezone),
      };
    },
  }),

  read({
    name: 'search_facts',
    args: z.object({
      query: z.string().trim().max(200).optional()
        .describe('từ khoá cần tìm trong các điều đã nhớ; bỏ trống để lấy tất cả'),
      category: z.enum(['health', 'nutrition', 'training', 'sleep', 'preference', 'other'])
        .optional(),
      limit: z.number().int().min(1).max(50).optional(),
    }),
    async run(ctx, a) {
      const res = await api<{ items: FactRow[] }>(
        ctx, 'GET',
        `/v1/me/facts?${q({ q: a.query, category: a.category, limit: a.limit ?? 30 })}`,
      );
      return { facts: res.items.map((f) => factBrief(f, ctx.user.timezone)) };
    },
  }),

  read({
    name: 'forget_fact',
    args: z.object({
      fact_id: z.string().describe('id lấy từ search_facts hoặc phần đã nhớ trong ngữ cảnh'),
    }),
    async run(ctx, a) {
      await api(ctx, 'DELETE', `/v1/me/facts/${encodeURIComponent(a.fact_id)}`);
      return { forgotten: true };
    },
  }),
];

export const AGENT_TOOLS: ReadonlyMap<string, AgentTool> = new Map(TOOLS.map((t) => [t.name, t]));

/* --------------------------------------------------- JSON schema for the model */

type JsonSchema = Record<string, unknown>;

/**
 * Just enough zod → JSON Schema for the argument shapes above, so each tool has
 * one schema that both validates and describes. Wrappers (optional, nullable,
 * transform) are peeled; the first description found on the way in wins.
 */
function describe(t: z.ZodTypeAny): { schema: JsonSchema; optional: boolean } {
  let node: z.ZodTypeAny = t;
  let optional = false;
  let description: string | undefined;
  for (;;) {
    description ??= node.description || undefined;
    if (node instanceof z.ZodOptional || node instanceof z.ZodNullable) {
      optional = true;
      node = node.unwrap();
    } else if (node instanceof z.ZodEffects) {
      node = node.innerType();
    } else if (node instanceof z.ZodDefault) {
      optional = true;
      node = node.removeDefault();
    } else break;
  }

  let schema: JsonSchema;
  if (node instanceof z.ZodString) schema = { type: 'string' };
  else if (node instanceof z.ZodNumber) schema = { type: node.isInt ? 'integer' : 'number' };
  else if (node instanceof z.ZodBoolean) schema = { type: 'boolean' };
  else if (node instanceof z.ZodEnum) schema = { type: 'string', enum: node.options };
  else if (node instanceof z.ZodObject) {
    const properties: Record<string, JsonSchema> = {};
    const required: string[] = [];
    for (const [key, value] of Object.entries(node.shape as z.ZodRawShape)) {
      const d = describe(value);
      properties[key] = d.schema;
      if (!d.optional) required.push(key);
    }
    schema = { type: 'object', properties, required };
  } else throw new Error(`Unsupported tool argument type: ${node.constructor.name}`);

  if (description) schema.description = description;
  return { schema, optional };
}

let definitions: unknown[] | null = null;

/** OpenAI-style tool list for Workers AI; built once per isolate. */
export function toolDefinitions(): unknown[] {
  if (definitions) return definitions;
  const descriptions = promptSections(PROMPTS.agentTools);
  definitions = TOOLS.map((t) => {
    const description = descriptions.get(t.name);
    if (!description) throw new Error(`prompts/agent/tools.md has no section for ${t.name}`);
    return {
      type: 'function',
      function: { name: t.name, description, parameters: describe(t.args).schema },
    };
  });
  return definitions;
}
