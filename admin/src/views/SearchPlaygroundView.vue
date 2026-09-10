<script setup lang="ts">
import { computed, ref } from 'vue'
import { api, errorMessage } from '@/lib/api'
import UiCard from '@/components/UiCard.vue'
import UiButton from '@/components/UiButton.vue'
import UiInput from '@/components/UiInput.vue'
import UiBadge from '@/components/UiBadge.vue'
import type { SearchPreview } from '@/lib/types'

const query = ref('')
const result = ref<SearchPreview | null>(null)
const loading = ref(false)
const error = ref<string | null>(null)

async function run() {
  if (!query.value.trim()) return
  loading.value = true
  error.value = null
  try {
    result.value = await api.searchPreview(query.value.trim())
  } catch (err) {
    error.value = errorMessage(err)
    result.value = null
  } finally {
    loading.value = false
  }
}

/** Rank movement between a retriever's list and the fused ranking. */
function drift(fusedRank: number, ownRank: number | null): { text: string; tone: 'ok' | 'accent' | 'neutral' } {
  if (ownRank === null) return { text: 'chỉ 1 nguồn', tone: 'neutral' }
  const delta = ownRank - fusedRank
  if (delta > 0) return { text: `▲${delta}`, tone: 'ok' }
  if (delta < 0) return { text: `▼${-delta}`, tone: 'accent' }
  return { text: '=', tone: 'neutral' }
}

const both = computed(() =>
  result.value?.fused.filter((f) => f.bm25Rank !== null && f.vectorRank !== null).length ?? 0)
</script>

<template>
  <h1 class="mb-1 text-2xl font-semibold tracking-tight">Thử tìm kiếm</h1>
  <p class="mb-5 max-w-3xl text-[13px] text-ink-soft">
    Đúng pipeline mà AI dùng khi đọc ảnh món ăn: BM25 (FTS5) và vector (Vectorize) chạy song song,
    rồi trộn bằng RRF <code class="font-mono">score = Σ 1/(k + hạng)</code>. Cột cuối cho thấy mỗi kết quả
    lên hay xuống bao nhiêu hạng sau khi trộn.
  </p>

  <UiCard>
    <div class="flex gap-2 border-b-2 border-rule px-4 py-3">
      <UiInput v-model="query" placeholder="com ga, bún chả, sữa tươi…" class="max-w-md" @keyup.enter="run" />
      <UiButton variant="primary" :loading="loading" @click="run">Chạy</UiButton>
      <div v-if="result" class="ml-auto flex items-center gap-2 font-mono text-[12px] text-ink-soft">
        <UiBadge>k = {{ result.rrfK }}</UiBadge>
        <UiBadge>{{ both }} kết quả trùng cả 2 nguồn</UiBadge>
        <UiBadge v-if="result.tookMs !== undefined">{{ result.tookMs }} ms</UiBadge>
      </div>
    </div>

    <p v-if="error" class="m-4 border-2 border-accent bg-accent-soft px-3 py-2 text-accent">{{ error }}</p>

    <div v-else-if="!result" class="px-4 py-10 text-center text-ink-faint">
      Nhập một truy vấn để so sánh ba bảng xếp hạng.
    </div>

    <div v-else class="grid gap-4 p-4 lg:grid-cols-3">
      <div>
        <h3 class="mb-2 text-[12px] font-semibold tracking-wide text-ink-soft uppercase">BM25 (FTS5)</h3>
        <ol class="space-y-1">
          <li v-for="c in result.bm25" :key="`b-${c.corpus}-${c.id}`" class="border-2 border-rule-soft bg-paper-raised px-2 py-1.5">
            <div class="flex gap-2">
              <span class="font-mono text-ink-faint">{{ c.rank }}</span>
              <span class="min-w-0 flex-1 truncate">{{ c.title }}</span>
            </div>
            <UiBadge :tone="c.corpus === 'foods' ? 'info' : 'neutral'">{{ c.corpus }}</UiBadge>
          </li>
          <li v-if="result.bm25.length === 0" class="px-2 py-4 text-center text-ink-faint">không có</li>
        </ol>
      </div>

      <div>
        <h3 class="mb-2 text-[12px] font-semibold tracking-wide text-ink-soft uppercase">Vector (Vectorize)</h3>
        <ol class="space-y-1">
          <li v-for="c in result.vector" :key="`v-${c.corpus}-${c.id}`" class="border-2 border-rule-soft bg-paper-raised px-2 py-1.5">
            <div class="flex gap-2">
              <span class="font-mono text-ink-faint">{{ c.rank }}</span>
              <span class="min-w-0 flex-1 truncate">{{ c.title }}</span>
              <span class="font-mono text-[11px] text-ink-faint">{{ c.score?.toFixed(3) ?? '' }}</span>
            </div>
            <UiBadge :tone="c.corpus === 'foods' ? 'info' : 'neutral'">{{ c.corpus }}</UiBadge>
          </li>
          <li v-if="result.vector.length === 0" class="px-2 py-4 text-center text-ink-faint">không có</li>
        </ol>
      </div>

      <div>
        <h3 class="mb-2 text-[12px] font-semibold tracking-wide text-accent uppercase">Trộn RRF → đưa vào prompt</h3>
        <ol class="space-y-1">
          <li v-for="c in result.fused" :key="`f-${c.corpus}-${c.id}`" class="border-2 border-rule bg-paper-raised px-2 py-1.5 shadow-hard-sm">
            <div class="flex gap-2">
              <span class="font-mono text-ink-faint">{{ c.rank }}</span>
              <span class="min-w-0 flex-1 truncate font-medium">{{ c.title }}</span>
              <span class="font-mono text-[11px]">{{ c.fusedScore.toFixed(4) }}</span>
            </div>
            <div class="mt-1 flex flex-wrap gap-1">
              <UiBadge :tone="c.corpus === 'foods' ? 'info' : 'neutral'">{{ c.corpus }}</UiBadge>
              <UiBadge>bm25 {{ c.bm25Rank ?? '—' }}</UiBadge>
              <UiBadge>vec {{ c.vectorRank ?? '—' }}</UiBadge>
              <UiBadge :tone="drift(c.rank, c.bm25Rank).tone">bm25 {{ drift(c.rank, c.bm25Rank).text }}</UiBadge>
              <UiBadge :tone="drift(c.rank, c.vectorRank).tone">vec {{ drift(c.rank, c.vectorRank).text }}</UiBadge>
            </div>
          </li>
          <li v-if="result.fused.length === 0" class="px-2 py-4 text-center text-ink-faint">không có</li>
        </ol>
      </div>
    </div>
  </UiCard>
</template>
