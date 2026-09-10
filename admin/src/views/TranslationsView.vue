<script setup lang="ts">
import { onMounted, ref, watch } from 'vue'
import { api, errorMessage } from '@/lib/api'
import UiCard from '@/components/UiCard.vue'
import UiState from '@/components/UiState.vue'
import UiButton from '@/components/UiButton.vue'
import UiInput from '@/components/UiInput.vue'
import UiField from '@/components/UiField.vue'
import { useToastStore } from '@/stores/toast'
import type { ActivityType, WorkoutExercise } from '@/lib/types'

const toast = useToastStore()
const entityType = ref<'activity_types' | 'workout_exercises'>('activity_types')
const rows = ref<Array<{ id: number; code: string }>>([])
const selectedId = ref<string>('')
const values = ref<{ vi: string; en: string }>({ vi: '', en: '' })
const loading = ref(true)
const loadingOne = ref(false)
const saving = ref(false)
const error = ref<string | null>(null)

async function loadEntities() {
  loading.value = true
  error.value = null
  try {
    const page = entityType.value === 'activity_types'
      ? await api.activityTypes.list()
      : await api.exercises.list()
    rows.value = (page.items as Array<ActivityType | WorkoutExercise>).map((r) => ({ id: r.id, code: r.code }))
    selectedId.value = rows.value[0] ? String(rows.value[0].id) : ''
  } catch (err) {
    error.value = errorMessage(err)
  } finally {
    loading.value = false
  }
}
onMounted(loadEntities)
watch(entityType, loadEntities)

async function loadOne() {
  if (!selectedId.value) return
  loadingOne.value = true
  values.value = { vi: '', en: '' }
  try {
    const res = await api.translations.list(entityType.value, selectedId.value)
    for (const t of res.items) {
      if (t.field !== 'name') continue
      if (t.locale === 'vi') values.value.vi = t.value
      if (t.locale === 'en') values.value.en = t.value
    }
  } catch (err) {
    toast.error(errorMessage(err))
  } finally {
    loadingOne.value = false
  }
}
watch(selectedId, loadOne, { immediate: true })

async function save() {
  saving.value = true
  try {
    // Both languages go in one request so they cannot drift apart on a failure.
    await api.translations.put(entityType.value, selectedId.value, [
      { locale: 'vi', field: 'name', value: values.value.vi },
      { locale: 'en', field: 'name', value: values.value.en },
    ].filter((t) => t.value.trim() !== ''))
    toast.ok('Đã lưu bản dịch')
  } catch (err) {
    toast.error(errorMessage(err))
  } finally {
    saving.value = false
  }
}
</script>

<template>
  <h1 class="mb-1 text-2xl font-semibold tracking-tight">Dịch thuật</h1>
  <p class="mb-5 max-w-2xl text-[13px] text-ink-soft">
    Tên hiển thị của danh mục. App lấy theo <code class="font-mono">locale</code> của người dùng,
    không có bản dịch thì rơi về mã gốc.
  </p>

  <UiCard>
    <UiState :loading="loading" :error="error">
      <template #retry><UiButton size="sm" class="ml-3" @click="loadEntities">Thử lại</UiButton></template>

      <div class="grid gap-4 p-4 sm:grid-cols-2">
        <UiField label="Loại">
          <select v-model="entityType" class="w-full border-2 border-rule bg-paper-raised px-2 py-1.5">
            <option value="activity_types">activity_types</option>
            <option value="workout_exercises">workout_exercises</option>
          </select>
        </UiField>
        <UiField label="Mục">
          <select v-model="selectedId" class="w-full border-2 border-rule bg-paper-raised px-2 py-1.5 font-mono">
            <option v-for="r in rows" :key="r.id" :value="String(r.id)">{{ r.id }} — {{ r.code }}</option>
          </select>
        </UiField>
        <UiField label="Tiếng Việt"><UiInput v-model="values.vi" :disabled="loadingOne" /></UiField>
        <UiField label="English"><UiInput v-model="values.en" :disabled="loadingOne" /></UiField>
      </div>

      <div class="border-t-2 border-rule px-4 py-3">
        <UiButton variant="primary" :loading="saving" :disabled="!selectedId" @click="save">Lưu</UiButton>
      </div>
    </UiState>
  </UiCard>
</template>
