<script setup lang="ts">
import { computed, reactive, watch } from 'vue'
import UiField from './UiField.vue'
import UiInput from './UiInput.vue'
import type { Food, FoodInput } from '@/lib/types'

const props = defineProps<{
  modelValue?: Food | null
  /** Prefilled and locked when resolving a barcode from the queue. */
  lockedBarcode?: string | null
  /** What the user typed when reporting an unknown barcode. */
  nameHint?: string | null
  /** Field name -> message, from the API's details.issues. */
  serverIssues?: Record<string, string>
}>()
const emit = defineEmits<{ submit: [FoodInput] }>()

const form = reactive<FoodInput & { barcode: string | null }>({
  barcode: null, name: '', brand: null, category: null,
  servingSizeG: 100, servingLabel: null, caloriesKcal: 0,
  proteinG: null, carbsG: null, fatG: null, saturatedFatG: null,
  fiberG: null, sugarG: null, sodiumMg: null, cholesterolMg: null,
  potassiumMg: null, calciumMg: null, ironMg: null, isVerified: true,
})

const localErrors = reactive<Record<string, string>>({})

watch(() => props.modelValue, (food) => {
  if (!food) return
  Object.assign(form, {
    barcode: food.barcode, name: food.name, brand: food.brand, category: food.category,
    servingSizeG: food.servingSizeG, servingLabel: food.servingLabel,
    caloriesKcal: food.caloriesKcal, proteinG: food.proteinG, carbsG: food.carbsG,
    fatG: food.fatG, saturatedFatG: food.saturatedFatG, fiberG: food.fiberG,
    sugarG: food.sugarG, sodiumMg: food.sodiumMg, cholesterolMg: food.cholesterolMg,
    potassiumMg: food.potassiumMg, calciumMg: food.calciumMg, ironMg: food.ironMg,
    isVerified: food.isVerified,
  })
}, { immediate: true })

watch(() => props.lockedBarcode, (code) => {
  if (code) form.barcode = code
}, { immediate: true })

// The hint only seeds an empty form; it must never overwrite a real product name.
watch(() => props.nameHint, (hint) => {
  if (hint && !form.name.trim()) form.name = hint
}, { immediate: true })

const NUMERIC: Array<[keyof FoodInput, string, string]> = [
  ['caloriesKcal', 'Calo', 'kcal'],
  ['proteinG', 'Đạm', 'g'],
  ['carbsG', 'Tinh bột', 'g'],
  ['fatG', 'Chất béo', 'g'],
  ['saturatedFatG', 'Béo bão hoà', 'g'],
  ['fiberG', 'Chất xơ', 'g'],
  ['sugarG', 'Đường', 'g'],
  ['sodiumMg', 'Natri', 'mg'],
  ['cholesterolMg', 'Cholesterol', 'mg'],
  ['potassiumMg', 'Kali', 'mg'],
  ['calciumMg', 'Canxi', 'mg'],
  ['ironMg', 'Sắt', 'mg'],
]

const errorFor = (field: string) => localErrors[field] ?? props.serverIssues?.[field] ?? null

const servingHint = computed(() =>
  `mọi giá trị dinh dưỡng tính cho ${form.servingSizeG || 0} g`)

function numberOrNull(v: unknown): number | null {
  if (v === '' || v === null || v === undefined) return null
  const n = Number(v)
  return Number.isFinite(n) ? n : null
}

function submit() {
  for (const key of Object.keys(localErrors)) delete localErrors[key]
  if (!form.name.trim()) localErrors.name = 'Bắt buộc'
  if (!form.servingSizeG || form.servingSizeG <= 0) localErrors.servingSizeG = 'Phải lớn hơn 0'
  if (numberOrNull(form.caloriesKcal) === null) localErrors.caloriesKcal = 'Bắt buộc'
  if (Object.keys(localErrors).length > 0) return

  const payload: FoodInput = { name: form.name.trim(), servingSizeG: Number(form.servingSizeG), caloriesKcal: Number(form.caloriesKcal) }
  payload.barcode = form.barcode?.trim() || null
  payload.brand = form.brand?.trim() || null
  payload.category = form.category?.trim() || null
  payload.servingLabel = form.servingLabel?.trim() || null
  payload.isVerified = form.isVerified
  for (const [key] of NUMERIC) {
    if (key === 'caloriesKcal') continue
    ;(payload as Record<string, unknown>)[key] = numberOrNull(form[key])
  }
  emit('submit', payload)
}

defineExpose({ submit })
</script>

<template>
  <form class="space-y-4" @submit.prevent="submit">
    <div class="grid gap-3 sm:grid-cols-2">
      <UiField label="Tên món" required :error="errorFor('name')">
        <UiInput v-model="form.name" :invalid="!!errorFor('name')" placeholder="Cơm tấm sườn nướng" />
      </UiField>
      <UiField label="Mã vạch" :error="errorFor('barcode')" hint="chỉ admin nhập">
        <UiInput v-model="form.barcode" mono :readonly="!!lockedBarcode" :invalid="!!errorFor('barcode')" />
      </UiField>
      <UiField label="Thương hiệu"><UiInput v-model="form.brand" /></UiField>
      <UiField label="Nhóm"><UiInput v-model="form.category" placeholder="rice_dish, beverage…" /></UiField>
    </div>

    <div class="grid gap-3 sm:grid-cols-2">
      <UiField label="Khẩu phần (g)" required :error="errorFor('servingSizeG')" :hint="servingHint">
        <UiInput v-model.number="form.servingSizeG" type="number" step="0.1" mono :invalid="!!errorFor('servingSizeG')" />
      </UiField>
      <UiField label="Nhãn khẩu phần"><UiInput v-model="form.servingLabel" placeholder="1 hộp 180ml" /></UiField>
    </div>

    <fieldset class="border-2 border-rule-soft p-3">
      <legend class="px-1 text-[12px] font-medium tracking-wide text-ink-soft uppercase">
        Dinh dưỡng / {{ form.servingSizeG || 0 }} g
      </legend>
      <div class="grid gap-3 sm:grid-cols-3">
        <UiField v-for="[key, label, unit] in NUMERIC" :key="key" :label="label" :hint="unit" :error="errorFor(key)">
          <UiInput v-model.number="(form as any)[key]" type="number" step="0.01" mono :invalid="!!errorFor(key)" />
        </UiField>
      </div>
    </fieldset>

    <label class="flex items-center gap-2">
      <input v-model="form.isVerified" type="checkbox" class="size-4 border-2 border-rule" />
      <span class="text-[13px]">Đã xác minh (ưu tiên hơn kết quả AI khi khớp món)</span>
    </label>
  </form>
</template>
