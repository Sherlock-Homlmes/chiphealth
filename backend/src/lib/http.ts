import type { Context } from 'hono';
import { z } from 'zod';
import { ApiError } from './errors';

/** Parse JSON body with zod; throws a uniform VALIDATION_ERROR. */
export async function parseBody<T extends z.ZodTypeAny>(
  c: Context, schema: T,
): Promise<z.infer<T>> {
  let raw: unknown;
  try {
    raw = await c.req.json();
  } catch {
    throw new ApiError('VALIDATION_ERROR', 'Body must be valid JSON');
  }
  const result = schema.safeParse(raw);
  if (!result.success) {
    throw new ApiError('VALIDATION_ERROR', 'Invalid request body', {
      issues: result.error.issues,
    });
  }
  return result.data;
}

/** Parse query params with zod. */
export function parseQuery<T extends z.ZodTypeAny>(c: Context, schema: T): z.infer<T> {
  const result = schema.safeParse(c.req.query());
  if (!result.success) {
    throw new ApiError('VALIDATION_ERROR', 'Invalid query parameters', {
      issues: result.error.issues,
    });
  }
  return result.data;
}

export const paginationSchema = z.object({
  limit: z.coerce.number().int().min(1).max(200).default(50),
  cursor: z.string().optional(),
});

/** Cursor page envelope. Cursor is the last row id — UUIDv7 sorts chronologically. */
export function page<T extends { id: string | number }>(items: T[], limit: number) {
  const hasMore = items.length > limit;
  const slice = hasMore ? items.slice(0, limit) : items;
  const last = slice[slice.length - 1];
  return {
    items: slice,
    nextCursor: hasMore && last ? String(last.id) : null,
  };
}

export const isoDateSchema = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Expected YYYY-MM-DD');
