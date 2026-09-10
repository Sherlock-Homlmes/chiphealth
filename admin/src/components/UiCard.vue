<script setup lang="ts">
defineProps<{ title?: string; subtitle?: string }>()
</script>

<template>
  <section class="border-2 border-rule bg-paper-raised shadow-hard">
    <header v-if="title || $slots.actions" class="flex items-center gap-3 border-b-2 border-rule px-4 py-2.5">
      <div class="min-w-0">
        <h2 v-if="title" class="truncate font-semibold">{{ title }}</h2>
        <p v-if="subtitle" class="truncate text-[12px] text-ink-soft">{{ subtitle }}</p>
      </div>
      <div class="ml-auto flex shrink-0 items-center gap-2"><slot name="actions" /></div>
    </header>
    <div :class="$slots.actions || title ? '' : ''"><slot /></div>
  </section>
</template>
