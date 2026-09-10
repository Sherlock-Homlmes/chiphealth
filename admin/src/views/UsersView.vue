<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { api, errorMessage } from '@/lib/api'
import UiCard from '@/components/UiCard.vue'
import UiState from '@/components/UiState.vue'
import UiButton from '@/components/UiButton.vue'
import UiInput from '@/components/UiInput.vue'
import UiBadge from '@/components/UiBadge.vue'
import { useToastStore } from '@/stores/toast'
import { useAuthStore } from '@/stores/auth'
import type { AdminUser } from '@/lib/types'

const toast = useToastStore()
const auth = useAuthStore()
const items = ref<AdminUser[]>([])
const cursor = ref<string | null>(null)
const loading = ref(true)
const error = ref<string | null>(null)
const query = ref('')

async function load(reset = true) {
  if (reset) { loading.value = true; error.value = null }
  try {
    const page = await api.users.list({ q: query.value || undefined, cursor: reset ? undefined : cursor.value })
    items.value = reset ? page.items : [...items.value, ...page.items]
    cursor.value = page.nextCursor
  } catch (err) {
    error.value = errorMessage(err)
  } finally {
    loading.value = false
  }
}
onMounted(() => load())

async function setRole(user: AdminUser, role: 'user' | 'admin') {
  try {
    const updated = await api.users.setRole(user.id, role)
    user.role = updated.role
    toast.ok(`${user.email} → ${role}`)
  } catch (err) {
    // The API refuses self-demotion; show that reason rather than a generic error.
    toast.error(errorMessage(err))
  }
}
</script>

<template>
  <h1 class="mb-5 text-2xl font-semibold tracking-tight">Người dùng</h1>

  <UiCard>
    <div class="flex gap-2 border-b-2 border-rule px-4 py-3">
      <UiInput v-model="query" placeholder="Email hoặc tên…" class="max-w-64" @keyup.enter="load()" />
      <UiButton @click="load()">Tìm</UiButton>
    </div>

    <UiState :loading="loading" :error="error" :empty="items.length === 0">
      <template #retry><UiButton size="sm" class="ml-3" @click="load()">Thử lại</UiButton></template>

      <div class="overflow-x-auto">
        <table class="w-full border-collapse text-[13px]">
          <thead>
            <tr class="border-b-2 border-rule text-left text-[11px] tracking-wide text-ink-soft uppercase">
              <th class="px-4 py-2">Email</th>
              <th class="px-2 py-2">Tên</th>
              <th class="px-2 py-2">Quyền</th>
              <th class="px-2 py-2">Múi giờ</th>
              <th class="px-4 py-2"></th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="u in items" :key="u.id" class="border-b border-rule-soft hover:bg-paper-sunk">
              <td class="px-4 py-2 font-mono text-[12px]">{{ u.email }}</td>
              <td class="px-2 py-2">{{ u.displayName ?? '—' }}</td>
              <td class="px-2 py-2">
                <UiBadge :tone="u.role === 'admin' ? 'accent' : 'neutral'">{{ u.role }}</UiBadge>
                <UiBadge v-if="u.deletedAt" tone="warn" class="ml-1">đã xoá</UiBadge>
              </td>
              <td class="px-2 py-2 font-mono text-[12px] text-ink-soft">{{ u.timezone }}</td>
              <td class="px-4 py-2 text-right">
                <UiButton
                  size="sm"
                  :disabled="u.id === auth.user?.id && u.role === 'admin'"
                  @click="setRole(u, u.role === 'admin' ? 'user' : 'admin')"
                >{{ u.role === 'admin' ? 'hạ quyền' : 'nâng lên admin' }}</UiButton>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div v-if="cursor" class="border-t-2 border-rule px-4 py-3">
        <UiButton @click="load(false)">Tải thêm</UiButton>
      </div>
    </UiState>
  </UiCard>
</template>
