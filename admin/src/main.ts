import { createApp } from 'vue'
import { createPinia } from 'pinia'
import App from './App.vue'
import router from './router'
import './style.css'

async function boot() {
  // Dev-only fixtures, so the panel is usable before the API is deployed.
  if (import.meta.env.VITE_USE_MSW === 'true') {
    const { installMockApi } = await import('./lib/mockApi')
    installMockApi()
  }

  const app = createApp(App)
  app.use(createPinia())
  app.use(router)
  app.mount('#app')
}

void boot()
