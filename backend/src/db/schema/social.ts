import { sqliteTable, text, integer, index, uniqueIndex, check } from 'drizzle-orm/sqlite-core';
import { sql } from 'drizzle-orm';
import { pkUuid, ts, tsNow } from './_shared';
import { users, mediaAssets } from './core';
import { mealLogs } from './nutrition';
import { workoutSessions } from './training';

export const FRIENDSHIP_STATUSES = ['pending', 'accepted', 'blocked'] as const;
export const MOMENT_VISIBILITIES = ['friends', 'public'] as const;

/** Request/accept model. The friend list is a UNION of both directions. */
export const friendships = sqliteTable('friendships', {
  id: pkUuid(),
  requesterId: text('requester_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  addresseeId: text('addressee_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  status: text('status', { enum: FRIENDSHIP_STATUSES }).notNull().default('pending'),
  requestedAt: tsNow('requested_at'),
  respondedAt: ts('responded_at'),
}, (t) => [
  uniqueIndex('friendships_uq').on(t.requesterId, t.addresseeId),
  index('friendships_addressee_idx').on(t.addresseeId, t.status),
  check('friendships_status_ck', sql`${t.status} in ('pending','accepted','blocked')`),
]);

/** Locket-style photo. The meal/workout links are optional. */
export const momentPosts = sqliteTable('moment_posts', {
  id: pkUuid(),
  userId: text('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  photoAssetId: text('photo_asset_id').notNull().references(() => mediaAssets.id),
  caption: text('caption'),
  visibility: text('visibility', { enum: MOMENT_VISIBILITIES }).notNull().default('friends'),
  linkedMealLogId: text('linked_meal_log_id').references(() => mealLogs.id),
  linkedWorkoutSessionId: text('linked_workout_session_id').references(() => workoutSessions.id),
  expiresAt: ts('expires_at'),
  createdAt: tsNow('created_at'),
  deletedAt: ts('deleted_at'),
}, (t) => [
  index('moment_posts_user_created_idx').on(t.userId, t.createdAt),
]);

export const momentReactions = sqliteTable('moment_reactions', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  momentPostId: text('moment_post_id').notNull()
    .references(() => momentPosts.id, { onDelete: 'cascade' }),
  userId: text('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  emoji: text('emoji').notNull(),
  createdAt: tsNow('created_at'),
}, (t) => [
  uniqueIndex('moment_reactions_uq').on(t.momentPostId, t.userId),
]);

export const MESSAGE_KINDS = ['text', 'reaction'] as const;

/**
 * A direct message between two friends — Instagram-shaped, not a comment
 * thread. Answering a photo is an ordinary message that pins the moment it
 * answers (`momentPostId`), and a reaction is a message too, so everything a
 * friend sends shows up in one conversation.
 *
 * `readAt` is the recipient's, so the badge needs no second table.
 */
export const momentMessages = sqliteTable('moment_messages', {
  id: pkUuid(),
  senderId: text('sender_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  recipientId: text('recipient_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  // Null for a plain message; the moment being answered otherwise. Set null on
  // delete: losing the photo must not take the conversation with it.
  momentPostId: text('moment_post_id')
    .references(() => momentPosts.id, { onDelete: 'set null' }),
  kind: text('kind', { enum: MESSAGE_KINDS }).notNull().default('text'),
  body: text('body').notNull(),
  createdAt: tsNow('created_at'),
  readAt: ts('read_at'),
}, (t) => [
  index('moment_messages_pair_idx').on(t.senderId, t.recipientId, t.createdAt),
  index('moment_messages_inbox_idx').on(t.recipientId, t.createdAt),
]);

/** Powers "seen by" and the unseen-moments anti-join for the widget. */
export const momentViews = sqliteTable('moment_views', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  momentPostId: text('moment_post_id').notNull()
    .references(() => momentPosts.id, { onDelete: 'cascade' }),
  viewerId: text('viewer_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  viewedAt: integer('viewed_at').notNull(),
}, (t) => [
  uniqueIndex('moment_views_uq').on(t.momentPostId, t.viewerId),
]);
