<script setup lang="ts">
withDefaults(defineProps<{ tone?: 'neutral' | 'ok' | 'warn' | 'info' | 'accent' }>(), { tone: 'neutral' })
</script>

<template>
  <span
    class="inline-block border px-1.5 py-0.5 font-mono text-[11px] leading-tight whitespace-nowrap"
    :class="[
      tone === 'neutral' && 'border-rule-soft bg-paper-sunk text-ink-soft',
      tone === 'ok' && 'border-ok bg-ok-soft text-ok',
      tone === 'warn' && 'border-warn bg-warn-soft text-warn',
      tone === 'info' && 'border-info bg-info-soft text-info',
      tone === 'accent' && 'border-accent bg-accent-soft text-accent',
    ]"
  ><slot /></span>
</template>
