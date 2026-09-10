<script setup lang="ts">
import { onMounted, ref, reactive } from 'vue'
import { api, errorMessage, fieldIssues } from '@/lib/api'
import UiCard from '@/components/UiCard.vue'
import UiState from '@/components/UiState.vue'
import UiButton from '@/components/UiButton.vue'
import UiInput from '@/components/UiInput.vue'
import UiBadge from '@/components/UiBadge.vue'
import UiModal from '@/components/UiModal.vue'
import FoodForm from '@/components/FoodForm.vue'
import { useToastStore } from '@/stores/toast'
import type { Food, FoodInput, FoodSource, ImportReport } from '@/lib/types'

const toast = useToastStore()
const items = ref<Food[]>([])
const cursor = ref<string | null>(null)
const loading = ref(true)
const loadingMore = ref(false)
const error = ref<string | null>(null)
const saving = ref(false)

const filters = reactive<{ q: string; source: FoodSource | ''; verified: boolean | '' }>({
  q: '', source: '', verified: '',
})

const editing = ref<Food | null>(null)
const showForm = ref(false)
const formRef = ref<InstanceType<typeof FoodForm> | null>(null)
const serverIssues = ref<Record<string, string>>({})

const showImport = ref(false)
const importFormat = ref<'csv' | 'json'>('csv')
const importContent = ref('')
const importReport = ref<ImportReport | null>(null)

async function load(reset = true) {
  if (reset) { loading.value = true; error.value = null }
  else loadingMore.value = true
  try {
    const page = await api.foods.list({
      q: filters.q || undefined,
      source: filters.source || undefined,
      verified: filters.verified === '' ? undefined : filters.verified,
      cursor: reset ? undefined : cursor.value,
    })
    items.value = reset ? page.items : [...items.value, ...page.items]
    cursor.value = page.nextCursor
  } catch (err) {
    error.value = errorMessage(err)
  } finally {
    loading.value = false
    loadingMore.value = false
  }
}
onMounted(() => load())

function openCreate() {
  editing.value = null
  serverIssues.value = {}
  showForm.value = true
}
function openEdit(food: Food) {
  editing.value = food
  serverIssues.value = {}
  showForm.value = true
}

async function save(payload: FoodInput) {
  saving.value = true
  serverIssues.value = {}
  try {
    if (editing.value) {
      await api.foods.update(editing.value.id, payload)
      toast.ok('Đã lưu thay đổi')
    } else {
      await api.foods.create(payload)
      toast.ok('Đã thêm thực phẩm')
    }
    showForm.value = false
    await load()
  } catch (err) {
    serverIssues.value = fieldIssues(err)
    toast.error(errorMessage(err))
  } finally {
    saving.value = false
  }
}

async function toggleVerified(food: Food) {
  try {
    const updated = await api.foods.verify(food.id, !food.isVerified)
    Object.assign(food, updated)
  } catch (err) {
    toast.error(errorMessage(err))
  }
}

async function remove(food: Food) {
  if (!confirm(`Xoá "${food.name}"?`)) return
  try {
    await api.foods.remove(food.id)
    items.value = items.value.filter((f) => f.id !== food.id)
    toast.ok('Đã xoá')
  } catch (err) {
    toast.error(errorMessage(err))
  }
}

async function runImport() {
  saving.value = true
  try {
    importReport.value = await api.foods.import({ format: importFormat.value, content: importContent.value })
    const report = importReport.value
    // A re-import of the same barcode is an update, not a duplicate.
    toast.ok(`${report.created} tạo mới, ${report.updated} cập nhật`)
    await load()
  } catch (err) {
    toast.error(errorMessage(err))
  } finally {
    saving.value = false
  }
}

const embedTone = (s: Food['embeddingStatus']) =>
  s === 'indexed' ? 'ok' : s === 'failed' ? 'accent' : 'warn'
</script>

<template>
  <div class="mb-5 flex items-center gap-3">
    <h1 class="text-2xl font-semibold tracking-tight">Thực phẩm</h1>
    <div class="ml-auto flex gap-2">
      <UiButton @click="showImport = true">Nhập hàng loạt</UiButton>
      <UiButton variant="primary" @click="openCreate">Thêm món</UiButton>
    </div>
  </div>

  <UiCard>
    <div class="flex flex-wrap items-end gap-2 border-b-2 border-rule px-4 py-3">
      <UiInput v-model="filters.q" placeholder="Tìm theo tên…" class="max-w-64" @keyup.enter="load()" />
      <select v-model="filters.source" class="border-2 border-rule bg-paper-raised px-2 py-1.5">
        <option value="">Mọi nguồn</option>
        <option value="admin_barcode">admin_barcode</option>
        <option value="admin_manual">admin_manual</option>
        <option value="rag_matched">rag_matched</option>
        <option value="web_search">web_search</option>
        <option value="ai_estimated">ai_estimated</option>
      </select>
      <select v-model="filters.verified" class="border-2 border-rule bg-paper-raised px-2 py-1.5">
        <option :value="''">Xác minh: tất cả</option>
        <option :value="true">Đã xác minh</option>
        <option :value="false">Chưa xác minh</option>
      </select>
      <UiButton @click="load()">Lọc</UiButton>
    </div>

    <UiState :loading="loading" :error="error" :empty="items.length === 0" empty-text="Không có món nào khớp bộ lọc">
      <template #retry><UiButton size="sm" class="ml-3" @click="load()">Thử lại</UiButton></template>

      <div class="overflow-x-auto">
        <table class="w-full border-collapse text-[13px]">
          <thead>
            <tr class="border-b-2 border-rule text-left text-[11px] tracking-wide text-ink-soft uppercase">
              <th class="px-4 py-2">Tên</th>
              <th class="px-2 py-2">Mã vạch</th>
              <th class="px-2 py-2 text-right">Khẩu phần</th>
              <th class="px-2 py-2 text-right">kcal</th>
              <th class="px-2 py-2 text-right">P / C / F</th>
              <th class="px-2 py-2">Nguồn</th>
              <th class="px-2 py-2">Vector</th>
              <th class="px-4 py-2"></th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="food in items" :key="food.id" class="border-b border-rule-soft hover:bg-paper-sunk">
              <td class="px-4 py-2">
                <button class="text-left font-medium hover:text-accent" @click="openEdit(food)">{{ food.name }}</button>
                <span v-if="food.brand" class="ml-1 text-ink-faint">· {{ food.brand }}</span>
              </td>
              <td class="px-2 py-2 font-mono text-[12px]">{{ food.barcode ?? '—' }}</td>
              <td class="px-2 py-2 text-right font-mono">{{ food.servingSizeG }} g</td>
              <td class="px-2 py-2 text-right font-mono">{{ food.caloriesKcal }}</td>
              <td class="px-2 py-2 text-right font-mono text-ink-soft">
                {{ food.proteinG ?? '–' }} / {{ food.carbsG ?? '–' }} / {{ food.fatG ?? '–' }}
              </td>
              <td class="px-2 py-2"><UiBadge>{{ food.source }}</UiBadge></td>
              <td class="px-2 py-2"><UiBadge :tone="embedTone(food.embeddingStatus)">{{ food.embeddingStatus ?? 'pending' }}</UiBadge></td>
              <td class="px-4 py-2">
                <div class="flex justify-end gap-1">
                  <UiButton size="sm" @click="toggleVerified(food)">
                    {{ food.isVerified ? '✓ đã xác minh' : 'xác minh' }}
                  </UiButton>
                  <UiButton size="sm" variant="danger" @click="remove(food)">xoá</UiButton>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div v-if="cursor" class="border-t-2 border-rule px-4 py-3">
        <UiButton :loading="loadingMore" @click="load(false)">Tải thêm</UiButton>
      </div>
    </UiState>
  </UiCard>

  <UiModal v-if="showForm" :title="editing ? 'Sửa thực phẩm' : 'Thêm thực phẩm'" wide @close="showForm = false">
    <FoodForm ref="formRef" :model-value="editing" :server-issues="serverIssues" @submit="save" />
    <template #footer>
      <UiButton @click="showForm = false">Huỷ</UiButton>
      <UiButton variant="primary" :loading="saving" @click="formRef?.submit()">Lưu</UiButton>
    </template>
  </UiModal>

  <UiModal v-if="showImport" title="Nhập hàng loạt" wide @close="showImport = false; importReport = null">
    <div class="space-y-3">
      <div class="flex gap-2">
        <label class="flex items-center gap-1"><input v-model="importFormat" type="radio" value="csv" /> CSV</label>
        <label class="flex items-center gap-1"><input v-model="importFormat" type="radio" value="json" /> JSON</label>
      </div>
      <p class="text-[12px] text-ink-soft">
        Cột CSV: <code class="font-mono">name, barcode, brand, category, servingSizeG, caloriesKcal, proteinG, carbsG, fatG, sugarG, sodiumMg…</code>
        Mọi giá trị tính theo <code class="font-mono">servingSizeG</code>.
        Dòng có <code class="font-mono">barcode</code> trùng sản phẩm đã có sẽ được <strong>cập nhật</strong>, không bỏ qua.
      </p>
      <textarea
        v-model="importContent" rows="10"
        class="w-full border-2 border-rule bg-paper-raised p-2 font-mono text-[12px]"
        placeholder="name,servingSizeG,caloriesKcal&#10;Phở bò,100,58"
      />
      <div v-if="importReport" class="border-2 border-rule p-3">
        <div class="mb-2 font-mono">
          {{ importReport.created }} tạo · {{ importReport.updated }} cập nhật ·
          {{ importReport.skipped }} bỏ qua · {{ importReport.failed }} lỗi
        </div>
        <ul class="max-h-40 space-y-0.5 overflow-y-auto text-[12px]">
          <li v-for="r in importReport.results" :key="r.row" :class="r.status === 'failed' && 'text-accent'">
            <span class="font-mono">#{{ r.row }}</span> {{ r.status }} — {{ r.name ?? '' }} {{ r.message ?? '' }}
          </li>
        </ul>
      </div>
    </div>
    <template #footer>
      <UiButton @click="showImport = false; importReport = null">Đóng</UiButton>
      <UiButton variant="primary" :loading="saving" :disabled="!importContent.trim()" @click="runImport">Nhập</UiButton>
    </template>
  </UiModal>
</template>
