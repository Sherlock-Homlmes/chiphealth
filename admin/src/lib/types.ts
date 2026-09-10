/**
 * Wire types for the ChipHealth API (v1).
 *
 * JSON is camelCase; the DB columns are snake_case (api_design.md §0).
 * Every timestamp is epoch **milliseconds**. Every unit is metric.
 * Enum unions are copied verbatim from db_design.dbml — do not "improve" them.
 */

/* ---------------------------------------------------------------- enums */

export const USER_ROLES = ['user', 'admin'] as const
export type UserRole = (typeof USER_ROLES)[number]

export const UNIT_SYSTEMS = ['metric', 'imperial'] as const
export type UnitSystem = (typeof UNIT_SYSTEMS)[number]

/** foods.source — food_source_enum */
export const FOOD_SOURCES = [
  'admin_barcode',
  'admin_manual',
  'rag_matched',
  'web_search',
  'ai_estimated',
] as const
export type FoodSource = (typeof FOOD_SOURCES)[number]

export const FOOD_SOURCE_LABELS: Record<FoodSource, string> = {
  admin_barcode: 'Admin · barcode',
  admin_manual: 'Admin · manual',
  rag_matched: 'RAG matched',
  web_search: 'Web search',
  ai_estimated: 'AI estimated',
}

/** barcode_scan_misses.status — barcode_miss_status_enum */
export const BARCODE_MISS_STATUSES = ['pending', 'resolved', 'rejected'] as const
export type BarcodeMissStatus = (typeof BARCODE_MISS_STATUSES)[number]

/** foods.embedding_status / food_kb_documents.embedding_status */
export const EMBEDDING_STATUSES = ['pending', 'indexed', 'failed'] as const
export type EmbeddingStatus = (typeof EMBEDDING_STATUSES)[number]

/** activity_types.category — activity_category_enum */
export const ACTIVITY_CATEGORIES = [
  'cardio_gps',
  'cardio_indoor',
  'strength',
  'sport',
  'mind_body',
  'other',
] as const
export type ActivityCategory = (typeof ACTIVITY_CATEGORIES)[number]

export const ACTIVITY_CATEGORY_LABELS: Record<ActivityCategory, string> = {
  cardio_gps: 'Cardio · GPS',
  cardio_indoor: 'Cardio · indoor',
  strength: 'Strength',
  sport: 'Sport',
  mind_body: 'Mind & body',
  other: 'Other',
}

/** translations.entity_type is free text; these are the ones the admin edits. */
export const TRANSLATION_ENTITY_TYPES = [
  'activity_types',
  'workout_exercises',
  'foods',
  'goal_type',
] as const
export type TranslationEntityType = (typeof TRANSLATION_ENTITY_TYPES)[number]

export const LOCALES = ['vi', 'en'] as const
export type Locale = (typeof LOCALES)[number]

/* ---------------------------------------------------------- envelope */

export interface ApiErrorIssue {
  /** zod path, e.g. ["caloriesKcal"] or ["items", 3, "name"] */
  path: (string | number)[]
  message: string
  code?: string
}

export interface ApiErrorBody {
  error: {
    code: string
    message: string
    details?: { issues?: ApiErrorIssue[] } & Record<string, unknown>
  }
}

export interface Page<T> {
  items: T[]
  nextCursor: string | null
}

/* -------------------------------------------------------------- auth */

export interface AuthUser {
  id: string
  email: string
  displayName: string | null
  avatarRemoteUrl: string | null
  role: UserRole
  locale: string
  unitSystem: UnitSystem
  timezone: string
}

export interface AuthTokens {
  accessToken: string
  refreshToken: string
  /** epoch ms */
  expiresAt: number
}

export interface GoogleAuthResponse extends AuthTokens {
  user: AuthUser
}

/* ------------------------------------------------------------- stats */

export interface AdminStats {
  users: number
  foods: number
  pendingBarcodeMisses: number
  kbDocuments: number
  mealsAnalysedToday: number
  /** 0..1 */
  aiFailureRate: number
}

/* ------------------------------------------------------------- foods */

/** Every nutrient below is **per `servingSizeG` grams**. */
export interface Food {
  id: string
  barcode: string | null
  name: string
  brand: string | null
  category: string | null
  servingSizeG: number
  servingLabel: string | null
  caloriesKcal: number
  proteinG: number | null
  carbsG: number | null
  fatG: number | null
  saturatedFatG: number | null
  fiberG: number | null
  sugarG: number | null
  sodiumMg: number | null
  cholesterolMg: number | null
  potassiumMg: number | null
  calciumMg: number | null
  ironMg: number | null
  micronutrientsJson: string | null
  source: FoodSource
  sourceUrl: string | null
  isVerified: boolean
  embeddingStatus: EmbeddingStatus | null
  createdBy: string | null
  createdAt: number
  updatedAt: number
}

/** POST/PATCH /v1/admin/foods body. `source` is derived server-side from `barcode`. */
export interface FoodInput {
  barcode?: string | null
  name: string
  brand?: string | null
  category?: string | null
  servingSizeG: number
  servingLabel?: string | null
  caloriesKcal: number
  proteinG?: number | null
  carbsG?: number | null
  fatG?: number | null
  saturatedFatG?: number | null
  fiberG?: number | null
  sugarG?: number | null
  sodiumMg?: number | null
  cholesterolMg?: number | null
  potassiumMg?: number | null
  calciumMg?: number | null
  ironMg?: number | null
  micronutrientsJson?: string | null
  sourceUrl?: string | null
  isVerified?: boolean
}

export interface FoodListQuery {
  q?: string
  source?: FoodSource | ''
  verified?: boolean | ''
  cursor?: string | null
  limit?: number
}

export interface ImportRowResult {
  row: number
  status: 'created' | 'updated' | 'skipped' | 'failed'
  foodId?: string
  name?: string
  message?: string
}

export interface ImportReport {
  total: number
  created: number
  updated: number
  skipped: number
  failed: number
  results: ImportRowResult[]
}

/* --------------------------------------------------- barcode misses */

export interface BarcodeMiss {
  id: string
  barcode: string
  scanCount: number
  firstScannedBy: string | null
  productNameHint: string | null
  photoAssetId: string | null
  /** convenience URL the API may include so the admin can see the packaging */
  photoUrl: string | null
  status: BarcodeMissStatus
  resolvedFoodId: string | null
  resolvedBy: string | null
  resolvedAt: number | null
  adminNote: string | null
  firstScannedAt: number
  lastScannedAt: number
}

/* ------------------------------------------------------- KB documents */

export interface KbDocument {
  id: string
  title: string
  content: string
  foodId: string | null
  locale: string
  vectorizeId: string | null
  embeddingModel: string | null
  embeddingStatus: EmbeddingStatus | null
  uploadedBy: string
  isActive: boolean
  createdAt: number
  updatedAt: number
}

export interface KbDocumentInput {
  title: string
  content: string
  foodId?: string | null
  locale: string
  isActive?: boolean
}

export interface ReindexAllResult {
  queued: number
}

/* -------------------------------------------------- search preview */

export interface SearchCandidate {
  /** food id or kb document id */
  id: string
  /** which corpus the row came from */
  corpus: 'foods' | 'food_kb_documents'
  title: string
  snippet?: string | null
  /** 1-based rank inside this retriever's own list */
  rank: number
  /** retriever-native score: BM25 rank score, or cosine similarity */
  score: number | null
}

export interface FusedCandidate {
  id: string
  corpus: 'foods' | 'food_kb_documents'
  title: string
  snippet?: string | null
  rank: number
  /** sum of 1 / (rrfK + rank) over the retrievers that returned it */
  fusedScore: number
  /** null when this retriever did not return the row */
  bm25Rank: number | null
  vectorRank: number | null
}

export interface SearchPreview {
  q: string
  rrfK: number
  bm25: SearchCandidate[]
  vector: SearchCandidate[]
  fused: FusedCandidate[]
  tookMs?: number
}

/* --------------------------------------------------------- catalogs */

export interface ActivityType {
  id: number
  code: string
  category: ActivityCategory
  defaultMet: number
  supportsGps: boolean
  supportsSets: boolean
  supportsHeartRate: boolean
  iconName: string | null
  sortOrder: number
  isActive: boolean
  /** resolved display name, when the API joins `translations` */
  name?: string | null
}

export interface ActivityTypeInput {
  code: string
  category: ActivityCategory
  defaultMet: number
  supportsGps: boolean
  supportsSets: boolean
  supportsHeartRate: boolean
  iconName?: string | null
  sortOrder: number
  isActive: boolean
}

export interface WorkoutExercise {
  id: number
  code: string
  muscleGroup: string
  equipment: string | null
  isUnilateral: boolean
  sortOrder: number
  name?: string | null
}

export interface WorkoutExerciseInput {
  code: string
  muscleGroup: string
  equipment?: string | null
  isUnilateral: boolean
  sortOrder: number
}

export const MUSCLE_GROUPS = ['chest', 'back', 'legs', 'shoulders', 'arms', 'core'] as const
export const EQUIPMENT = ['barbell', 'dumbbell', 'machine', 'bodyweight', 'cable', 'kettlebell'] as const

/* ----------------------------------------------------- translations */

export interface Translation {
  id: number
  entityType: string
  entityId: string
  locale: string
  field: string
  value: string
}

export interface TranslationUpsert {
  locale: string
  field: string
  value: string
}

/* ------------------------------------------------------------ users */

export interface AdminUser {
  id: string
  email: string
  displayName: string | null
  avatarRemoteUrl: string | null
  role: UserRole
  locale: string
  timezone: string
  createdAt: number
  deletedAt: number | null
}
