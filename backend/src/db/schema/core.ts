import { sqliteTable, text, integer, index, uniqueIndex, check } from 'drizzle-orm/sqlite-core';
import { sql } from 'drizzle-orm';
import { pkUuid, ts, tsNow, bool } from './_shared';

export const USER_ROLES = ['user', 'admin'] as const;
export const UNIT_SYSTEMS = ['metric', 'imperial'] as const;
export const MEDIA_KINDS = [
  'meal_photo', 'moment_photo', 'avatar', 'sleep_audio_clip', 'workout_stream',
] as const;

/**
 * users and media_assets reference each other (avatar), so they live in one
 * module to keep the FK callbacks out of a circular import.
 */
export const users = sqliteTable('users', {
  id: pkUuid(),
  googleSub: text('google_sub').notNull().unique(),
  email: text('email').notNull().unique(),
  emailVerified: bool('email_verified', true),
  displayName: text('display_name'),
  avatarAssetId: text('avatar_asset_id').references((): any => mediaAssets.id),
  avatarRemoteUrl: text('avatar_remote_url'),
  role: text('role', { enum: USER_ROLES }).notNull().default('user'),
  locale: text('locale').notNull().default('vi'),
  unitSystem: text('unit_system', { enum: UNIT_SYSTEMS }).notNull().default('metric'),
  timezone: text('timezone').notNull().default('Asia/Ho_Chi_Minh'),
  createdAt: tsNow('created_at'),
  updatedAt: tsNow('updated_at'),
  deletedAt: ts('deleted_at'),
}, (t) => [
  check('users_role_ck', sql`${t.role} in ('user','admin')`),
  check('users_unit_ck', sql`${t.unitSystem} in ('metric','imperial')`),
]);

export const mediaAssets = sqliteTable('media_assets', {
  id: pkUuid(),
  userId: text('user_id').references((): any => users.id),
  kind: text('kind', { enum: MEDIA_KINDS }).notNull(),
  r2Bucket: text('r2_bucket').notNull(),
  r2Key: text('r2_key').notNull().unique(),
  mimeType: text('mime_type').notNull(),
  byteSize: integer('byte_size'),
  width: integer('width'),
  height: integer('height'),
  durationMs: integer('duration_ms'),
  checksumSha256: text('checksum_sha256'),
  /** 1 until a domain row references it; the sweeper deletes stale orphans. */
  isOrphan: bool('is_orphan', true),
  createdAt: tsNow('created_at'),
}, (t) => [
  index('media_assets_orphan_idx').on(t.isOrphan, t.createdAt),
  check('media_assets_kind_ck',
    sql`${t.kind} in ('meal_photo','moment_photo','avatar','sleep_audio_clip','workout_stream')`),
]);

export const authSessions = sqliteTable('auth_sessions', {
  id: pkUuid(),
  userId: text('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  /** SHA-256 of the opaque refresh token — plaintext is never stored. */
  refreshTokenHash: text('refresh_token_hash').notNull().unique(),
  deviceName: text('device_name'),
  platform: text('platform'),
  appVersion: text('app_version'),
  ipAddress: text('ip_address'),
  expiresAt: integer('expires_at').notNull(),
  revokedAt: ts('revoked_at'),
  lastUsedAt: ts('last_used_at'),
  createdAt: tsNow('created_at'),
}, (t) => [
  index('auth_sessions_user_idx').on(t.userId),
]);

export const pushTokens = sqliteTable('push_tokens', {
  id: pkUuid(),
  userId: text('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  token: text('token').notNull().unique(),
  platform: text('platform').notNull(),
  isActive: bool('is_active', true),
  createdAt: tsNow('created_at'),
  updatedAt: tsNow('updated_at'),
}, (t) => [
  index('push_tokens_user_active_idx').on(t.userId, t.isActive),
]);
