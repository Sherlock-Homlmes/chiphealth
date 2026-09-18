import type { Context, Hono } from 'hono';
import { ApiError, type ErrorCode } from './errors';
import type { AppEnv, Bindings } from '../env';

/**
 * The assistant's tools reach the user's data through the same public API the
 * app uses, dispatched in-process with the caller's own bearer token. Every
 * ownership check, validation rule and day re-sum therefore applies to the
 * agent exactly as it does to the app — there is no second write path to keep
 * in step, and no way for a tool to touch another user's rows.
 *
 * The root app registers itself here (src/index.ts) rather than being imported,
 * which would be an import cycle through the coach route.
 */
let root: Hono<AppEnv> | null = null;

export function registerRootApp(app: Hono<AppEnv>): void {
  root = app;
}

export interface ApiCaller {
  authorization: string;
  env: Bindings;
  executionCtx: Context['executionCtx'];
}

export async function callApi<T = unknown>(
  caller: ApiCaller,
  method: 'GET' | 'POST' | 'PATCH' | 'PUT' | 'DELETE',
  path: string,
  body?: unknown,
): Promise<T> {
  if (!root) throw new Error('Root app not registered for internal API calls');
  const res = await root.request(`http://internal${path}`, {
    method,
    headers: { Authorization: caller.authorization, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  }, caller.env, caller.executionCtx);

  if (res.status === 204) return null as T;
  const json = await res.json().catch(() => null) as
    { error?: { code?: string; message?: string; details?: unknown } } | null;
  if (!res.ok) {
    throw new ApiError(
      (json?.error?.code ?? 'INTERNAL') as ErrorCode,
      json?.error?.message ?? `HTTP ${res.status}`,
      json?.error?.details,
    );
  }
  return json as T;
}
