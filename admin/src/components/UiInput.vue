<script setup lang="ts">
defineProps<{ invalid?: boolean; mono?: boolean }>()
const model = defineModel<string | number | null>()
</script>

<template>
  <input
    v-model="model"
    class="w-full border-2 bg-paper-raised px-2.5 py-1.5 outline-none
           focus:border-accent focus:shadow-hard-sm"
    :class="[invalid ? 'border-accent' : 'border-rule', mono && 'font-mono']"
    v-bind="$attrs"
  />
</template>
