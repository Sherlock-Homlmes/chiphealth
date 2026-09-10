import { Hono } from 'hono';
import type { Context } from 'hono';
import { and, desc, eq, inArray, isNull, or, sql } from 'drizzle-orm';
import { z } from 'zod';
import {
  users, friendships, momentPosts, momentReactions, momentMessages, momentViews,
  mediaAssets,
} from '../db/schema';
import { parseBody, parseQuery, paginationSchema, page } from '../lib/http';
import { ApiError, notFound } from '../lib/errors';
import { newId } from '../lib/ids';
import { friendIds } from '../lib/friends';
import type { AppEnv } from '../env';

const app = new Hono<AppEnv>();

app.get('/friends', async (c) => {
  const db = c.get('db');
  const ids = await friendIds(db, c.get('user').id);
  if (ids.length === 0) return c.json({ items: [] });

  const rows = await db.select({
    id: users.id,
    displayName: users.displayName,
    email: users.email,
    avatarAssetId: users.avatarAssetId,
    avatarRemoteUrl: users.avatarRemoteUrl,
  }).from(users).where(inArray(users.id, ids));

  return c.json({ items: rows });
});

app.get('/friends/requests', async (c) => {
  const db = c.get('db');
  const userId = c.get('user').id;

  const [incoming, outgoing] = await Promise.all([
    db.select().from(friendships).where(and(
      eq(friendships.addresseeId, userId), eq(friendships.status, 'pending'),
    )),
    db.select().from(friendships).where(and(
      eq(friendships.requesterId, userId), eq(friendships.status, 'pending'),
    )),
  ]);

  return c.json({ incoming, outgoing });
});

app.post('/friends/requests', async (c) => {
  const body = await parseBody(c, z.object({
    email: z.string().email().optional(),
    userId: z.string().uuid().optional(),
  }).refine((v) => v.email ?? v.userId, { message: 'email or userId is required' }));

  const db = c.get('db');
  const me = c.get('user').id;

  const targetRows = body.userId
    ? await db.select().from(users).where(eq(users.id, body.userId)).limit(1)
    : await db.select().from(users).where(eq(users.email, body.email!)).limit(1);

  const target = targetRows[0];
  if (!target || target.deletedAt) throw notFound('User');
  if (target.id === me) throw new ApiError('VALIDATION_ERROR', 'Cannot befriend yourself');

  // The relationship is undirected, so an existing row in EITHER direction wins;
  // only checking the outgoing one lets a pair end up with two mirrored rows.
  const existing = await db.select().from(friendships).where(or(
    and(eq(friendships.requesterId, me), eq(friendships.addresseeId, target.id)),
    and(eq(friendships.requesterId, target.id), eq(friendships.addresseeId, me)),
  )).limit(1);

  const prior = existing[0];
  if (prior) {
    if (prior.status === 'blocked') throw new ApiError('CONFLICT', 'Blocked');
    // They asked first: accepting their pending request is the natural resolution.
    if (prior.status === 'pending' && prior.addresseeId === me) {
      await db.update(friendships)
        .set({ status: 'accepted', respondedAt: Date.now() })
        .where(eq(friendships.id, prior.id));
      return c.json({ ...prior, status: 'accepted' });
    }
    return c.json(prior);
  }

  const id = newId();
  await db.insert(friendships).values({
    id,
    requesterId: me,
    addresseeId: target.id,
    status: 'pending',
    requestedAt: Date.now(),
  }).onConflictDoNothing();

  const rows = await db.select().from(friendships)
    .where(eq(friendships.id, id)).limit(1);
  return c.json(rows[0], 201);
});

async function respondToRequest(
  c: Context<AppEnv>, status: 'accepted' | 'blocked',
) {
  const db = c.get('db');
  const requestId = c.req.param('id') ?? '';
  const rows = await db.select().from(friendships).where(and(
    eq(friendships.id, requestId),
    eq(friendships.addresseeId, c.get('user').id),
    eq(friendships.status, 'pending'),
  )).limit(1);

  if (!rows[0]) throw notFound('Friend request');

  await db.update(friendships).set({ status, respondedAt: Date.now() })
    .where(eq(friendships.id, rows[0].id));
  return c.json({ ...rows[0], status });
}

app.post('/friends/requests/:id/accept', (c) => respondToRequest(c, 'accepted'));
app.post('/friends/requests/:id/decline', (c) => respondToRequest(c, 'blocked'));

app.delete('/friends/:userId', async (c) => {
  const me = c.get('user').id;
  const other = c.req.param('userId');

  await c.get('db').delete(friendships).where(or(
    and(eq(friendships.requesterId, me), eq(friendships.addresseeId, other)),
    and(eq(friendships.requesterId, other), eq(friendships.addresseeId, me)),
  ));
  return c.body(null, 204);
});

// --------------------------------------------------------------- moments

app.post('/moments', async (c) => {
  const body = await parseBody(c, z.object({
    photoAssetId: z.string().uuid(),
    caption: z.string().max(200).nullish(),
    visibility: z.enum(['friends', 'public']).default('friends'),
    linkedMealLogId: z.string().uuid().nullish(),
    linkedWorkoutSessionId: z.string().uuid().nullish(),
    expiresAt: z.number().int().positive().nullish(),
  }));

  const db = c.get('db');
  const user = c.get('user');

  const asset = await db.select().from(mediaAssets).where(and(
    eq(mediaAssets.id, body.photoAssetId), eq(mediaAssets.userId, user.id),
  )).limit(1);
  if (!asset[0]) throw notFound('Photo asset');

  const id = newId();
  await db.update(mediaAssets).set({ isOrphan: false })
    .where(eq(mediaAssets.id, body.photoAssetId));

  await db.insert(momentPosts).values({
    id,
    userId: user.id,
    photoAssetId: body.photoAssetId,
    caption: body.caption ?? null,
    visibility: body.visibility,
    linkedMealLogId: body.linkedMealLogId ?? null,
    linkedWorkoutSessionId: body.linkedWorkoutSessionId ?? null,
    expiresAt: body.expiresAt ?? null,
    createdAt: Date.now(),
  });

  const rows = await db.select().from(momentPosts).where(eq(momentPosts.id, id)).limit(1);
  return c.json(rows[0], 201);
});

app.get('/moments/feed', async (c) => {
  const q = parseQuery(c, paginationSchema);
  const db = c.get('db');
  const me = c.get('user').id;

  const ids = [...(await friendIds(db, me)), me];
  const filters = [
    inArray(momentPosts.userId, ids),
    isNull(momentPosts.deletedAt),
  ];
  if (q.cursor) filters.push(sql`${momentPosts.id} < ${q.cursor}`);

  // Joined rather than raw rows: the feed renders "who posted this" under every
  // photo, and without the join every moment reads as the viewer's own.
  const rows = await db.select({
    id: momentPosts.id,
    userId: momentPosts.userId,
    photoAssetId: momentPosts.photoAssetId,
    caption: momentPosts.caption,
    visibility: momentPosts.visibility,
    createdAt: momentPosts.createdAt,
    authorName: users.displayName,
    authorAvatarUrl: users.avatarRemoteUrl,
    // Null until this viewer has actually looked at the moment. Home shows
    // only what is new, so the flag has to ride along with the feed rather
    // than cost a second request.
    viewedAt: momentViews.viewedAt,
  }).from(momentPosts)
    .innerJoin(users, eq(momentPosts.userId, users.id))
    .leftJoin(momentViews, and(
      eq(momentViews.momentPostId, momentPosts.id),
      eq(momentViews.viewerId, me),
    ))
    .where(and(...filters)).orderBy(desc(momentPosts.id)).limit(q.limit + 1);

  return c.json(page(rows, q.limit));
});

/** Home-screen widget: the newest unseen moment per friend, minimal payload. */
app.get('/moments/widget', async (c) => {
  const db = c.get('db');
  const me = c.get('user').id;
  const ids = await friendIds(db, me);
  if (ids.length === 0) return c.json({ items: [] });

  const rows = await db.select({
    id: momentPosts.id,
    userId: momentPosts.userId,
    photoAssetId: momentPosts.photoAssetId,
    caption: momentPosts.caption,
    createdAt: momentPosts.createdAt,
    authorName: users.displayName,
    viewedAt: momentViews.viewedAt,
  }).from(momentPosts)
    .innerJoin(users, eq(momentPosts.userId, users.id))
    .leftJoin(momentViews, and(
      eq(momentViews.momentPostId, momentPosts.id),
      eq(momentViews.viewerId, me),
    ))
    .where(and(
      inArray(momentPosts.userId, ids),
      isNull(momentPosts.deletedAt),
      isNull(momentViews.viewedAt),
    ))
    .orderBy(desc(momentPosts.id))
    .limit(50);

  // One row per author: the newest unseen post wins.
  const seen = new Set<string>();
  const items = rows.filter((r) => {
    if (seen.has(r.userId)) return false;
    seen.add(r.userId);
    return true;
  });

  c.header('Cache-Control', 'private, max-age=60');
  return c.json({ items });
});

/** Author, public, or accepted friend — enforced server-side, never in the client. */
async function visibleMoment(
  db: AppEnv['Variables']['db'], viewerId: string, postId: string,
) {
  const rows = await db.select().from(momentPosts)
    .where(and(eq(momentPosts.id, postId), isNull(momentPosts.deletedAt))).limit(1);
  const post = rows[0];
  if (!post) throw notFound('Moment');

  if (post.userId === viewerId || post.visibility === 'public') return post;

  const ids = await friendIds(db, viewerId);
  if (!ids.includes(post.userId)) throw notFound('Moment');
  return post;
}

app.post('/moments/:id/view', async (c) => {
  const db = c.get('db');
  const me = c.get('user').id;
  const post = await visibleMoment(db, me, c.req.param('id'));

  await db.insert(momentViews).values({
    momentPostId: post.id, viewerId: me, viewedAt: Date.now(),
  }).onConflictDoNothing();
  return c.body(null, 204);
});

app.post('/moments/:id/react', async (c) => {
  const body = await parseBody(c, z.object({ emoji: z.string().min(1).max(16) }));
  const db = c.get('db');
  const me = c.get('user').id;
  const post = await visibleMoment(db, me, c.req.param('id'));
  const now = Date.now();

  // What is on the moment already: tapping the same emoji twice should not
  // post the same message twice.
  const previous = await db.select({ emoji: momentReactions.emoji })
    .from(momentReactions)
    .where(and(
      eq(momentReactions.momentPostId, post.id),
      eq(momentReactions.userId, me),
    )).limit(1);

  await db.insert(momentReactions).values({
    momentPostId: post.id, userId: me, emoji: body.emoji, createdAt: now,
  }).onConflictDoUpdate({
    target: [momentReactions.momentPostId, momentReactions.userId],
    set: { emoji: body.emoji, createdAt: now },
  });

  // A reaction is something the author should read, so it lands in the
  // conversation like any other message — the way Instagram delivers a reply
  // to a story. Reacting to your own moment writes to your own thread, exactly
  // as answering it in text does; anything else makes the two paths disagree.
  const changed = previous[0]?.emoji !== body.emoji;
  if (changed) {
    await sendMessage(db, {
      senderId: me,
      recipientId: post.userId,
      momentPostId: post.id,
      kind: 'reaction',
      body: body.emoji,
    });
  }

  return c.json({ momentPostId: post.id, emoji: body.emoji, messaged: changed }, 201);
});

/* -------------------------------------------------------------------------- */
/* Messages — direct, between two friends                                       */
/* -------------------------------------------------------------------------- */

const messageColumns = {
  id: momentMessages.id,
  senderId: momentMessages.senderId,
  recipientId: momentMessages.recipientId,
  momentPostId: momentMessages.momentPostId,
  kind: momentMessages.kind,
  body: momentMessages.body,
  createdAt: momentMessages.createdAt,
  readAt: momentMessages.readAt,
};

/** Everything sent either way between two people. */
const betweenUsers = (me: string, other: string) => or(
  and(eq(momentMessages.senderId, me), eq(momentMessages.recipientId, other)),
  and(eq(momentMessages.senderId, other), eq(momentMessages.recipientId, me)),
);

async function sendMessage(
  db: AppEnv['Variables']['db'],
  message: {
    senderId: string; recipientId: string; body: string;
    momentPostId?: string | null; kind?: 'text' | 'reaction';
  },
) {
  const row = {
    id: newId(),
    senderId: message.senderId,
    recipientId: message.recipientId,
    momentPostId: message.momentPostId ?? null,
    kind: message.kind ?? 'text' as const,
    body: message.body,
    createdAt: Date.now(),
    // A message to yourself — answering your own moment — is already read.
    readAt: message.senderId === message.recipientId ? Date.now() : null,
  };
  await db.insert(momentMessages).values(row);
  return row;
}

/** Answering a photo: an ordinary message that pins the moment it answers. */
app.post('/moments/:id/messages', async (c) => {
  const body = await parseBody(c, z.object({ body: z.string().trim().min(1).max(500) }));
  const db = c.get('db');
  const me = c.get('user').id;
  const post = await visibleMoment(db, me, c.req.param('id'));

  const row = await sendMessage(db, {
    senderId: me,
    recipientId: post.userId,
    momentPostId: post.id,
    body: body.body,
  });
  return c.json(row, 201);
});

/**
 * The conversation list: one row per friend I have exchanged anything with,
 * carrying the last message and how many of theirs I have not read.
 */
app.get('/messages', async (c) => {
  const db = c.get('db');
  const me = c.get('user').id;

  const rows = await db.select({
    ...messageColumns,
    photoAssetId: momentPosts.photoAssetId,
  }).from(momentMessages)
    .leftJoin(momentPosts, eq(momentMessages.momentPostId, momentPosts.id))
    .where(or(eq(momentMessages.senderId, me), eq(momentMessages.recipientId, me)))
    .orderBy(desc(momentMessages.createdAt))
    .limit(500);

  // Folded here rather than in SQL: D1 has no window functions, and the
  // alternative is one query per friend.
  const byFriend = new Map<string, {
    userId: string; lastMessage: typeof rows[number]; unread: number;
  }>();
  for (const row of rows) {
    const other = row.senderId === me ? row.recipientId : row.senderId;
    const entry = byFriend.get(other)
      ?? { userId: other, lastMessage: row, unread: 0 };
    if (row.recipientId === me && row.readAt === null) entry.unread += 1;
    byFriend.set(other, entry);
  }
  if (byFriend.size === 0) return c.json({ items: [] });

  const people = await db.select({
    id: users.id,
    displayName: users.displayName,
    avatarRemoteUrl: users.avatarRemoteUrl,
  }).from(users).where(inArray(users.id, [...byFriend.keys()]));
  const person = new Map(people.map((p) => [p.id, p]));

  return c.json({
    items: [...byFriend.values()].map((entry) => ({
      userId: entry.userId,
      displayName: person.get(entry.userId)?.displayName ?? null,
      avatarRemoteUrl: person.get(entry.userId)?.avatarRemoteUrl ?? null,
      unread: entry.unread,
      lastMessage: entry.lastMessage,
    })),
  });
});

/** One conversation, oldest first — the order a chat is read in. */
app.get('/messages/:userId', async (c) => {
  const q = parseQuery(c, paginationSchema);
  const db = c.get('db');
  const me = c.get('user').id;
  const other = c.req.param('userId');

  const rows = await db.select({
    ...messageColumns,
    photoAssetId: momentPosts.photoAssetId,
    momentCaption: momentPosts.caption,
  }).from(momentMessages)
    .leftJoin(momentPosts, eq(momentMessages.momentPostId, momentPosts.id))
    .where(betweenUsers(me, other))
    .orderBy(desc(momentMessages.createdAt))
    .limit(q.limit);

  return c.json({ items: rows.reverse() });
});

app.post('/messages/:userId', async (c) => {
  const body = await parseBody(c, z.object({
    body: z.string().trim().min(1).max(500),
    momentPostId: z.string().nullish(),
  }));
  const db = c.get('db');
  const me = c.get('user').id;
  const other = c.req.param('userId');

  // Friends only, and the check is the friend list rather than the client's
  // word for it.
  const ids = await friendIds(db, me);
  if (other !== me && !ids.includes(other)) throw notFound('Friend');

  const row = await sendMessage(db, {
    senderId: me,
    recipientId: other,
    body: body.body,
    momentPostId: body.momentPostId ?? null,
  });
  return c.json(row, 201);
});

/** Opening a conversation is what clears its badge. */
app.post('/messages/:userId/read', async (c) => {
  const db = c.get('db');
  const me = c.get('user').id;

  await db.update(momentMessages).set({ readAt: Date.now() }).where(and(
    eq(momentMessages.recipientId, me),
    eq(momentMessages.senderId, c.req.param('userId')),
    isNull(momentMessages.readAt),
  ));
  return c.body(null, 204);
});

/* -------------------------------------------------------------------------- */
/* Live updates                                                                 */
/* -------------------------------------------------------------------------- */

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** How long one stream lives before the client is asked to reconnect. */
const STREAM_TTL_MS = 4 * 60 * 1000;
const STREAM_POLL_MS = 3000;

/** Messages that arrived for this viewer after `since`. */
async function newsSince(
  db: AppEnv['Variables']['db'], me: string, since: number,
) {
  return db.select({
    id: momentMessages.id,
    senderId: momentMessages.senderId,
    recipientId: momentMessages.recipientId,
    momentPostId: momentMessages.momentPostId,
    kind: momentMessages.kind,
    body: momentMessages.body,
    createdAt: momentMessages.createdAt,
    senderName: users.displayName,
    senderAvatarUrl: users.avatarRemoteUrl,
    photoAssetId: momentPosts.photoAssetId,
  }).from(momentMessages)
    .innerJoin(users, eq(momentMessages.senderId, users.id))
    .leftJoin(momentPosts, eq(momentMessages.momentPostId, momentPosts.id))
    .where(and(
      eq(momentMessages.recipientId, me),
      sql`${momentMessages.createdAt} > ${since}`,
    ))
    .orderBy(momentMessages.createdAt).limit(50);
}

/**
 * Server-sent events for incoming messages. SSE rather than a socket: the
 * traffic is one-way and rare, and a Worker holding a socket open costs a
 * Durable Object this app does not otherwise need.
 *
 * The stream polls D1 — nothing here can push — and closes itself after
 * [STREAM_TTL_MS] so a dead connection cannot linger; EventSource reconnects on
 * its own, and `since` carries the client's place forward.
 */
app.get('/moments/stream', async (c) => {
  const db = c.get('db');
  const me = c.get('user').id;
  let since = Number(c.req.query('since')) || Date.now();

  const encoder = new TextEncoder();
  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      const send = (event: string, data: unknown) => {
        controller.enqueue(encoder.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`));
      };

      send('open', { since });
      const until = Date.now() + STREAM_TTL_MS;
      try {
        while (Date.now() < until) {
          await sleep(STREAM_POLL_MS);
          const messages = await newsSince(db, me, since);
          for (const message of messages) send('message', message);

          if (messages.length > 0) {
            since = Math.max(since, ...messages.map((m) => m.createdAt));
          }
          // A comment line is a no-op to the client but keeps proxies from
          // dropping an idle connection.
          else controller.enqueue(encoder.encode(': keep-alive\n\n'));
        }
        send('bye', { since });
      } catch {
        // A disconnected client shows up as a write failure; nothing to do but
        // let the stream end.
      } finally {
        controller.close();
      }
    },
  });

  return new Response(stream, {
    headers: {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache, no-transform',
      Connection: 'keep-alive',
    },
  });
});

app.delete('/moments/:id', async (c) => {
  await c.get('db').update(momentPosts).set({ deletedAt: Date.now() }).where(and(
    eq(momentPosts.id, c.req.param('id')),
    eq(momentPosts.userId, c.get('user').id),
  ));
  return c.body(null, 204);
});

export default app;
