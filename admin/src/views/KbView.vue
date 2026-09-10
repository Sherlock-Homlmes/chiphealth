<script setup lang="ts">
import { onMounted, ref, reactive } from 'vue'
import { api, errorMessage, fieldIssues } from '@/lib/api'
import UiCard from '@/components/UiCard.vue'
import UiState from '@/components/UiState.vue'
import UiButton from '@/components/UiButton.vue'
import UiInput from '@/components/UiInput.vue'
import UiBadge from '@/components/UiBadge.vue'
import UiField from '@/components/UiField.vue'
import UiModal from '@/components/UiModal.vue'
import { useToastStore } from '@/stores/toast'
import type { KbDocument, KbDocumentInput } from '@/lib/types'

const toast = useToastStore()
const items = ref<KbDocument[]>([])
const cursor = ref<string | null>(null)
const loading = ref(true)
const error = ref<string | null>(null)
const saving = ref(false)
const query = ref('')

const editing = ref<KbDocument | null>(null)
const showForm = ref(false)
const serverIssues = ref<Record<string, string>>({})
const form = reactive<KbDocumentInput>({ title: '', content: '', locale: 'vi', isActive: true, foodId: null })

async function load(reset = true) {
  if (reset) { loading.value = true; error.value = null }
  try {
    const page = await api.kb.list({ q: query.value || undefined, cursor: reset ? undefined : cursor.value })
    items.value = reset ? page.items : [...items.value, ...page.items]
    cursor.value = page.nextCursor
  } catch (err) {
    error.value = errorMessage(err)
  } finally {
    loading.value = false
  }
}
onMounted(() => load())

function openCreate() {
  editing.value = null
  Object.assign(form, { title: '', content: '', locale: 'vi', isActive: true, foodId: null })
  serverIssues.value = {}
  showForm.value = true
}

function openEdit(doc: KbDocument) {
  editing.value = doc
  Object.assign(form, { title: doc.title, content: doc.content, locale: doc.locale, isActive: doc.isActive, foodId: doc.foodId })
  serverIssues.value = {}
  showForm.value = true
}

async function save() {
  if (!form.title.trim() || !form.content.trim()) {
    serverIssues.value = { title: !form.title.trim() ? 'Bắt buộc' : '', content: !form.content.trim() ? 'Bắt buộc' : '' }
    return
  }
  saving.value = true
  serverIssues.value = {}
  try {
    if (editing.value) await api.kb.update(editing.value.id, { ...form })
    else await api.kb.create({ ...form })
    // Editing the text marks the vector stale; the server re-embeds in the background.
    toast.ok('Đã lưu — đang tạo lại vector')
    showForm.value = false
    await load()
  } catch (err) {
    serverIssues.value = fieldIssues(err)
    toast.error(errorMessage(err))
  } finally {
    saving.value = false
  }
}

async function reindex(doc: KbDocument) {
  try {
    const updated = await api.kb.reindex(doc.id)
    Object.assign(doc, updated)
    toast.ok('Đã đánh chỉ mục lại')
  } catch (err) {
    toast.error(errorMessage(err))
  }
}

async function reindexAll() {
  try {
    const res = await api.kb.reindexAll()
    toast.ok(`Đã xếp hàng ${res.queued} tài liệu`)
  } catch (err) {
    toast.error(errorMessage(err))
  }
}

async function remove(doc: KbDocument) {
  if (!confirm(`Xoá "${doc.title}"?`)) return
  try {
    await api.kb.remove(doc.id)
    items.value = items.value.filter((d) => d.id !== doc.id)
    toast.ok('Đã xoá')
  } catch (err) {
    toast.error(errorMessage(err))
  }
}

const tone = (s: KbDocument['embeddingStatus']) =>
  s === 'indexed' ? 'ok' : s === 'failed' ? 'accent' : 'warn'
</script>

<template>
  <div class="mb-1 flex items-center gap-3">
    <h1 class="text-2xl font-semibold tracking-tight">Kho RAG</h1>
    <div class="ml-auto flex gap-2">
      <UiButton @click="reindexAll">Đánh chỉ mục lại tất cả</UiButton>
      <UiButton variant="primary" @click="openCreate">Thêm tài liệu</UiButton>
    </div>
  </div>
  <p class="mb-5 max-w-2xl text-[13px] text-ink-soft">
    Kiến thức nền để AI đoán thành phần món ăn: cách nấu, khẩu phần chuẩn, bảng dinh dưỡng.
    Mỗi tài liệu vừa vào FTS5 (BM25) vừa vào Vectorize, hai kết quả được trộn bằng RRF.
  </p>

  <UiCard>
    <div class="flex gap-2 border-b-2 border-rule px-4 py-3">
      <UiInput v-model="query" placeholder="Tìm tiêu đề…" class="max-w-64" @keyup.enter="load()" />
      <UiButton @click="load()">Tìm</UiButton>
    </div>

    <UiState :loading="loading" :error="error" :empty="items.length === 0" empty-text="Chưa có tài liệu nào">
      <template #retry><UiButton size="sm" class="ml-3" @click="load()">Thử lại</UiButton></template>

      <div class="overflow-x-auto">
        <table class="w-full border-collapse text-[13px]">
          <thead>
            <tr class="border-b-2 border-rule text-left text-[11px] tracking-wide text-ink-soft uppercase">
              <th class="px-4 py-2">Tiêu đề</th>
              <th class="px-2 py-2">Ngôn ngữ</th>
              <th class="px-2 py-2">Vector</th>
              <th class="px-2 py-2">Model</th>
              <th class="px-4 py-2"></th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="doc in items" :key="doc.id" class="border-b border-rule-soft hover:bg-paper-sunk">
              <td class="px-4 py-2">
                <button class="text-left font-medium hover:text-accent" @click="openEdit(doc)">{{ doc.title }}</button>
                <div class="max-w-lg truncate text-[12px] text-ink-faint">{{ doc.content }}</div>
              </td>
              <td class="px-2 py-2"><UiBadge>{{ doc.locale }}</UiBadge></td>
              <td class="px-2 py-2"><UiBadge :tone="tone(doc.embeddingStatus)">{{ doc.embeddingStatus ?? 'pending' }}</UiBadge></td>
              <td class="px-2 py-2 font-mono text-[11px] text-ink-faint">{{ doc.embeddingModel ?? '—' }}</td>
              <td class="px-4 py-2">
                <div class="flex justify-end gap-1">
                  <UiButton size="sm" @click="reindex(doc)">reindex</UiButton>
                  <UiButton size="sm" variant="danger" @click="remove(doc)">xoá</UiButton>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div v-if="cursor" class="border-t-2 border-rule px-4 py-3">
        <UiButton @click="load(false)">Tải thêm</UiButton>
      </div>
    </UiState>
  </UiCard>

  <UiModal v-if="showForm" :title="editing ? 'Sửa tài liệu' : 'Thêm tài liệu'" wide @close="showForm = false">
    <div class="space-y-3">
      <UiField label="Tiêu đề" required :error="serverIssues.title">
        <UiInput v-model="form.title" :invalid="!!serverIssues.title" />
      </UiField>
      <UiField label="Nội dung" required :error="serverIssues.content" hint="một đoạn = một chunk embed">
        <textarea
          v-model="form.content" rows="12"
          class="w-full border-2 bg-paper-raised p-2 text-[13px] outline-none focus:border-accent"
          :class="serverIssues.content ? 'border-accent' : 'border-rule'"
        />
      </UiField>
      <div class="grid gap-3 sm:grid-cols-2">
        <UiField label="Ngôn ngữ">
          <select v-model="form.locale" class="w-full border-2 border-rule bg-paper-raised px-2 py-1.5">
            <option value="vi">vi</option>
            <option value="en">en</option>
          </select>
        </UiField>
        <UiField label="Gắn với food id" hint="tuỳ chọn">
          <UiInput v-model="form.foodId" mono placeholder="uuid" />
        </UiField>
      </div>
      <label class="flex items-center gap-2">
        <input v-model="form.isActive" type="checkbox" class="size-4 border-2 border-rule" />
        <span class="text-[13px]">Đang dùng cho truy hồi</span>
      </label>
    </div>
    <template #footer>
      <UiButton @click="showForm = false">Huỷ</UiButton>
      <UiButton variant="primary" :loading="saving" @click="save">Lưu</UiButton>
    </template>
  </UiModal>
</template>
