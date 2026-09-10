<script setup lang="ts">
import { onMounted, onUnmounted } from 'vue'

const props = defineProps<{ title: string; wide?: boolean }>()
const emit = defineEmits<{ close: [] }>()

function onKey(e: KeyboardEvent) {
  if (e.key === 'Escape') emit('close')
}
onMounted(() => document.addEventListener('keydown', onKey))
onUnmounted(() => document.removeEventListener('keydown', onKey))
void props
</script>

<template>
  <div class="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-ink/40 p-6" @click.self="emit('close')">
    <div class="w-full border-2 border-rule bg-paper shadow-hard-lg" :class="wide ? 'max-w-4xl' : 'max-w-xl'">
      <header class="flex items-center gap-3 border-b-2 border-rule bg-paper-raised px-4 py-3">
        <h2 class="font-semibold">{{ title }}</h2>
        <button class="ml-auto px-2 text-xl leading-none text-ink-soft hover:text-accent" @click="emit('close')">×</button>
      </header>
      <div class="p-4"><slot /></div>
      <footer v-if="$slots.footer" class="flex justify-end gap-2 border-t-2 border-rule bg-paper-raised px-4 py-3">
        <slot name="footer" />
      </footer>
    </div>
  </div>
</template>
