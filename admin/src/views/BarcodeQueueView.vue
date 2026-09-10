<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { api, errorMessage, fieldIssues } from '@/lib/api'
import UiCard from '@/components/UiCard.vue'
import UiState from '@/components/UiState.vue'
import UiButton from '@/components/UiButton.vue'
import UiBadge from '@/components/UiBadge.vue'
import UiModal from '@/components/UiModal.vue'
import UiInput from '@/components/UiInput.vue'
import FoodForm from '@/components/FoodForm.vue'
import { useToastStore } from '@/stores/toast'
import type { BarcodeMiss, BarcodeMissStatus, Food, FoodInput } from '@/lib/types'

const toast = useToastStore()
const status = ref<BarcodeMissStatus>('pending')
const items = ref<BarcodeMiss[]>([])
const loading = ref(true)
const error = ref<string | null>(null)
const saving = ref(false)

const resolving = ref<BarcodeMiss | null>(null)
/** Existing product for this barcode, used to prefill the form. */
const prefill = ref<Food | null>(null)
const prefilling = ref(false)
const rejecting = ref<BarcodeMiss | null>(null)
const rejectNote = ref('')
const formRef = ref<InstanceType<typeof FoodForm> | null>(null)
const serverIssues = ref<Record<string, string>>({})

async function load() {
  loading.value = true
  error.value = null
  try {
    items.value = (await api.barcodeMisses.list({ status: status.value })).items
  } catch (err) {
    error.value = errorMessage(err)
  } finally {
    loading.value = false
  }
}
onMounted(load)

async function openResolve(miss: BarcodeMiss) {
  resolving.value = miss
  serverIssues.value = {}
  prefill.value = null

  // If the barcode already has a product, show it filled in rather than making
  // the admin retype a row that exists.
  prefilling.value = true
  try {
    prefill.value = await api.foods.byBarcode(miss.barcode)
  } catch {
    prefill.value = null
  } finally {
    prefilling.value = false
  }
}

async function submitResolve(payload: FoodInput) {
  if (!resolving.value) return
  saving.value = true
  serverIssues.value = {}
  try {
    await api.barcodeMisses.resolve(resolving.value.id, payload)
    toast.ok('Đã thêm sản phẩm — người dùng quét lại sẽ ra kết quả')
    resolving.value = null
    await load()
  } catch (err) {
    serverIssues.value = fieldIssues(err)
    toast.error(errorMessage(err))
  } finally {
    saving.value = false
  }
}

async function submitReject() {
  if (!rejecting.value) return
  saving.value = true
  try {
    await api.barcodeMisses.reject(rejecting.value.id, rejectNote.value)
    toast.ok('Đã bỏ qua mã này')
    rejecting.value = null
    rejectNote.value = ''
    await load()
  } catch (err) {
    toast.error(errorMessage(err))
  } finally {
    saving.value = false
  }
}

const when = (ms: number) => new Date(ms).toLocaleString('vi-VN')
</script>

<template>
  <h1 class="mb-1 text-2xl font-semibold tracking-tight">Hàng đợi mã vạch</h1>
  <p class="mb-5 max-w-2xl text-[13px] text-ink-soft">
    Người dùng quét mã mà app chưa có dữ liệu → app báo “chưa có dữ liệu”, mã rơi vào đây.
    Sắp theo số lần quét, nên món ở trên là món nhiều người cần nhất.
  </p>

  <UiCard>
    <div class="flex gap-2 border-b-2 border-rule px-4 py-3">
      <UiButton
        v-for="s in (['pending', 'resolved', 'rejected'] as BarcodeMissStatus[])"
        :key="s" size="sm"
        :variant="status === s ? 'primary' : 'default'"
        @click="status = s; load()"
      >{{ s }}</UiButton>
    </div>

    <UiState :loading="loading" :error="error" :empty="items.length === 0"
             :empty-text="status === 'pending' ? 'Sạch hàng đợi 🎉' : 'Không có mục nào'">
      <template #retry><UiButton size="sm" class="ml-3" @click="load">Thử lại</UiButton></template>

      <div class="overflow-x-auto">
        <table class="w-full border-collapse text-[13px]">
          <thead>
            <tr class="border-b-2 border-rule text-left text-[11px] tracking-wide text-ink-soft uppercase">
              <th class="px-4 py-2">Mã vạch</th>
              <th class="px-2 py-2 text-right">Lượt quét</th>
              <th class="px-2 py-2">Gợi ý tên</th>
              <th class="px-2 py-2">Ảnh</th>
              <th class="px-2 py-2">Quét gần nhất</th>
              <th class="px-4 py-2"></th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="miss in items" :key="miss.id" class="border-b border-rule-soft hover:bg-paper-sunk">
              <td class="px-4 py-2 font-mono">{{ miss.barcode }}</td>
              <td class="px-2 py-2 text-right">
                <UiBadge :tone="miss.scanCount > 3 ? 'accent' : 'neutral'">{{ miss.scanCount }}</UiBadge>
              </td>
              <td class="px-2 py-2">{{ miss.productNameHint ?? '—' }}</td>
              <td class="px-2 py-2">
                <a v-if="miss.photoUrl" :href="miss.photoUrl" target="_blank" rel="noreferrer">
                  <img :src="miss.photoUrl" alt="bao bì" class="size-10 border-2 border-rule object-cover" />
                </a>
                <span v-else class="text-ink-faint">—</span>
              </td>
              <td class="px-2 py-2 font-mono text-[12px] text-ink-soft">{{ when(miss.lastScannedAt) }}</td>
              <td class="px-4 py-2">
                <div v-if="miss.status === 'pending'" class="flex justify-end gap-1">
                  <UiButton size="sm" variant="primary" @click="openResolve(miss)">Nhập sản phẩm</UiButton>
                  <UiButton size="sm" variant="danger" @click="rejecting = miss">Bỏ qua</UiButton>
                </div>
                <span v-else class="text-ink-faint">{{ miss.adminNote ?? '' }}</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </UiState>
  </UiCard>

  <UiModal v-if="resolving" :title="`Nhập sản phẩm cho ${resolving.barcode}`" wide @close="resolving = null">
    <p v-if="prefilling" class="mb-3 text-[13px] text-ink-soft">Đang kiểm tra mã này…</p>
    <p v-else-if="prefill" class="mb-3 border-2 border-info bg-info-soft px-3 py-2 text-[13px] text-info">
      Mã này đã có sản phẩm “{{ prefill.name }}” — form đã điền sẵn, chỉ cần sửa chỗ cần thiết.
    </p>
    <p v-else-if="resolving.productNameHint" class="mb-3 border-2 border-rule-soft bg-paper-sunk px-3 py-2 text-[13px]">
      Người dùng ghi chú: <strong>{{ resolving.productNameHint }}</strong>
    </p>
    <FoodForm
      ref="formRef"
      :model-value="prefill"
      :locked-barcode="resolving.barcode"
      :name-hint="resolving.productNameHint"
      :server-issues="serverIssues"
      @submit="submitResolve"
    />
    <template #footer>
      <UiButton @click="resolving = null">Huỷ</UiButton>
      <UiButton variant="primary" :loading="saving" @click="formRef?.submit()">Tạo và đóng mục</UiButton>
    </template>
  </UiModal>

  <UiModal v-if="rejecting" :title="`Bỏ qua ${rejecting.barcode}`" @close="rejecting = null">
    <UiInput v-model="rejectNote" placeholder="Lý do (không phải thực phẩm, mã hỏng…)" />
    <template #footer>
      <UiButton @click="rejecting = null">Huỷ</UiButton>
      <UiButton variant="danger" :loading="saving" :disabled="!rejectNote.trim()" @click="submitReject">Bỏ qua</UiButton>
    </template>
  </UiModal>
</template>
