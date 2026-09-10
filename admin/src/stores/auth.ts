import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import { api, ApiError } from '@/lib/api'
import { clearTokens, getRefreshToken, hasSession, setTokens } from '@/lib/session'
import type { AuthUser } from '@/lib/types'

/**
 * Auth state for the panel. Tokens themselves live in `lib/session`; this store
 * only owns the signed-in identity and the "are you actually an admin" question,
 * which the API answers with 403 on any /v1/admin route.
 */
export const useAuthStore = defineStore('auth', () => {
  const user = ref<AuthUser | null>(null)
  const loading = ref(false)
  const error = ref<string | null>(null)
  /** Signed in with Google, but the account is not an admin. */
  const forbidden = ref(false)

  const isAuthenticated = computed(() => user.value !== null)
  const isAdmin = computed(() => user.value?.role === 'admin')

  async function signInWithGoogle(idToken: string): Promise<void> {
    loading.value = true
    error.value = null
    forbidden.value = false
    try {
      const res = await api.auth.google(idToken)
      setTokens(res)
      user.value = res.user
      forbidden.value = res.user.role !== 'admin'
    } catch (err) {
      error.value = err instanceof ApiError ? err.message : 'Sign-in failed'
      clearTokens()
      throw err
    } finally {
      loading.value = false
    }
  }

  /** Called once on boot: a stored refresh token should survive a reload. */
  async function restore(): Promise<void> {
    if (!hasSession()) return
    loading.value = true
    try {
      const res = await api.auth.me()
      user.value = res.user
      forbidden.value = res.user.role !== 'admin'
    } catch {
      clearTokens()
      user.value = null
    } finally {
      loading.value = false
    }
  }

  async function signOut(): Promise<void> {
    const refreshToken = getRefreshToken()
    if (refreshToken) await api.auth.logout(refreshToken).catch(() => undefined)
    clearTokens()
    user.value = null
    forbidden.value = false
  }

  return { user, loading, error, forbidden, isAuthenticated, isAdmin, signInWithGoogle, restore, signOut }
})
