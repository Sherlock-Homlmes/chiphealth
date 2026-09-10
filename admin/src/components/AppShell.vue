<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { RouterLink, useRoute, useRouter } from 'vue-router'
import { api } from '@/lib/api'
import { useAuthStore } from '@/stores/auth'
import UiBadge from './UiBadge.vue'
import UiButton from './UiButton.vue'

const auth = useAuthStore()
const route = useRoute()
const router = useRouter()

/** Live count on the sidebar: the barcode queue is the daily job. */
const pendingBarcodes = ref<number | null>(null)

const nav = [
  { to: '/', label: 'Tổng quan', key: 'dashboard' },
  { to: '/foods', label: 'Thực phẩm', key: 'foods' },
  { to: '/barcodes', label: 'Hàng đợi mã vạch', key: 'barcodes', badge: true },
  { to: '/kb', label: 'Kho RAG', key: 'kb' },
  { to: '/search', label: 'Thử tìm kiếm', key: 'search' },
  { to: '/catalogs', label: 'Danh mục', key: 'catalogs' },
  { to: '/translations', label: 'Dịch thuật', key: 'translations' },
  { to: '/users', label: 'Người dùng', key: 'users' },
]

onMounted(async () => {
  try {
    pendingBarcodes.value = (await api.stats()).pendingBarcodeMisses
  } catch {
    pendingBarcodes.value = null
  }
})

async function signOut() {
  await auth.signOut()
  void router.push({ name: 'login' })
}
</script>

<template>
  <!-- Not an admin: the API would 403 every screen, so say so instead. -->
  <div v-if="auth.forbidden" class="flex min-h-dvh items-center justify-center p-6">
    <div class="max-w-md border-2 border-rule bg-paper-raised p-6 shadow-hard">
      <h1 class="mb-2 text-lg font-semibold">Tài khoản này không phải admin</h1>
      <p class="mb-4 text-ink-soft">
        {{ auth.user?.email }} đăng nhập được nhưng không có quyền quản trị.
        Nhờ một admin nâng quyền, hoặc đăng nhập bằng tài khoản khác.
      </p>
      <UiButton variant="primary" @click="signOut">Đăng xuất</UiButton>
    </div>
  </div>

  <div v-else class="flex min-h-dvh">
    <aside class="flex w-56 shrink-0 flex-col border-r-2 border-rule bg-paper-raised">
      <div class="border-b-2 border-rule px-4 py-4">
        <div class="font-semibold tracking-tight">ChipHealth</div>
        <div class="font-mono text-[11px] text-ink-faint">admin</div>
      </div>

      <nav class="flex-1 p-2">
        <RouterLink
          v-for="item in nav"
          :key="item.key"
          :to="item.to"
          class="mb-1 flex items-center gap-2 border-2 px-3 py-1.5"
          :class="route.name === item.key
            ? 'border-rule bg-accent text-white shadow-hard-sm'
            : 'border-transparent text-ink-soft hover:bg-paper-sunk'"
        >
          <span class="truncate">{{ item.label }}</span>
          <UiBadge
            v-if="item.badge && pendingBarcodes"
            :tone="route.name === item.key ? 'neutral' : 'accent'"
            class="ml-auto"
          >{{ pendingBarcodes }}</UiBadge>
        </RouterLink>
      </nav>

      <div class="border-t-2 border-rule p-3">
        <div class="mb-2 truncate text-[12px] text-ink-soft">{{ auth.user?.email }}</div>
        <UiButton size="sm" class="w-full" @click="signOut">Đăng xuất</UiButton>
      </div>
    </aside>

    <main class="min-w-0 flex-1 p-6"><slot /></main>
  </div>
</template>
