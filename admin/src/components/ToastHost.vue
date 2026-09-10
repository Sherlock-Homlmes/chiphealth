<script setup lang="ts">
import { useToastStore } from '@/stores/toast'
const toasts = useToastStore()
</script>

<template>
  <div class="fixed right-5 bottom-5 z-[60] flex w-80 flex-col gap-2">
    <div
      v-for="t in toasts.toasts"
      :key="t.id"
      class="cursor-pointer border-2 border-rule px-3 py-2 shadow-hard"
      :class="[
        t.kind === 'ok' && 'bg-ok-soft text-ok',
        t.kind === 'error' && 'bg-accent-soft text-accent',
        t.kind === 'info' && 'bg-info-soft text-info',
      ]"
      @click="toasts.dismiss(t.id)"
    >{{ t.text }}</div>
  </div>
</template>
