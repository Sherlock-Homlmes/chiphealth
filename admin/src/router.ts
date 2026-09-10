import { createRouter, createWebHistory } from 'vue-router'
import { hasSession } from '@/lib/session'

/**
 * Every screen except /login requires a session. The admin-role check is not done
 * here — the API is the authority, and AppShell renders the "not an admin" state.
 */
const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/login', name: 'login', component: () => import('@/views/LoginView.vue'), meta: { public: true } },
    { path: '/', name: 'dashboard', component: () => import('@/views/DashboardView.vue') },
    { path: '/foods', name: 'foods', component: () => import('@/views/FoodsView.vue') },
    { path: '/barcodes', name: 'barcodes', component: () => import('@/views/BarcodeQueueView.vue') },
    { path: '/kb', name: 'kb', component: () => import('@/views/KbView.vue') },
    { path: '/search', name: 'search', component: () => import('@/views/SearchPlaygroundView.vue') },
    { path: '/catalogs', name: 'catalogs', component: () => import('@/views/CatalogsView.vue') },
    { path: '/translations', name: 'translations', component: () => import('@/views/TranslationsView.vue') },
    { path: '/users', name: 'users', component: () => import('@/views/UsersView.vue') },
    { path: '/:pathMatch(.*)*', name: 'not-found', component: () => import('@/views/NotFoundView.vue') },
  ],
  scrollBehavior: () => ({ top: 0 }),
})

router.beforeEach((to) => {
  if (to.meta.public) return true
  if (!hasSession()) return { name: 'login', query: { next: to.fullPath } }
  return true
})

export default router
