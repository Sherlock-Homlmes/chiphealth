<script setup lang="ts">
defineProps<{
  label: string
  /** Server-side message for this field, from `details.issues`. */
  error?: string | null
  hint?: string
  required?: boolean
}>()
</script>

<template>
  <label class="block">
    <span class="mb-1 flex items-baseline gap-1.5">
      <span class="text-[12px] font-medium tracking-wide text-ink-soft uppercase">{{ label }}</span>
      <span v-if="required" class="text-accent">*</span>
      <span v-if="hint" class="ml-auto font-mono text-[11px] text-ink-faint">{{ hint }}</span>
    </span>
    <slot />
    <span v-if="error" class="mt-1 block text-[12px] text-accent">{{ error }}</span>
  </label>
</template>
