<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { RouterView } from 'vue-router'
import AppShell from '@/components/AppShell.vue'
import ToastHost from '@/components/ToastHost.vue'
import { useAuthStore } from '@/stores/auth'
import { useRoute } from 'vue-router'

const auth = useAuthStore()
const route = useRoute()
const booted = ref(false)

onMounted(async () => {
  await auth.restore()
  booted.value = true
})
</script>

<template>
  <div v-if="!booted" class="flex min-h-dvh items-center justify-center text-ink-soft">
    <span class="inline-block size-4 animate-spin border-2 border-current border-t-transparent" />
  </div>
  <RouterView v-else-if="route.meta.public" />
  <AppShell v-else>
    <RouterView />
  </AppShell>
  <ToastHost />
</template>
