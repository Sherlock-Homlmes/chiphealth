/**
 * Typed client for the ChipHealth API (api_design.md).
 *
 * Handles the three conventions that matter to the admin panel:
 *   - the `{ error: { code, message, details } }` envelope, including
 *     `details.issues` from zod so a form can show the message on the field;
 *   - bearer auth with transparent refresh on 401 via /v1/auth/refresh;
 *   - cursor pagination: `{ items, nextCursor }`.
 */
import {
  clearTokens,
  getAccessToken,
  getRefreshToken,
  setTokens,
} from './session'
import type {
  ActivityType,
  ActivityTypeInput,
  AdminStats,
  AdminUser,
  ApiErrorBody,
  ApiErrorIssue,
  AuthTokens,
  BarcodeMiss,
  BarcodeMissStatus,
  Food,
  FoodInput,
  FoodListQuery,
  GoogleAuthResponse,
  ImportReport,
  KbDocument,
  KbDocumentInput,
  Page,
  ReindexAllResult,
  SearchPreview,
  Translation,
  TranslationUpsert,
  UserRole,
  WorkoutExercise,
  WorkoutExerciseInput,
} from './types'

export const API_BASE_URL = (import.meta.env.VITE_API_BASE_URL ?? '').replace(/\/+$/, '')

/* ------------------------------------------------------------ errors */

export class ApiError extends Error {
  readonly status: number
  readonly code: string
  readonly details: Record<string, unknown> | undefined
  readonly issues: ApiErrorIssue[]

  constructor(
    status: number,
    code: string,
    message: string,
    details?: Record<string, unknown>,
  ) {
    super(message)
    this.name = 'ApiError'
    this.status = status
    this.code = code
    this.details = details
    const raw = (details?.issues as ApiErrorIssue[] | undefined) ?? []
    this.issues = Array.isArray(raw) ? raw : []
  }

  /**
   * zod issues flattened to `{ fieldName: message }` so a form can drop the
   * message straight next to the offending input. Nested paths are joined
   * with `.` so `["items", 0, "name"]` -> `items.0.name`.
   */
  fieldErrors(): Record<string, string> {
    const out: Record<string, string> = {}
    for (const issue of this.issues) {
      const key = (issue.path ?? []).join('.')
      if (!key) continue
      if (!(key in out)) out[key] = issue.message
    }
    return out
  }

  get isValidation(): boolean {
    return this.code === 'VALIDATION_ERROR'
  }

  get isForbidden(): boolean {
    return this.code === 'FORBIDDEN' || this.status === 403
  }

  get isUnauthenticated(): boolean {
    return this.code === 'UNAUTHENTICATED' || this.status === 401
  }
}

function isErrorBody(value: unknown): value is ApiErrorBody {
  return (
    typeof value === 'object' &&
    value !== null &&
    'error' in value &&
    typeof (value as ApiErrorBody).error === 'object'
  )
}

/* -------------------------------------------------------- transport */

interface RequestOptions {
  method?: string
  body?: unknown
  query?: Record<string, string | number | boolean | null | undefined>
  /** skip the Authorization header + refresh dance (auth endpoints) */
  anonymous?: boolean
  signal?: AbortSignal
  /** send a FormData body untouched */
  formData?: FormData
}

function buildUrl(path: string, query?: RequestOptions['query']): string {
  const url = `${API_BASE_URL}${path}`
  if (!query) return url
  const params = new URLSearchParams()
  for (const [key, value] of Object.entries(query)) {
    if (value === undefined || value === null || value === '') continue
    params.set(key, String(value))
  }
  const qs = params.toString()
  return qs ? `${url}?${qs}` : url
}

/** Single-flight refresh: N parallel 401s must trigger exactly one refresh. */
let refreshInFlight: Promise<string | null> | null = null

async function refreshAccessToken(): Promise<string | null> {
  if (refreshInFlight) return refreshInFlight
  refreshInFlight = (async () => {
    const refreshToken = getRefreshToken()
    if (!refreshToken) return null
    try {
      const res = await fetch(buildUrl('/v1/auth/refresh'), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ refreshToken }),
      })
      if (!res.ok) {
        // The server rejected the token itself — the session really is over.
        clearTokens()
        return null
      }
      const tokens = (await res.json()) as AuthTokens
      setTokens(tokens)
      return tokens.accessToken
    } catch {
      // Network/CORS failure: the refresh token may still be perfectly valid, so
      // keep it. Discarding it here silently signs the admin out whenever the API
      // is briefly unreachable or an origin is missing from ADMIN_ORIGIN.
      return null
    } finally {
      // released on the next tick so the awaiting callers all see this result
      setTimeout(() => {
        refreshInFlight = null
      }, 0)
    }
  })()
  return refreshInFlight
}

async function parseBody(res: Response): Promise<unknown> {
  if (res.status === 204) return null
  const text = await res.text()
  if (!text) return null
  try {
    return JSON.parse(text)
  } catch {
    return text
  }
}

async function raw(path: string, options: RequestOptions, retry = true): Promise<unknown> {
  const headers: Record<string, string> = {}
  if (!options.formData && options.body !== undefined) {
    headers['Content-Type'] = 'application/json'
  }
  if (!options.anonymous) {
    const token = getAccessToken()
    if (token) headers.Authorization = `Bearer ${token}`
  }

  let res: Response
  try {
    res = await fetch(buildUrl(path, options.query), {
      method: options.method ?? 'GET',
      headers,
      body: options.formData ?? (options.body !== undefined ? JSON.stringify(options.body) : undefined),
      signal: options.signal,
    })
  } catch (err) {
    if ((err as Error)?.name === 'AbortError') throw err
    throw new ApiError(0, 'NETWORK_ERROR', `Cannot reach the API at ${API_BASE_URL || '(unset)'}.`)
  }

  if (res.status === 401 && retry && !options.anonymous) {
    const token = await refreshAccessToken()
    if (token) return raw(path, options, false)
  }

  const body = await parseBody(res)

  if (!res.ok) {
    if (isErrorBody(body)) {
      const { code, message, details } = body.error
      throw new ApiError(res.status, code || 'INTERNAL', message || res.statusText, details)
    }
    throw new ApiError(
      res.status,
      res.status === 401 ? 'UNAUTHENTICATED' : 'INTERNAL',
      typeof body === 'string' && body ? body : res.statusText || 'Request failed',
    )
  }

  return body
}

function request<T>(path: string, options: RequestOptions = {}): Promise<T> {
  return raw(path, options) as Promise<T>
}

/* ------------------------------------------------------------- API */

const listQuery = (q: FoodListQuery) => ({
  q: q.q,
  source: q.source || undefined,
  verified: q.verified === '' || q.verified === undefined ? undefined : q.verified,
  cursor: q.cursor ?? undefined,
  limit: q.limit ?? 50,
})

export const api = {
  /* -- auth -------------------------------------------------------- */
  auth: {
    google(idToken: string): Promise<GoogleAuthResponse> {
      return request('/v1/auth/google', {
        method: 'POST',
        anonymous: true,
        body: { idToken, deviceName: 'ChipHealth Admin', platform: 'web-admin' },
      })
    },
    logout(refreshToken: string): Promise<null> {
      return request('/v1/auth/logout', { method: 'POST', anonymous: true, body: { refreshToken } })
    },
    /** the panel uses /v1/me to re-hydrate the signed-in admin after a reload */
    me(): Promise<{ user: GoogleAuthResponse['user'] }> {
      return request('/v1/me')
    },
  },

  /* -- dashboard --------------------------------------------------- */
  stats(): Promise<AdminStats> {
    return request('/v1/admin/stats')
  },

  /* -- foods ------------------------------------------------------- */
  foods: {
    list(q: FoodListQuery = {}): Promise<Page<Food>> {
      return request('/v1/admin/foods', { query: listQuery(q) })
    },
    get(id: string): Promise<Food> {
      return request(`/v1/admin/foods/${encodeURIComponent(id)}`)
    },
    /** Existing product for a barcode, so a form can prefill instead of retyping. */
    byBarcode(code: string): Promise<Food> {
      return request(`/v1/admin/foods/by-barcode/${encodeURIComponent(code)}`)
    },
    create(body: FoodInput): Promise<Food> {
      return request('/v1/admin/foods', { method: 'POST', body })
    },
    update(id: string, body: Partial<FoodInput>): Promise<Food> {
      return request(`/v1/admin/foods/${encodeURIComponent(id)}`, { method: 'PATCH', body })
    },
    remove(id: string): Promise<null> {
      return request(`/v1/admin/foods/${encodeURIComponent(id)}`, { method: 'DELETE' })
    },
    verify(id: string, isVerified: boolean): Promise<Food> {
      return request(`/v1/admin/foods/${encodeURIComponent(id)}/verify`, {
        method: 'POST',
        body: { isVerified },
      })
    },
    import(payload: { format: 'csv' | 'json'; content: string }): Promise<ImportReport> {
      return request('/v1/admin/foods/import', { method: 'POST', body: payload })
    },
  },

  /* -- barcode queue ----------------------------------------------- */
  barcodeMisses: {
    list(q: { status?: BarcodeMissStatus; cursor?: string | null; limit?: number } = {}): Promise<
      Page<BarcodeMiss>
    > {
      return request('/v1/admin/barcode-misses', {
        query: { status: q.status ?? 'pending', cursor: q.cursor ?? undefined, limit: q.limit ?? 50 },
      })
    },
    resolve(id: string, food: FoodInput): Promise<{ miss: BarcodeMiss; food: Food }> {
      return request(`/v1/admin/barcode-misses/${encodeURIComponent(id)}/resolve`, {
        method: 'POST',
        body: food,
      })
    },
    reject(id: string, adminNote: string): Promise<BarcodeMiss> {
      return request(`/v1/admin/barcode-misses/${encodeURIComponent(id)}/reject`, {
        method: 'POST',
        body: { adminNote },
      })
    },
  },

  /* -- RAG corpus --------------------------------------------------- */
  kb: {
    list(q: { q?: string; cursor?: string | null; limit?: number } = {}): Promise<Page<KbDocument>> {
      return request('/v1/admin/kb-documents', {
        query: { q: q.q, cursor: q.cursor ?? undefined, limit: q.limit ?? 50 },
      })
    },
    get(id: string): Promise<KbDocument> {
      return request(`/v1/admin/kb-documents/${encodeURIComponent(id)}`)
    },
    create(body: KbDocumentInput): Promise<KbDocument> {
      return request('/v1/admin/kb-documents', { method: 'POST', body })
    },
    update(id: string, body: Partial<KbDocumentInput>): Promise<KbDocument> {
      return request(`/v1/admin/kb-documents/${encodeURIComponent(id)}`, { method: 'PATCH', body })
    },
    remove(id: string): Promise<null> {
      return request(`/v1/admin/kb-documents/${encodeURIComponent(id)}`, { method: 'DELETE' })
    },
    reindex(id: string): Promise<KbDocument> {
      return request(`/v1/admin/kb-documents/${encodeURIComponent(id)}/reindex`, { method: 'POST' })
    },
    reindexAll(): Promise<ReindexAllResult> {
      return request('/v1/admin/kb-documents/reindex-all', { method: 'POST' })
    },
  },

  /* -- retrieval playground ---------------------------------------- */
  searchPreview(q: string): Promise<SearchPreview> {
    return request('/v1/admin/search/preview', { method: 'POST', body: { q } })
  },

  /* -- catalogs ----------------------------------------------------- */
  activityTypes: {
    list(): Promise<Page<ActivityType>> {
      return request('/v1/admin/activity-types')
    },
    create(body: ActivityTypeInput): Promise<ActivityType> {
      return request('/v1/admin/activity-types', { method: 'POST', body })
    },
    update(id: number, body: Partial<ActivityTypeInput>): Promise<ActivityType> {
      return request(`/v1/admin/activity-types/${id}`, { method: 'PATCH', body })
    },
  },

  exercises: {
    list(): Promise<Page<WorkoutExercise>> {
      return request('/v1/admin/exercises')
    },
    create(body: WorkoutExerciseInput): Promise<WorkoutExercise> {
      return request('/v1/admin/exercises', { method: 'POST', body })
    },
    update(id: number, body: Partial<WorkoutExerciseInput>): Promise<WorkoutExercise> {
      return request(`/v1/admin/exercises/${id}`, { method: 'PATCH', body })
    },
  },

  /* -- translations -------------------------------------------------- */
  translations: {
    list(entityType: string, entityId: string): Promise<{ items: Translation[] }> {
      return request('/v1/admin/translations', { query: { entityType, entityId } })
    },
    put(
      entityType: string,
      entityId: string,
      translations: TranslationUpsert[],
    ): Promise<{ items: Translation[] }> {
      return request('/v1/admin/translations', {
        method: 'PUT',
        query: { entityType, entityId },
        body: { translations },
      })
    },
  },

  /* -- users --------------------------------------------------------- */
  users: {
    list(q: { q?: string; cursor?: string | null; limit?: number } = {}): Promise<Page<AdminUser>> {
      return request('/v1/admin/users', {
        query: { q: q.q, cursor: q.cursor ?? undefined, limit: q.limit ?? 50 },
      })
    },
    setRole(id: string, role: UserRole): Promise<AdminUser> {
      return request(`/v1/admin/users/${encodeURIComponent(id)}/role`, {
        method: 'PATCH',
        body: { role },
      })
    },
  },
}

/** `{ field: message }` for any thrown value; empty when it is not a validation error. */
export function fieldIssues(err: unknown): Record<string, string> {
  return err instanceof ApiError ? err.fieldErrors() : {}
}

/** Human text for any thrown value, for toasts and error panels. */
export function errorMessage(err: unknown): string {
  if (err instanceof ApiError) return err.message
  if (err instanceof Error) return err.message
  return String(err)
}
