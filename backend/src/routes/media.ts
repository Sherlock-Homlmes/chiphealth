import { Hono } from 'hono';
import type { Context } from 'hono';
import { and, eq, isNull } from 'drizzle-orm';
import { z } from 'zod';
import { mediaAssets, momentPosts } from '../db/schema';
import { parseBody } from '../lib/http';
import { ApiError, notFound } from '../lib/errors';
import { newId } from '../lib/ids';
import { friendIds } from '../lib/friends';
import type { AppEnv, Bindings } from '../env';

const app = new Hono<AppEnv>();

const KINDS = ['meal_photo', 'moment_photo', 'avatar', 'sleep_audio_clip', 'workout_stream'] as const;
type Kind = typeof KINDS[number];

const IMAGE_MIMES = ['image/jpeg', 'image/png', 'image/webp', 'image/heic'];
const AUDIO_MIMES = ['audio/mpeg', 'audio/mp4', 'audio/aac', 'audio/wav', 'audio/webm'];
const STREAM_MIMES = ['application/json', 'application/x-ndjson', 'application/gzip'];

const ALLOWED_MIMES: Record<Kind, string[]> = {
  meal_photo: IMAGE_MIMES,
  moment_photo: IMAGE_MIMES,
  avatar: IMAGE_MIMES,
  sleep_audio_clip: AUDIO_MIMES,
  workout_stream: STREAM_MIMES,
};

function maxBytesFor(kind: Kind, env: Bindings): number {
  const num = (v: string | undefined, d: number) => {
    const n = Number(v);
    return Number.isFinite(n) && n > 0 ? n : d;
  };
  switch (kind) {
    case 'sleep_audio_clip': return num(env.MAX_SLEEP_CLIP_BYTES, 2 * 1024 * 1024);
    case 'workout_stream': return 16 * 1024 * 1024;
    default: return num(env.MAX_MEAL_PHOTO_BYTES, 8 * 1024 * 1024);
  }
}

const EXT: Record<string, string> = {
  'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'image/heic': 'heic',
  'audio/mpeg': 'mp3', 'audio/mp4': 'm4a', 'audio/aac': 'aac', 'audio/wav': 'wav',
  'audio/webm': 'weba', 'application/json': 'json', 'application/x-ndjson': 'ndjson',
  'application/gzip': 'gz',
};

const FOLDER: Record<Kind, string> = {
  meal_photo: 'meals',
  moment_photo: 'moments',
  avatar: 'avatars',
  sleep_audio_clip: 'sleep',
  workout_stream: 'streams',
};

const uploadUrlSchema = z.object({
  kind: z.enum(KINDS),
  mimeType: z.string().min(1),
  byteSize: z.number().int().positive(),
});

/**
 * R2 bindings expose no presigned-URL API inside a Worker, so the upload target
 * is our own route (`PUT /v1/media/:id/content`), authorised by the caller's
 * bearer token and asset ownership. Same round-trip count as a presigned PUT.
 */
app.post('/upload-url', async (c) => {
  const body = await parseBody(c, uploadUrlSchema);
  const user = c.get('user');

  const allowed = ALLOWED_MIMES[body.kind];
  if (!allowed.includes(body.mimeType)) {
    throw new ApiError('VALIDATION_ERROR', `mimeType not allowed for ${body.kind}`, { allowed });
  }
  const maxBytes = maxBytesFor(body.kind, c.env);
  if (body.byteSize > maxBytes) {
    throw new ApiError('UPLOAD_TOO_LARGE', `Max ${maxBytes} bytes for ${body.kind}`);
  }

  const id = newId();
  const ext = EXT[body.mimeType] ?? 'bin';
  const key = `${FOLDER[body.kind]}/${user.id}/${id}.${ext}`;
  const ttl = Number(c.env.UPLOAD_URL_TTL_SECONDS ?? 900);

  await c.get('db').insert(mediaAssets).values({
    id,
    userId: user.id,
    kind: body.kind,
    r2Bucket: c.env.R2_BUCKET_NAME ?? 'chiphealth-media',
    r2Key: key,
    mimeType: body.mimeType,
    byteSize: body.byteSize,
    isOrphan: true,
    createdAt: Date.now(),
  });

  return c.json({
    assetId: id,
    uploadUrl: `${c.env.API_BASE_URL}/v1/media/${id}/content`,
    uploadMethod: 'PUT',
    expiresAt: Date.now() + ttl * 1000,
  }, 201);
});

async function ownedAsset(c: Context<AppEnv>, id: string) {
  const rows = await c.get('db').select().from(mediaAssets)
    .where(and(eq(mediaAssets.id, id), eq(mediaAssets.userId, c.get('user').id)))
    .limit(1);
  const asset = rows[0];
  if (!asset) throw notFound('Asset');
  return asset;
}

/**
 * Magic bytes for the image types we accept. A client that sends the wrong
 * thing — a JSON error page, a text body, a HEIC renamed to .jpg — otherwise
 * only finds out when the photo renders as a broken tile days later, so the
 * check happens here, at the one point that can still refuse the write.
 */
function sniffImage(bytes: Uint8Array): string | null {
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return 'image/jpeg';
  }
  if (bytes.length >= 8 && bytes[0] === 0x89 && bytes[1] === 0x50
      && bytes[2] === 0x4e && bytes[3] === 0x47) {
    return 'image/png';
  }
  const ascii = (at: number, text: string) => text.split('')
    .every((ch, i) => bytes[at + i] === ch.charCodeAt(0));
  if (bytes.length >= 12 && ascii(0, 'RIFF') && ascii(8, 'WEBP')) return 'image/webp';
  if (bytes.length >= 12 && ascii(4, 'ftyp')) return 'image/heic'; // heic/heif share the box
  return null;
}

app.put('/:id/content', async (c) => {
  const asset = await ownedAsset(c, c.req.param('id'));
  const maxBytes = maxBytesFor(asset.kind as Kind, c.env);

  const declared = Number(c.req.header('Content-Length') ?? 0);
  if (declared > maxBytes) {
    throw new ApiError('UPLOAD_TOO_LARGE', `Max ${maxBytes} bytes for ${asset.kind}`);
  }
  if (!c.req.raw.body) throw new ApiError('VALIDATION_ERROR', 'Empty upload body');

  // Images are buffered so the bytes can be sniffed before they reach R2, and
  // so the row records the size that actually arrived rather than the size the
  // client promised. Audio and workout streams keep streaming: they are the
  // large kinds, and nothing downstream decodes them.
  const isImage = IMAGE_MIMES.includes(asset.mimeType);
  let body: ReadableStream | Uint8Array = c.req.raw.body;
  let size: number | null = null;

  if (isImage) {
    const buffer = new Uint8Array(await c.req.arrayBuffer());
    if (buffer.byteLength === 0) throw new ApiError('VALIDATION_ERROR', 'Empty upload body');
    if (buffer.byteLength > maxBytes) {
      throw new ApiError('UPLOAD_TOO_LARGE', `Max ${maxBytes} bytes for ${asset.kind}`);
    }
    if (!sniffImage(buffer)) {
      throw new ApiError('VALIDATION_ERROR',
        'Body is not an image. Send the raw file bytes, not JSON.');
    }
    body = buffer;
    size = buffer.byteLength;
  }

  const object = await c.env.MEDIA.put(asset.r2Key, body, {
    httpMetadata: { contentType: asset.mimeType },
  });

  await c.get('db').update(mediaAssets)
    .set({ byteSize: object?.size ?? size ?? asset.byteSize })
    .where(eq(mediaAssets.id, asset.id));

  return c.json({ assetId: asset.id, byteSize: object?.size ?? size });
});

/** Adoption is only granted once the object is really in R2. */
app.post('/:id/complete', async (c) => {
  const asset = await ownedAsset(c, c.req.param('id'));
  const head = await c.env.MEDIA.head(asset.r2Key);
  if (!head) throw new ApiError('CONFLICT', 'Object has not been uploaded yet');

  await c.get('db').update(mediaAssets)
    .set({ isOrphan: false, byteSize: head.size })
    .where(eq(mediaAssets.id, asset.id));

  return c.json({ assetId: asset.id, byteSize: head.size, isOrphan: false });
});

/**
 * Reading is wider than writing: a moment photo has to be readable by everyone
 * allowed to see the post that carries it, or friends' moments render as broken
 * tiles. Ownership still gates every other kind, and every mutation below.
 */
async function readableAsset(c: Context<AppEnv>, id: string) {
  const db = c.get('db');
  const viewer = c.get('user').id;

  const rows = await db.select().from(mediaAssets).where(eq(mediaAssets.id, id)).limit(1);
  const asset = rows[0];
  if (!asset) throw notFound('Asset');
  if (asset.userId === viewer) return asset;
  if (asset.kind !== 'moment_photo') throw notFound('Asset');

  const posts = await db.select({
    userId: momentPosts.userId,
    visibility: momentPosts.visibility,
  }).from(momentPosts).where(and(
    eq(momentPosts.photoAssetId, id),
    isNull(momentPosts.deletedAt),
  ));
  if (posts.length === 0) throw notFound('Asset');
  if (posts.some((p) => p.visibility === 'public')) return asset;

  const ids = await friendIds(db, viewer);
  if (!posts.some((p) => ids.includes(p.userId))) throw notFound('Asset');
  return asset;
}

/**
 * Always served from the binding, never as a redirect to the bucket's public
 * URL. Two reasons: a public URL hands out a moment photo to anyone holding the
 * link, which throws away the visibility check above; and it only ever resolves
 * for objects that are really in the production bucket, so `wrangler dev` —
 * whose R2 is simulated locally — answered every photo with the bucket's 404
 * page, which the app then tried to decode as an image.
 */
app.get('/:id', async (c) => {
  const asset = await readableAsset(c, c.req.param('id'));

  const object = await c.env.MEDIA.get(asset.r2Key);
  if (!object) throw notFound('Object');
  return new Response(object.body, {
    headers: {
      'Content-Type': asset.mimeType,
      'Cache-Control': 'private, max-age=86400',
    },
  });
});

app.delete('/:id', async (c) => {
  const asset = await ownedAsset(c, c.req.param('id'));
  await c.env.MEDIA.delete(asset.r2Key);
  await c.get('db').delete(mediaAssets).where(eq(mediaAssets.id, asset.id));
  return c.body(null, 204);
});

export default app;
