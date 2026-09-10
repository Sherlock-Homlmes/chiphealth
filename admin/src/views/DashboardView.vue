<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { RouterLink } from 'vue-router'
import { api, errorMessage } from '@/lib/api'
import UiCard from '@/components/UiCard.vue'
import UiState from '@/components/UiState.vue'
import UiButton from '@/components/UiButton.vue'
import type { AdminStats } from '@/lib/types'

const stats = ref<AdminStats | null>(null)
const loading = ref(true)
const error = ref<string | null>(null)

async function load() {
  loading.value = true
  error.value = null
  try {
    stats.value = await api.stats()
  } catch (err) {
    error.value = errorMessage(err)
  } finally {
    loading.value = false
  }
}
onMounted(load)

const tiles = () => [
  { label: 'Người dùng', value: stats.value?.users ?? 0 },
  { label: 'Thực phẩm', value: stats.value?.foods ?? 0 },
  { label: 'Tài liệu RAG', value: stats.value?.kbDocuments ?? 0 },
  { label: 'Ảnh phân tích hôm nay', value: stats.value?.mealsAnalysedToday ?? 0 },
]
</script>

<template>
  <h1 class="mb-5 text-2xl font-semibold tracking-tight">Tổng quan</h1>

  <UiState :loading="loading" :error="error">
    <template #retry><UiButton size="sm" class="ml-3" @click="load">Thử lại</UiButton></template>

    <!-- The barcode queue is the admin's daily job, so it gets the top slot. -->
    <div
      class="mb-5 flex items-center gap-4 border-2 border-rule p-4 shadow-hard"
      :class="stats && stats.pendingBarcodeMisses > 0 ? 'bg-accent-soft' : 'bg-paper-raised'"
    >
      <div class="font-mono text-4xl leading-none">{{ stats?.pendingBarcodeMisses ?? 0 }}</div>
      <div class="min-w-0">
        <div class="font-semibold">mã vạch người dùng quét mà chưa có dữ liệu</div>
        <div class="text-[13px] text-ink-soft">Sắp theo số lần quét — nhập cái nhiều người cần trước.</div>
      </div>
      <RouterLink to="/barcodes" class="ml-auto shrink-0">
        <UiButton variant="primary">Mở hàng đợi</UiButton>
      </RouterLink>
    </div>

    <div class="mb-5 grid grid-cols-2 gap-4 lg:grid-cols-4">
      <div v-for="t in tiles()" :key="t.label" class="border-2 border-rule bg-paper-raised p-4 shadow-hard">
        <div class="font-mono text-3xl leading-none">{{ t.value }}</div>
        <div class="mt-1 text-[13px] text-ink-soft">{{ t.label }}</div>
      </div>
    </div>

    <UiCard title="Chất lượng phân tích AI">
      <div class="grid gap-4 p-4 sm:grid-cols-2">
        <div>
          <div class="font-mono text-2xl">{{ ((stats?.aiFailureRate ?? 0) * 100).toFixed(1) }}%</div>
          <div class="text-[13px] text-ink-soft">tỷ lệ phân tích ảnh thất bại hôm nay</div>
        </div>
        <div>
          <div class="font-mono text-2xl">{{ stats?.foodsVerified ?? 0 }}</div>
          <div class="text-[13px] text-ink-soft">thực phẩm đã được admin xác minh</div>
        </div>
      </div>
    </UiCard>
  </UiState>
</template>
