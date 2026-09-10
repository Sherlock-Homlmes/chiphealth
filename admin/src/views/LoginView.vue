<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import UiButton from '@/components/UiButton.vue'
import { useAuthStore } from '@/stores/auth'

const auth = useAuthStore()
const router = useRouter()
const route = useRoute()

const useMock = import.meta.env.VITE_USE_MSW === 'true'
const clientId = import.meta.env.VITE_GOOGLE_CLIENT_ID as string | undefined
const gsiReady = ref(false)
const buttonHost = ref<HTMLElement | null>(null)

function nextRoute(): string {
  const next = route.query.next
  return typeof next === 'string' ? next : '/'
}

async function handleCredential(idToken: string) {
  try {
    await auth.signInWithGoogle(idToken)
    void router.replace(nextRoute())
  } catch {
    /* auth.error is rendered below */
  }
}

/**
 * Google Identity Services is loaded on demand so the panel still boots (and the
 * mock sign-in still works) when the script is blocked or no client id is set.
 */
onMounted(() => {
  if (useMock || !clientId) return

  const script = document.createElement('script')
  script.src = 'https://accounts.google.com/gsi/client'
  script.async = true
  script.onload = () => {
    const google = (window as unknown as { google?: any }).google
    if (!google?.accounts?.id || !buttonHost.value) return
    google.accounts.id.initialize({
      client_id: clientId,
      callback: (res: { credential: string }) => void handleCredential(res.credential),
    })
    google.accounts.id.renderButton(buttonHost.value, { theme: 'outline', size: 'large', width: 280 })
    gsiReady.value = true
  }
  document.head.appendChild(script)
})
</script>

<template>
  <div class="flex min-h-dvh items-center justify-center p-6">
    <div class="w-full max-w-sm border-2 border-rule bg-paper-raised p-6 shadow-hard-lg">
      <h1 class="text-xl font-semibold tracking-tight">ChipHealth</h1>
      <p class="mb-6 font-mono text-[11px] text-ink-faint">bảng quản trị</p>

      <p v-if="auth.error" class="mb-4 border-2 border-accent bg-accent-soft px-3 py-2 text-[13px] text-accent">
        {{ auth.error }}
      </p>

      <template v-if="useMock">
        <UiButton variant="primary" class="w-full" :loading="auth.loading" @click="handleCredential('mock-id-token')">
          Đăng nhập bằng tài khoản giả lập
        </UiButton>
        <p class="mt-3 text-[12px] text-ink-faint">VITE_USE_MSW=true — dữ liệu là fixture trong bộ nhớ.</p>
      </template>

      <template v-else-if="!clientId">
        <p class="border-2 border-warn bg-warn-soft px-3 py-2 text-[13px] text-warn">
          Chưa đặt <code class="font-mono">VITE_GOOGLE_CLIENT_ID</code> trong <code class="font-mono">.env</code>.
        </p>
      </template>

      <template v-else>
        <div ref="buttonHost" class="flex justify-center" />
        <p v-if="!gsiReady" class="mt-3 text-[12px] text-ink-faint">Đang tải Google Sign-In…</p>
      </template>
    </div>
  </div>
</template>
