<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue'
import { api, errorMessage, fieldIssues } from '@/lib/api'
import UiCard from '@/components/UiCard.vue'
import UiState from '@/components/UiState.vue'
import UiButton from '@/components/UiButton.vue'
import UiInput from '@/components/UiInput.vue'
import UiField from '@/components/UiField.vue'
import UiBadge from '@/components/UiBadge.vue'
import UiModal from '@/components/UiModal.vue'
import { useToastStore } from '@/stores/toast'
import type {
  ActivityCategory, ActivityType, ActivityTypeInput, WorkoutExercise, WorkoutExerciseInput,
} from '@/lib/types'

const toast = useToastStore()
const tab = ref<'activities' | 'exercises'>('activities')

const activities = ref<ActivityType[]>([])
const exercises = ref<WorkoutExercise[]>([])
const loading = ref(true)
const error = ref<string | null>(null)
const saving = ref(false)
const issues = ref<Record<string, string>>({})

const CATEGORIES: ActivityCategory[] = ['cardio_gps', 'cardio_indoor', 'strength', 'sport', 'mind_body', 'other']

const showActivity = ref(false)
const editingActivity = ref<ActivityType | null>(null)
const activityForm = reactive<ActivityTypeInput>({
  code: '', category: 'other', defaultMet: 5, supportsGps: false,
  supportsSets: false, supportsHeartRate: true, iconName: null, sortOrder: 0, isActive: true,
})

const showExercise = ref(false)
const editingExercise = ref<WorkoutExercise | null>(null)
const exerciseForm = reactive<WorkoutExerciseInput>({
  code: '', muscleGroup: 'chest', equipment: null, isUnilateral: false, sortOrder: 0,
})

async function load() {
  loading.value = true
  error.value = null
  try {
    const [a, e] = await Promise.all([api.activityTypes.list(), api.exercises.list()])
    activities.value = a.items
    exercises.value = e.items
  } catch (err) {
    error.value = errorMessage(err)
  } finally {
    loading.value = false
  }
}
onMounted(load)

function openActivity(row: ActivityType | null) {
  editingActivity.value = row
  issues.value = {}
  Object.assign(activityForm, row ?? {
    code: '', category: 'other', defaultMet: 5, supportsGps: false,
    supportsSets: false, supportsHeartRate: true, iconName: null, sortOrder: 0, isActive: true,
  })
  showActivity.value = true
}

async function saveActivity() {
  saving.value = true
  issues.value = {}
  try {
    if (editingActivity.value) await api.activityTypes.update(editingActivity.value.id, { ...activityForm })
    else await api.activityTypes.create({ ...activityForm })
    toast.ok('Đã lưu')
    showActivity.value = false
    await load()
  } catch (err) {
    issues.value = fieldIssues(err)
    toast.error(errorMessage(err))
  } finally {
    saving.value = false
  }
}

function openExercise(row: WorkoutExercise | null) {
  editingExercise.value = row
  issues.value = {}
  Object.assign(exerciseForm, row ?? {
    code: '', muscleGroup: 'chest', equipment: null, isUnilateral: false, sortOrder: 0,
  })
  showExercise.value = true
}

async function saveExercise() {
  saving.value = true
  issues.value = {}
  try {
    if (editingExercise.value) await api.exercises.update(editingExercise.value.id, { ...exerciseForm })
    else await api.exercises.create({ ...exerciseForm })
    toast.ok('Đã lưu')
    showExercise.value = false
    await load()
  } catch (err) {
    issues.value = fieldIssues(err)
    toast.error(errorMessage(err))
  } finally {
    saving.value = false
  }
}
</script>

<template>
  <div class="mb-5 flex items-center gap-3">
    <h1 class="text-2xl font-semibold tracking-tight">Danh mục</h1>
    <div class="ml-auto flex gap-2">
      <UiButton :variant="tab === 'activities' ? 'primary' : 'default'" @click="tab = 'activities'">Môn thể thao</UiButton>
      <UiButton :variant="tab === 'exercises' ? 'primary' : 'default'" @click="tab = 'exercises'">Bài tập tạ</UiButton>
    </div>
  </div>

  <UiCard>
    <UiState :loading="loading" :error="error">
      <template #retry><UiButton size="sm" class="ml-3" @click="load">Thử lại</UiButton></template>

      <div class="flex justify-end border-b-2 border-rule px-4 py-3">
        <UiButton v-if="tab === 'activities'" variant="primary" @click="openActivity(null)">Thêm môn</UiButton>
        <UiButton v-else variant="primary" @click="openExercise(null)">Thêm bài tập</UiButton>
      </div>

      <div class="overflow-x-auto">
        <table v-if="tab === 'activities'" class="w-full border-collapse text-[13px]">
          <thead>
            <tr class="border-b-2 border-rule text-left text-[11px] tracking-wide text-ink-soft uppercase">
              <th class="px-4 py-2">Mã</th><th class="px-2 py-2">Tên</th><th class="px-2 py-2">Nhóm</th>
              <th class="px-2 py-2 text-right">MET</th><th class="px-2 py-2">Hỗ trợ</th>
              <th class="px-2 py-2 text-right">Thứ tự</th><th class="px-4 py-2"></th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="a in activities" :key="a.id" class="border-b border-rule-soft hover:bg-paper-sunk">
              <td class="px-4 py-2 font-mono text-[12px]">{{ a.code }}</td>
              <td class="px-2 py-2">{{ a.name ?? '—' }}</td>
              <td class="px-2 py-2"><UiBadge>{{ a.category }}</UiBadge></td>
              <td class="px-2 py-2 text-right font-mono">{{ a.defaultMet }}</td>
              <td class="px-2 py-2">
                <div class="flex gap-1">
                  <UiBadge v-if="a.supportsGps" tone="info">gps</UiBadge>
                  <UiBadge v-if="a.supportsSets" tone="info">sets</UiBadge>
                  <UiBadge v-if="a.supportsHeartRate" tone="info">hr</UiBadge>
                </div>
              </td>
              <td class="px-2 py-2 text-right font-mono">{{ a.sortOrder }}</td>
              <td class="px-4 py-2 text-right"><UiButton size="sm" @click="openActivity(a)">sửa</UiButton></td>
            </tr>
          </tbody>
        </table>

        <table v-else class="w-full border-collapse text-[13px]">
          <thead>
            <tr class="border-b-2 border-rule text-left text-[11px] tracking-wide text-ink-soft uppercase">
              <th class="px-4 py-2">Mã</th><th class="px-2 py-2">Tên</th><th class="px-2 py-2">Nhóm cơ</th>
              <th class="px-2 py-2">Dụng cụ</th><th class="px-4 py-2"></th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="e in exercises" :key="e.id" class="border-b border-rule-soft hover:bg-paper-sunk">
              <td class="px-4 py-2 font-mono text-[12px]">{{ e.code }}</td>
              <td class="px-2 py-2">{{ e.name ?? '—' }}</td>
              <td class="px-2 py-2"><UiBadge>{{ e.muscleGroup }}</UiBadge></td>
              <td class="px-2 py-2 text-ink-soft">{{ e.equipment ?? '—' }}</td>
              <td class="px-4 py-2 text-right"><UiButton size="sm" @click="openExercise(e)">sửa</UiButton></td>
            </tr>
          </tbody>
        </table>
      </div>
    </UiState>
  </UiCard>

  <UiModal v-if="showActivity" :title="editingActivity ? 'Sửa môn' : 'Thêm môn'" @close="showActivity = false">
    <div class="space-y-3">
      <UiField label="Mã" required :error="issues.code"><UiInput v-model="activityForm.code" mono :invalid="!!issues.code" /></UiField>
      <div class="grid gap-3 sm:grid-cols-2">
        <UiField label="Nhóm">
          <select v-model="activityForm.category" class="w-full border-2 border-rule bg-paper-raised px-2 py-1.5">
            <option v-for="cat in CATEGORIES" :key="cat" :value="cat">{{ cat }}</option>
          </select>
        </UiField>
        <UiField label="MET" hint="ước tính calo khi không có nhịp tim" :error="issues.defaultMet">
          <UiInput v-model.number="activityForm.defaultMet" type="number" step="0.1" mono />
        </UiField>
        <UiField label="Icon"><UiInput v-model="activityForm.iconName" /></UiField>
        <UiField label="Thứ tự"><UiInput v-model.number="activityForm.sortOrder" type="number" mono /></UiField>
      </div>
      <div class="flex flex-wrap gap-4">
        <label class="flex items-center gap-2"><input v-model="activityForm.supportsGps" type="checkbox" class="size-4 border-2 border-rule" /> GPS</label>
        <label class="flex items-center gap-2"><input v-model="activityForm.supportsSets" type="checkbox" class="size-4 border-2 border-rule" /> Sets/reps</label>
        <label class="flex items-center gap-2"><input v-model="activityForm.supportsHeartRate" type="checkbox" class="size-4 border-2 border-rule" /> Nhịp tim</label>
        <label class="flex items-center gap-2"><input v-model="activityForm.isActive" type="checkbox" class="size-4 border-2 border-rule" /> Đang bật</label>
      </div>
    </div>
    <template #footer>
      <UiButton @click="showActivity = false">Huỷ</UiButton>
      <UiButton variant="primary" :loading="saving" @click="saveActivity">Lưu</UiButton>
    </template>
  </UiModal>

  <UiModal v-if="showExercise" :title="editingExercise ? 'Sửa bài tập' : 'Thêm bài tập'" @close="showExercise = false">
    <div class="space-y-3">
      <UiField label="Mã" required :error="issues.code"><UiInput v-model="exerciseForm.code" mono :invalid="!!issues.code" /></UiField>
      <div class="grid gap-3 sm:grid-cols-2">
        <UiField label="Nhóm cơ" required :error="issues.muscleGroup"><UiInput v-model="exerciseForm.muscleGroup" /></UiField>
        <UiField label="Dụng cụ"><UiInput v-model="exerciseForm.equipment" /></UiField>
        <UiField label="Thứ tự"><UiInput v-model.number="exerciseForm.sortOrder" type="number" mono /></UiField>
      </div>
      <label class="flex items-center gap-2"><input v-model="exerciseForm.isUnilateral" type="checkbox" class="size-4 border-2 border-rule" /> Tập một bên</label>
    </div>
    <template #footer>
      <UiButton @click="showExercise = false">Huỷ</UiButton>
      <UiButton variant="primary" :loading="saving" @click="saveExercise">Lưu</UiButton>
    </template>
  </UiModal>
</template>
