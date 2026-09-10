<script setup lang="ts">
withDefaults(defineProps<{
  variant?: 'primary' | 'default' | 'ghost' | 'danger'
  size?: 'sm' | 'md'
  type?: 'button' | 'submit'
  disabled?: boolean
  loading?: boolean
}>(), { variant: 'default', size: 'md', type: 'button', disabled: false, loading: false })
</script>

<template>
  <button
    :type="type"
    :disabled="disabled || loading"
    class="inline-flex items-center justify-center gap-2 border-2 border-rule font-medium
           transition-[transform,box-shadow] active:translate-x-[2px] active:translate-y-[2px]
           active:shadow-none disabled:cursor-not-allowed disabled:opacity-45
           disabled:active:translate-x-0 disabled:active:translate-y-0"
    :class="[
      size === 'sm' ? 'px-2.5 py-1 text-[13px] shadow-hard-sm' : 'px-3.5 py-2 shadow-hard',
      variant === 'primary' && 'bg-accent text-white',
      variant === 'default' && 'bg-paper-raised text-ink hover:bg-paper-sunk',
      variant === 'ghost' && 'border-transparent bg-transparent shadow-none hover:bg-paper-sunk',
      variant === 'danger' && 'bg-paper-raised text-accent',
    ]"
  >
    <span v-if="loading" class="inline-block size-3 animate-spin border-2 border-current border-t-transparent" />
    <slot />
  </button>
</template>
