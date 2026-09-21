import { sqliteTable, text, integer, real, index, uniqueIndex, check } from 'drizzle-orm/sqlite-core';
import { sql } from 'drizzle-orm';
import { pkUuid, ts, tsNow, bool } from './_shared';
import { users, mediaAssets } from './core';

export const FOOD_SOURCES = [
  'admin_barcode', 'admin_manual', 'rag_matched', 'web_search', 'ai_estimated',
] as const;
export const MEAL_TYPES = ['breakfast', 'lunch', 'dinner', 'snack'] as const;
export const AI_JOB_STATUSES = ['pending', 'running', 'completed', 'failed'] as const;
export const MEAL_PLAN_STATUSES = ['suggested', 'accepted', 'skipped', 'expired'] as const;
export const BARCODE_MISS_STATUSES = ['pending', 'resolved', 'rejected'] as const;
export const EMBEDDING_STATUSES = ['pending', 'indexed', 'failed'] as const;

/**
 * Global food database. Resolution order when analysing a photo:
 * barcode -> hybrid RAG (FTS5 BM25 + Vectorize, RRF) -> user_foods -> web -> AI guess.
 */
export const foods = sqliteTable('foods', {
  id: pkUuid(),
  /** Admin-entered only. Users can scan a barcode but never create one. */
  barcode: text('barcode').unique(),
  name: text('name').notNull(),
  brand: text('brand'),
  category: text('category'),
  /** Every nutrient column below is per this amount. */
  servingSizeG: real('serving_size_g').notNull().default(100),
  servingLabel: text('serving_label'),
  caloriesKcal: real('calories_kcal').notNull(),
  proteinG: real('protein_g'),
  carbsG: real('carbs_g'),
  fatG: real('fat_g'),
  saturatedFatG: real('saturated_fat_g'),
  fiberG: real('fiber_g'),
  sugarG: real('sugar_g'),
  sodiumMg: real('sodium_mg'),
  cholesterolMg: real('cholesterol_mg'),
  potassiumMg: real('potassium_mg'),
  calciumMg: real('calcium_mg'),
  ironMg: real('iron_mg'),
  micronutrientsJson: text('micronutrients_json'),
  source: text('source', { enum: FOOD_SOURCES }).notNull(),
  sourceUrl: text('source_url'),
  isVerified: bool('is_verified', false),
  embeddingStatus: text('embedding_status', { enum: EMBEDDING_STATUSES }),
  createdBy: text('created_by').references(() => users.id),
  createdAt: tsNow('created_at'),
  updatedAt: tsNow('updated_at'),
}, (t) => [
  index('foods_name_idx').on(t.name),
  check('foods_source_ck',
    sql`${t.source} in ('admin_barcode','admin_manual','rag_matched','web_search','ai_estimated')`),
]);

/**
 * A user scanning an unknown barcode gets "chưa có dữ liệu" in the app and the
 * code lands here. Aggregated by barcode — repeat scans bump scan_count, which
 * is the priority signal for the admin queue.
 */
export const barcodeScanMisses = sqliteTable('barcode_scan_misses', {
  id: pkUuid(),
  barcode: text('barcode').notNull().unique(),
  scanCount: integer('scan_count').notNull().default(1),
  firstScannedBy: text('first_scanned_by').references(() => users.id),
  productNameHint: text('product_name_hint'),
  photoAssetId: text('photo_asset_id').references(() => mediaAssets.id),
  status: text('status', { enum: BARCODE_MISS_STATUSES }).notNull().default('pending'),
  resolvedFoodId: text('resolved_food_id').references(() => foods.id),
  resolvedBy: text('resolved_by').references(() => users.id),
  resolvedAt: ts('resolved_at'),
  adminNote: text('admin_note'),
  firstScannedAt: tsNow('first_scanned_at'),
  lastScannedAt: tsNow('last_scanned_at'),
}, (t) => [
  index('barcode_misses_queue_idx').on(t.status, t.scanCount),
  check('barcode_misses_status_ck', sql`${t.status} in ('pending','resolved','rejected')`),
]);

/**
 * Admin-managed RAG corpus. D1 holds the text + metadata, the vector lives in
 * Vectorize, BM25 comes from the food_kb_fts virtual table.
 */
export const foodKbDocuments = sqliteTable('food_kb_documents', {
  id: pkUuid(),
  title: text('title').notNull(),
  content: text('content').notNull(),
  foodId: text('food_id').references(() => foods.id),
  locale: text('locale').notNull().default('vi'),
  vectorizeId: text('vectorize_id').unique(),
  embeddingModel: text('embedding_model'),
  embeddingStatus: text('embedding_status', { enum: EMBEDDING_STATUSES }),
  uploadedBy: text('uploaded_by').notNull().references(() => users.id),
  isActive: bool('is_active', true),
  createdAt: tsNow('created_at'),
  updatedAt: tsNow('updated_at'),
});

/** Per-user food base — the same dish differs between people. */
export const userFoods = sqliteTable('user_foods', {
  id: pkUuid(),
  userId: text('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  basedOnFoodId: text('based_on_food_id').references(() => foods.id),
  name: text('name').notNull(),
  servingSizeG: real('serving_size_g').notNull().default(100),
  servingLabel: text('serving_label'),
  caloriesKcal: real('calories_kcal').notNull(),
  proteinG: real('protein_g'),
  carbsG: real('carbs_g'),
  fatG: real('fat_g'),
  saturatedFatG: real('saturated_fat_g'),
  fiberG: real('fiber_g'),
  sugarG: real('sugar_g'),
  sodiumMg: real('sodium_mg'),
  cholesterolMg: real('cholesterol_mg'),
  micronutrientsJson: text('micronutrients_json'),
  isRecipe: bool('is_recipe', false),
  usageCount: integer('usage_count').notNull().default(0),
  lastUsedAt: ts('last_used_at'),
  notes: text('notes'),
  createdAt: tsNow('created_at'),
  updatedAt: tsNow('updated_at'),
}, (t) => [
  index('user_foods_user_name_idx').on(t.userId, t.name),
]);

export const userFoodIngredients = sqliteTable('user_food_ingredients', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  userFoodId: text('user_food_id').notNull().references(() => userFoods.id, { onDelete: 'cascade' }),
  foodId: text('food_id').references(() => foods.id),
  ingredientName: text('ingredient_name').notNull(),
  quantityG: real('quantity_g').notNull(),
  createdAt: tsNow('created_at'),
}, (t) => [
  index('user_food_ingredients_parent_idx').on(t.userFoodId),
]);

export const mealPlans = sqliteTable('meal_plans', {
  id: pkUuid(),
  userId: text('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  planDate: text('plan_date').notNull(),
  mealType: text('meal_type', { enum: MEAL_TYPES }).notNull(),
  title: text('title').notNull(),
  description: text('description'),
  targetCaloriesKcal: real('target_calories_kcal'),
  targetProteinG: real('target_protein_g'),
  targetCarbsG: real('target_carbs_g'),
  targetFatG: real('target_fat_g'),
  suggestedFoodId: text('suggested_food_id').references(() => foods.id),
  suggestedUserFoodId: text('suggested_user_food_id').references(() => userFoods.id),
  /** Why the coach picked this — surfaced in the UI. */
  rationale: text('rationale'),
  generatedByModel: text('generated_by_model'),
  status: text('status', { enum: MEAL_PLAN_STATUSES }).notNull().default('suggested'),
  createdAt: tsNow('created_at'),
  updatedAt: tsNow('updated_at'),
}, (t) => [
  index('meal_plans_user_date_idx').on(t.userId, t.planDate),
]);

export const mealLogs = sqliteTable('meal_logs', {
  id: pkUuid(),
  userId: text('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  mealType: text('meal_type', { enum: MEAL_TYPES }).notNull(),
  photoAssetId: text('photo_asset_id').references(() => mediaAssets.id),
  loggedAt: integer('logged_at').notNull(),
  /** YYYY-MM-DD in the user tz — the daily grouping key. */
  localDate: text('local_date').notNull(),
  /** What the dish is called, as the vision model named it. Null until analysed. */
  dishName: text('dish_name'),
  note: text('note'),
  totalCaloriesKcal: real('total_calories_kcal').notNull().default(0),
  totalProteinG: real('total_protein_g').notNull().default(0),
  totalCarbsG: real('total_carbs_g').notNull().default(0),
  totalFatG: real('total_fat_g').notNull().default(0),
  totalFiberG: real('total_fiber_g'),
  totalSugarG: real('total_sugar_g'),
  totalSodiumMg: real('total_sodium_mg'),
  /** Fluid the meal carried, summed from its items. Null until analysed. */
  totalWaterMl: real('total_water_ml'),
  fromMealPlanId: text('from_meal_plan_id').references(() => mealPlans.id),
  createdAt: tsNow('created_at'),
  updatedAt: tsNow('updated_at'),
}, (t) => [
  index('meal_logs_user_date_idx').on(t.userId, t.localDate),
  // How the diary actually pages: newest eaten first, id breaking ties.
  index('meal_logs_user_logged_idx').on(t.userId, t.loggedAt, t.id),
  check('meal_logs_type_ck', sql`${t.mealType} in ('breakfast','lunch','dinner','snack')`),
]);

export const ANALYSIS_FEEDBACK = ['up', 'down'] as const;

/** Immutable record of one AI analysis attempt — the fine-tuning corpus. */
export const mealAiAnalyses = sqliteTable('meal_ai_analyses', {
  id: pkUuid(),
  mealLogId: text('meal_log_id').notNull().references(() => mealLogs.id, { onDelete: 'cascade' }),
  status: text('status', { enum: AI_JOB_STATUSES }).notNull().default('pending'),
  model: text('model').notNull(),
  promptVersion: text('prompt_version').notNull(),
  rawResponseJson: text('raw_response_json'),
  /** {bm25:[...], vector:[...], fused:[...]} with ids and RRF scores. */
  retrievalJson: text('retrieval_json'),
  webSourcesJson: text('web_sources_json'),
  overallConfidence: real('overall_confidence'),
  latencyMs: integer('latency_ms'),
  errorMessage: text('error_message'),
  /** The user's thumb on this analysis: 'up', 'down', or null for no verdict. */
  userFeedback: text('user_feedback', { enum: ANALYSIS_FEEDBACK }),
  feedbackAt: ts('feedback_at'),
  createdAt: tsNow('created_at'),
  completedAt: ts('completed_at'),
}, (t) => [
  index('meal_ai_analyses_meal_idx').on(t.mealLogId),
  index('meal_ai_analyses_latest_idx').on(t.mealLogId, t.id),
  // The 15-minute sweeper: runs still open, and old.
  index('meal_ai_analyses_open_idx').on(t.status, t.createdAt),
]);

/**
 * One row per detected component. Live columns hold the current (possibly
 * user-corrected) values; ai_predicted_json keeps the original guess, so a
 * corrected row is a (prediction, ground truth) pair with no second table.
 */
export const mealItems = sqliteTable('meal_items', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  mealLogId: text('meal_log_id').notNull().references(() => mealLogs.id, { onDelete: 'cascade' }),
  foodId: text('food_id').references(() => foods.id),
  userFoodId: text('user_food_id').references(() => userFoods.id),
  ingredientName: text('ingredient_name').notNull(),
  quantityG: real('quantity_g').notNull(),
  quantityLabel: text('quantity_label'),
  caloriesKcal: real('calories_kcal').notNull(),
  proteinG: real('protein_g'),
  carbsG: real('carbs_g'),
  fatG: real('fat_g'),
  saturatedFatG: real('saturated_fat_g'),
  fiberG: real('fiber_g'),
  sugarG: real('sugar_g'),
  sodiumMg: real('sodium_mg'),
  cholesterolMg: real('cholesterol_mg'),
  /**
   * Fluid this component carries, in ml — the whole volume for a drink, the
   * water content for a food. Estimated by the model rather than scaled from
   * the food base, which holds no water column.
   */
  waterMl: real('water_ml'),
  source: text('source', { enum: FOOD_SOURCES }).notNull(),
  confidence: real('confidence'),
  aiPredictedJson: text('ai_predicted_json'),
  isUserCorrected: bool('is_user_corrected', false),
  correctedAt: ts('corrected_at'),
  createdAt: tsNow('created_at'),
}, (t) => [
  index('meal_items_meal_idx').on(t.mealLogId),
]);

export const dailyNutritionSummaries = sqliteTable('daily_nutrition_summaries', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  userId: text('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  localDate: text('local_date').notNull(),
  caloriesConsumedKcal: real('calories_consumed_kcal').notNull().default(0),
  proteinG: real('protein_g'),
  carbsG: real('carbs_g'),
  fatG: real('fat_g'),
  fiberG: real('fiber_g'),
  sugarG: real('sugar_g'),
  sodiumMg: real('sodium_mg'),
  /** Mifflin-St Jeor from profile + latest body metrics. */
  bmrKcal: real('bmr_kcal'),
  tdeeKcal: real('tdee_kcal'),
  caloriesBurnedWorkoutKcal: real('calories_burned_workout_kcal').notNull().default(0),
  /** consumed - tdee; negative = deficit. */
  calorieBalanceKcal: real('calorie_balance_kcal'),
  mealsLogged: integer('meals_logged').notNull().default(0),
  createdAt: tsNow('created_at'),
  updatedAt: tsNow('updated_at'),
}, (t) => [
  uniqueIndex('daily_nutrition_uq').on(t.userId, t.localDate),
]);
