import { defineStore } from 'pinia'
import { ref } from 'vue'

export type ToastKind = 'ok' | 'error' | 'info'
export interface Toast { id: number; kind: ToastKind; text: string }

let nextId = 1

export const useToastStore = defineStore('toast', () => {
  const toasts = ref<Toast[]>([])

  function push(kind: ToastKind, text: string): void {
    const id = nextId++
    toasts.value.push({ id, kind, text })
    setTimeout(() => dismiss(id), kind === 'error' ? 8000 : 4000)
  }

  function dismiss(id: number): void {
    toasts.value = toasts.value.filter((t) => t.id !== id)
  }

  return {
    toasts,
    dismiss,
    ok: (text: string) => push('ok', text),
    error: (text: string) => push('error', text),
    info: (text: string) => push('info', text),
  }
})
