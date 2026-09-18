import { Hono, type Context } from 'hono';
import { and, asc, desc, eq, gte, inArray, lte, sql } from 'drizzle-orm';
import { z } from 'zod';
import { coachActions, coachConversations, coachMessages, coachInsights } from '../db/schema';
import { parseBody, parseQuery, paginationSchema, page, isoDateSchema } from '../lib/http';
import { ApiError, notFound } from '../lib/errors';
import { newId } from '../lib/ids';
import { modelConfig } from '../config/models';
import { runAgentTurn } from '../services/agent/agent';
import { AGENT_TOOLS, ToolError, type Execution } from '../services/agent/tools';
import type { ChatTurn } from '../services/coach';
import type { ApiCaller } from '../lib/internalApi';
import type { AppEnv } from '../env';

const app = new Hono<AppEnv>();

type Db = AppEnv['Variables']['db'];

/** Only the last few turns are replayed; the agent fetches older data with tools. */
const HISTORY_TURNS = 12;

/** A proposal left unanswered this long can no longer be confirmed. */
export const ACTION_TTL_MS = 24 * 3_600_000;

app.get('/conversations', async (c) => {
  const q = parseQuery(c, paginationSchema);
  const filters = [
    eq(coachConversations.userId, c.get('user').id),
    eq(coachConversations.isArchived, false),
  ];
  if (q.cursor) filters.push(sql`${coachConversations.id} < ${q.cursor}`);

  const rows = await c.get('db').select().from(coachConversations)
    .where(and(...filters))
    .orderBy(desc(coachConversations.lastMessageAt), desc(coachConversations.id))
    .limit(q.limit + 1);
  return c.json(page(rows, q.limit));
});

app.post('/conversations', async (c) => {
  const body = await parseBody(c, z.object({ title: z.string().max(200).nullish() }));
  const id = newId();
  const now = Date.now();

  await c.get('db').insert(coachConversations).values({
    id,
    userId: c.get('user').id,
    title: body.title ?? null,
    messageCount: 0,
    createdAt: now,
    updatedAt: now,
  });

  const rows = await c.get('db').select().from(coachConversations)
    .where(eq(coachConversations.id, id)).limit(1);
  return c.json(rows[0], 201);
});

async function ownedConversation(db: Db, userId: string, id: string) {
  const rows = await db.select().from(coachConversations)
    .where(and(
      eq(coachConversations.id, id),
      eq(coachConversations.userId, userId),
      eq(coachConversations.isArchived, false),
    ))
    .limit(1);
  const conversation = rows[0];
  if (!conversation) throw notFound('Conversation');
  return conversation;
}

/**
 * Archived, not deleted: the messages are what the per-day rate limit counts,
 * so deleting a thread must not hand the quota back.
 */
app.delete('/conversations/:id', async (c) => {
  const db = c.get('db');
  const conversation = await ownedConversation(db, c.get('user').id, c.req.param('id'));
  await db.update(coachConversations)
    .set({ isArchived: true, updatedAt: Date.now() })
    .where(eq(coachConversations.id, conversation.id));
  await db.update(coachActions)
    .set({ status: 'cancelled', resolvedAt: Date.now() })
    .where(and(eq(coachActions.conversationId, conversation.id), eq(coachActions.status, 'pending')));
  return c.body(null, 204);
});

/* ------------------------------------------------------------ serializers */

type ActionRow = typeof coachActions.$inferSelect;
type MessageRow = typeof coachMessages.$inferSelect;

function parseJson(raw: string | null): unknown {
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function isExpired(a: ActionRow, now = Date.now()): boolean {
  return a.status === 'pending' && now - a.createdAt > ACTION_TTL_MS;
}

function serializeAction(a: ActionRow) {
  return {
    id: a.id,
    tool: a.tool,
    summary: a.summary,
    details: (parseJson(a.detailsJson) as string[] | null) ?? [],
    status: isExpired(a) ? 'expired' : a.status,
    result: parseJson(a.resultJson),
    error: a.errorMessage,
    createdAt: a.createdAt,
    resolvedAt: a.resolvedAt,
  };
}

/** The context snapshot stays server-side; the app only needs the bubble. */
function serializeMessage(m: MessageRow, actions: ActionRow[] = []) {
  return {
    id: m.id,
    role: m.role,
    content: m.content,
    createdAt: m.createdAt,
    actions: actions.map(serializeAction),
  };
}

app.get('/conversations/:id/messages', async (c) => {
  const db = c.get('db');
  const conversation = await ownedConversation(db, c.get('user').id, c.req.param('id'));

  const [rows, actions] = await Promise.all([
    db.select().from(coachMessages)
      .where(eq(coachMessages.conversationId, conversation.id))
      .orderBy(asc(coachMessages.id)),
    db.select().from(coachActions)
      .where(eq(coachActions.conversationId, conversation.id))
      .orderBy(asc(coachActions.createdAt)),
  ]);

  const byMessage = new Map<number, ActionRow[]>();
  for (const a of actions) {
    if (a.messageId == null) continue;
    byMessage.set(a.messageId, [...(byMessage.get(a.messageId) ?? []), a]);
  }
  return c.json({ items: rows.map((m) => serializeMessage(m, byMessage.get(m.id))) });
});

/* ------------------------------------------------------------- the agent */

/**
 * Per-user limits on assistant messages. Every message costs 2+ model calls
 * (guard + agent rounds), so this is the cost ceiling as much as abuse control.
 * Counted from stored user messages — archived threads included.
 */
async function enforceRateLimit(db: Db, env: AppEnv['Bindings'], userId: string): Promise<void> {
  const { agentRatePerMinute, agentRatePerDay } = modelConfig(env);
  const now = Date.now();
  const rows = await db.select({
    minute: sql<number>`sum(case when ${coachMessages.createdAt} > ${now - 60_000} then 1 else 0 end)`,
    day: sql<number>`count(*)`,
  }).from(coachMessages)
    .innerJoin(coachConversations, eq(coachConversations.id, coachMessages.conversationId))
    .where(and(
      eq(coachConversations.userId, userId),
      eq(coachMessages.role, 'user'),
      gte(coachMessages.createdAt, now - 86_400_000),
    ));
  const minute = Number(rows[0]?.minute ?? 0);
  const day = Number(rows[0]?.day ?? 0);
  if (minute >= agentRatePerMinute) {
    throw new ApiError('RATE_LIMITED', 'Bạn gửi hơi nhanh, đợi một phút rồi hỏi tiếp nhé.');
  }
  if (day >= agentRatePerDay) {
    throw new ApiError('RATE_LIMITED', 'Bạn đã dùng hết lượt hỏi Trợ lý AI trong 24 giờ qua.');
  }
}

function apiCaller(c: Context<AppEnv, any>): ApiCaller {
  // requireAuth has already verified this header on the way in.
  return { authorization: c.req.header('Authorization') ?? '', env: c.env, executionCtx: c.executionCtx };
}

const sendSchema = z.object({
  content: z.string().trim().min(1).max(4000),
  /** Numbers that only exist on the phone (water is not stored server-side yet). */
  device: z.object({
    waterMlToday: z.number().int().min(0).max(20000).optional(),
    waterTargetMl: z.number().int().min(0).max(20000).optional(),
  }).optional(),
});

app.post('/conversations/:id/messages', async (c) => {
  const body = await parseBody(c, sendSchema);
  const db = c.get('db');
  const user = c.get('user');
  const conversation = await ownedConversation(db, user.id, c.req.param('id'));
  await enforceRateLimit(db, c.env, user.id);
  const { chat } = modelConfig(c.env);
  const started = Date.now();

  const previous = await db.select().from(coachMessages)
    .where(eq(coachMessages.conversationId, conversation.id))
    .orderBy(desc(coachMessages.id)).limit(HISTORY_TURNS);
  const history: ChatTurn[] = previous.reverse().map((m) => ({
    role: m.role as ChatTurn['role'],
    content: m.content,
  }));

  await db.insert(coachMessages).values({
    conversationId: conversation.id,
    role: 'user',
    content: body.content,
    createdAt: started,
  });

  const turn = await runAgentTurn({
    db,
    env: c.env,
    user,
    caller: apiCaller(c),
    conversationId: conversation.id,
    history,
    message: body.content,
    device: body.device ?? {},
  });

  const now = Date.now();
  const inserted = await db.insert(coachMessages).values({
    conversationId: conversation.id,
    role: 'assistant',
    content: turn.reply,
    // What the answer was based on and how it got there, so it stays explainable.
    contextJson: JSON.stringify({
      guard: turn.guard,
      outcome: turn.outcome,
      modelCalls: turn.modelCalls,
      timings: turn.timings,
      trace: turn.trace,
      context: turn.context,
    }),
    model: chat,
    latencyMs: now - started,
    createdAt: now,
  }).returning();
  const message = inserted[0]!;

  let actions: ActionRow[] = [];
  if (turn.actionIds.length) {
    await db.update(coachActions).set({ messageId: message.id })
      .where(and(eq(coachActions.userId, user.id), inArray(coachActions.id, turn.actionIds)));
    actions = await db.select().from(coachActions)
      .where(inArray(coachActions.id, turn.actionIds))
      .orderBy(asc(coachActions.createdAt));
  }

  await db.update(coachConversations).set({
    lastMessageAt: now,
    messageCount: conversation.messageCount + 2,
    title: conversation.title ?? body.content.slice(0, 60),
    updatedAt: now,
  }).where(eq(coachConversations.id, conversation.id));

  return c.json(serializeMessage(message, actions));
});

/* ---------------------------------------------------- confirming proposals */

async function ownedPendingAction(db: Db, userId: string, id: string): Promise<ActionRow> {
  const rows = await db.select().from(coachActions)
    .where(and(eq(coachActions.id, id), eq(coachActions.userId, userId))).limit(1);
  const action = rows[0];
  if (!action) throw notFound('Action');
  if (isExpired(action)) {
    await db.update(coachActions).set({ status: 'expired', resolvedAt: Date.now() })
      .where(and(eq(coachActions.id, action.id), eq(coachActions.status, 'pending')));
    throw new ApiError('CONFLICT', 'Đề xuất này đã hết hạn, hãy nhờ Trợ lý tạo lại.');
  }
  if (action.status !== 'pending') throw new ApiError('CONFLICT', `Đề xuất đã ở trạng thái ${action.status}`);
  return action;
}

/** Moves a pending action on; false when another request got there first. */
async function claim(db: Db, id: string, status: 'confirmed' | 'cancelled'): Promise<boolean> {
  const rows = await db.update(coachActions)
    .set({ status, resolvedAt: Date.now() })
    .where(and(eq(coachActions.id, id), eq(coachActions.status, 'pending')))
    .returning({ id: coachActions.id });
  return rows.length > 0;
}

/**
 * The outcome goes into the thread as an assistant line, so the next turn's
 * history tells the model what actually happened to its proposal.
 */
async function appendOutcome(db: Db, action: ActionRow, content: string) {
  const now = Date.now();
  const inserted = await db.insert(coachMessages).values({
    conversationId: action.conversationId,
    role: 'assistant',
    content,
    createdAt: now,
  }).returning();
  await db.update(coachConversations).set({
    lastMessageAt: now,
    messageCount: sql`${coachConversations.messageCount} + 1`,
    updatedAt: now,
  }).where(eq(coachConversations.id, action.conversationId));
  return inserted[0]!;
}

app.post('/actions/:id/confirm', async (c) => {
  const db = c.get('db');
  const user = c.get('user');
  const action = await ownedPendingAction(db, user.id, c.req.param('id'));
  const tool = AGENT_TOOLS.get(action.tool);
  if (!tool || tool.kind !== 'write') throw new ApiError('INTERNAL', `Unknown action tool ${action.tool}`);
  if (!await claim(db, action.id, 'confirmed')) throw new ApiError('CONFLICT', 'Đề xuất đã được xử lý');

  let execution: Execution | null = null;
  let failure: string | null = null;
  try {
    const args = tool.args.parse(JSON.parse(action.argsJson));
    execution = await tool.execute({ caller: apiCaller(c), user, memo: new Map() }, args);
  } catch (err) {
    if (!(err instanceof ApiError || err instanceof ToolError)) console.error('assistant action failed', err);
    failure = err instanceof Error ? err.message : String(err);
  }

  await db.update(coachActions).set(failure
    ? { status: 'failed', errorMessage: failure.slice(0, 500) }
    : { resultJson: JSON.stringify(execution ?? {}) })
    .where(eq(coachActions.id, action.id));

  const message = await appendOutcome(db, action, failure
    ? `Không thực hiện được: ${action.summary}. Lý do: ${failure}`
    : `Đã thực hiện: ${action.summary}`);
  const updated = (await db.select().from(coachActions).where(eq(coachActions.id, action.id)).limit(1))[0]!;

  return c.json({
    action: serializeAction(updated),
    message: serializeMessage(message),
    clientEffect: execution?.clientEffect ?? null,
  });
});

app.post('/actions/:id/cancel', async (c) => {
  const db = c.get('db');
  const action = await ownedPendingAction(db, c.get('user').id, c.req.param('id'));
  if (!await claim(db, action.id, 'cancelled')) throw new ApiError('CONFLICT', 'Đề xuất đã được xử lý');

  const message = await appendOutcome(db, action, `Đã huỷ đề xuất: ${action.summary}`);
  const updated = (await db.select().from(coachActions).where(eq(coachActions.id, action.id)).limit(1))[0]!;
  return c.json({ action: serializeAction(updated), message: serializeMessage(message) });
});

/* --------------------------------------------------------------- insights */

app.get('/insights', async (c) => {
  const q = parseQuery(c, z.object({
    from: isoDateSchema.optional(),
    to: isoDateSchema.optional(),
    unreadOnly: z.enum(['true', 'false']).optional(),
  }));
  const filters = [eq(coachInsights.userId, c.get('user').id)];
  if (q.from) filters.push(gte(coachInsights.localDate, q.from));
  if (q.to) filters.push(lte(coachInsights.localDate, q.to));
  if (q.unreadOnly === 'true') filters.push(eq(coachInsights.isRead, false));

  const rows = await c.get('db').select().from(coachInsights)
    .where(and(...filters)).orderBy(desc(coachInsights.localDate), desc(coachInsights.id));
  return c.json({ items: rows });
});

app.post('/insights/:id/read', async (c) => {
  await c.get('db').update(coachInsights).set({ isRead: true }).where(and(
    eq(coachInsights.id, c.req.param('id')),
    eq(coachInsights.userId, c.get('user').id),
  ));
  return c.body(null, 204);
});

export default app;
