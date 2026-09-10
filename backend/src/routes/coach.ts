import { Hono } from 'hono';
import { and, asc, desc, eq, gte, lte, sql } from 'drizzle-orm';
import { z } from 'zod';
import { coachConversations, coachMessages, coachInsights } from '../db/schema';
import { parseBody, parseQuery, paginationSchema, page, isoDateSchema } from '../lib/http';
import { notFound } from '../lib/errors';
import { newId } from '../lib/ids';
import { modelConfig } from '../config/models';
import { buildCoachContext, completeCoachReply, type ChatTurn } from '../services/coach';
import type { AppEnv } from '../env';

const app = new Hono<AppEnv>();

/** Only the last few turns are replayed; the context block carries the health data. */
const HISTORY_TURNS = 12;

app.get('/conversations', async (c) => {
  const q = parseQuery(c, paginationSchema);
  const filters = [eq(coachConversations.userId, c.get('user').id)];
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

async function ownedConversation(
  db: AppEnv['Variables']['db'], userId: string, id: string,
) {
  const rows = await db.select().from(coachConversations)
    .where(and(eq(coachConversations.id, id), eq(coachConversations.userId, userId)))
    .limit(1);
  const conversation = rows[0];
  if (!conversation) throw notFound('Conversation');
  return conversation;
}

app.get('/conversations/:id/messages', async (c) => {
  const db = c.get('db');
  const conversation = await ownedConversation(db, c.get('user').id, c.req.param('id'));

  const rows = await db.select().from(coachMessages)
    .where(eq(coachMessages.conversationId, conversation.id))
    .orderBy(asc(coachMessages.id));
  return c.json({ items: rows });
});

/**
 * The reply is streamed as SSE so the app can render it as it arrives; the full
 * text plus the context snapshot is persisted once the stream completes.
 */
app.post('/conversations/:id/messages', async (c) => {
  const body = await parseBody(c, z.object({ content: z.string().min(1).max(4000) }));
  const db = c.get('db');
  const user = c.get('user');
  const conversation = await ownedConversation(db, user.id, c.req.param('id'));
  const { chat } = modelConfig(c.env);
  const started = Date.now();

  await db.insert(coachMessages).values({
    conversationId: conversation.id,
    role: 'user',
    content: body.content,
    createdAt: started,
  });

  const previous = await db.select().from(coachMessages)
    .where(eq(coachMessages.conversationId, conversation.id))
    .orderBy(desc(coachMessages.id)).limit(HISTORY_TURNS);

  const history: ChatTurn[] = previous.reverse().map((m) => ({
    role: m.role as ChatTurn['role'],
    content: m.content,
  }));

  const ctx = await buildCoachContext(db, c.env, user.id, user.timezone);
  const reply = await completeCoachReply(c.env, ctx, history);

  const now = Date.now();
  await db.insert(coachMessages).values({
    conversationId: conversation.id,
    role: 'assistant',
    content: reply,
    // Snapshot of the data the answer was based on, so it stays explainable.
    contextJson: JSON.stringify(ctx),
    model: chat,
    latencyMs: now - started,
    createdAt: now,
  });

  await db.update(coachConversations).set({
    lastMessageAt: now,
    messageCount: conversation.messageCount + 2,
    title: conversation.title ?? body.content.slice(0, 60),
    updatedAt: now,
  }).where(eq(coachConversations.id, conversation.id));

  return c.json({ role: 'assistant', content: reply, model: chat });
});

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
