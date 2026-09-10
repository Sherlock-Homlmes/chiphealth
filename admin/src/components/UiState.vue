<script setup lang="ts">
defineProps<{
  loading?: boolean
  error?: string | null
  /** Show the empty slot when there is nothing to render. */
  empty?: boolean
  emptyText?: string
  colspan?: number
}>()
</script>

<template>
  <!-- One component so no screen can silently render a blank table. -->
  <div v-if="loading" class="flex items-center gap-2 px-4 py-8 text-ink-soft">
    <span class="inline-block size-3 animate-spin border-2 border-current border-t-transparent" />
    Đang tải…
  </div>
  <div v-else-if="error" class="m-4 border-2 border-accent bg-accent-soft px-3 py-2 text-accent">
    {{ error }}
    <slot name="retry" />
  </div>
  <div v-else-if="empty" class="px-4 py-10 text-center text-ink-faint">
    {{ emptyText ?? 'Chưa có dữ liệu' }}
    <slot name="empty" />
  </div>
  <slot v-else />
</template>
