/**
 * Raw token storage, deliberately outside Pinia so `api.ts` can read and rotate
 * tokens without importing a store (and creating a cycle).
 *
 * Access token: memory only — it dies with the tab, which is what we want.
 * Refresh token: localStorage, so a reload does not bounce the admin to login.
 */
import type { AuthTokens } from './types'

const REFRESH_KEY = 'chiphealth.admin.refreshToken'

let accessToken: string | null = null
let expiresAt = 0

type Listener = () => void
const listeners = new Set<Listener>()

function emit() {
  for (const fn of listeners) fn()
}

export function onSessionChange(fn: Listener): () => void {
  listeners.add(fn)
  return () => listeners.delete(fn)
}

export function getAccessToken(): string | null {
  return accessToken
}

export function getExpiresAt(): number {
  return expiresAt
}

export function getRefreshToken(): string | null {
  try {
    return localStorage.getItem(REFRESH_KEY)
  } catch {
    return null
  }
}

export function setTokens(tokens: AuthTokens): void {
  accessToken = tokens.accessToken
  expiresAt = tokens.expiresAt
  try {
    localStorage.setItem(REFRESH_KEY, tokens.refreshToken)
  } catch {
    /* private mode — the session just will not survive a reload */
  }
  emit()
}

export function clearTokens(): void {
  accessToken = null
  expiresAt = 0
  try {
    localStorage.removeItem(REFRESH_KEY)
  } catch {
    /* ignore */
  }
  emit()
}

export function hasSession(): boolean {
  return accessToken !== null || getRefreshToken() !== null
}
