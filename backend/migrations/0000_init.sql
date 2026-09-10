CREATE TABLE `auth_sessions` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`refresh_token_hash` text NOT NULL,
	`device_name` text,
	`platform` text,
	`app_version` text,
	`ip_address` text,
	`expires_at` integer NOT NULL,
	`revoked_at` integer,
	`last_used_at` integer,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `auth_sessions_refresh_token_hash_unique` ON `auth_sessions` (`refresh_token_hash`);--> statement-breakpoint
CREATE INDEX `auth_sessions_user_idx` ON `auth_sessions` (`user_id`);--> statement-breakpoint
CREATE TABLE `media_assets` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text,
	`kind` text NOT NULL,
	`r2_bucket` text NOT NULL,
	`r2_key` text NOT NULL,
	`mime_type` text NOT NULL,
	`byte_size` integer,
	`width` integer,
	`height` integer,
	`duration_ms` integer,
	`checksum_sha256` text,
	`is_orphan` integer DEFAULT true NOT NULL,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE no action,
	CONSTRAINT "media_assets_kind_ck" CHECK("media_assets"."kind" in ('meal_photo','moment_photo','avatar','sleep_audio_clip','workout_stream'))
);
--> statement-breakpoint
CREATE UNIQUE INDEX `media_assets_r2_key_unique` ON `media_assets` (`r2_key`);--> statement-breakpoint
CREATE INDEX `media_assets_orphan_idx` ON `media_assets` (`is_orphan`,`created_at`);--> statement-breakpoint
CREATE TABLE `push_tokens` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`token` text NOT NULL,
	`platform` text NOT NULL,
	`is_active` integer DEFAULT true NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `push_tokens_token_unique` ON `push_tokens` (`token`);--> statement-breakpoint
CREATE INDEX `push_tokens_user_active_idx` ON `push_tokens` (`user_id`,`is_active`);--> statement-breakpoint
CREATE TABLE `users` (
	`id` text PRIMARY KEY NOT NULL,
	`google_sub` text NOT NULL,
	`email` text NOT NULL,
	`email_verified` integer DEFAULT true NOT NULL,
	`display_name` text,
	`avatar_asset_id` text,
	`avatar_remote_url` text,
	`role` text DEFAULT 'user' NOT NULL,
	`locale` text DEFAULT 'vi' NOT NULL,
	`unit_system` text DEFAULT 'metric' NOT NULL,
	`timezone` text DEFAULT 'Asia/Ho_Chi_Minh' NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	`deleted_at` integer,
	FOREIGN KEY (`avatar_asset_id`) REFERENCES `media_assets`(`id`) ON UPDATE no action ON DELETE no action,
	CONSTRAINT "users_role_ck" CHECK("users"."role" in ('user','admin')),
	CONSTRAINT "users_unit_ck" CHECK("users"."unit_system" in ('metric','imperial'))
);
--> statement-breakpoint
CREATE UNIQUE INDEX `users_google_sub_unique` ON `users` (`google_sub`);--> statement-breakpoint
CREATE UNIQUE INDEX `users_email_unique` ON `users` (`email`);--> statement-breakpoint
CREATE TABLE `activity_types` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`code` text NOT NULL,
	`category` text NOT NULL,
	`default_met` real NOT NULL,
	`supports_gps` integer DEFAULT false NOT NULL,
	`supports_sets` integer DEFAULT false NOT NULL,
	`supports_heart_rate` integer DEFAULT true NOT NULL,
	`icon_name` text,
	`sort_order` integer DEFAULT 0 NOT NULL,
	`is_active` integer DEFAULT true NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `activity_types_code_unique` ON `activity_types` (`code`);--> statement-breakpoint
CREATE TABLE `body_metrics_logs` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`user_id` text NOT NULL,
	`recorded_at` integer NOT NULL,
	`local_date` text NOT NULL,
	`weight_kg` real,
	`height_cm` real,
	`body_fat_percent` real,
	`muscle_mass_kg` real,
	`waist_cm` real,
	`source` text DEFAULT 'manual' NOT NULL,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `body_metrics_user_recorded_idx` ON `body_metrics_logs` (`user_id`,`recorded_at`);--> statement-breakpoint
CREATE TABLE `chronic_conditions` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`description` text NOT NULL,
	`diagnosed_on` text,
	`notes` text,
	`is_active` integer DEFAULT true NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `chronic_conditions_user_active_idx` ON `chronic_conditions` (`user_id`,`is_active`);--> statement-breakpoint
CREATE TABLE `goals` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`goal_type` text NOT NULL,
	`target_value` real,
	`target_unit` text,
	`start_value` real NOT NULL,
	`deadline` text,
	`priority` integer DEFAULT 0 NOT NULL,
	`status` text DEFAULT 'active' NOT NULL,
	`completed_at` integer,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	CONSTRAINT "goals_status_ck" CHECK("goals"."status" in ('active','completed','abandoned'))
);
--> statement-breakpoint
CREATE INDEX `goals_user_status_idx` ON `goals` (`user_id`,`status`);--> statement-breakpoint
CREATE TABLE `translations` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`entity_type` text NOT NULL,
	`entity_id` text NOT NULL,
	`locale` text NOT NULL,
	`field` text NOT NULL,
	`value` text NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `translations_uq` ON `translations` (`entity_type`,`entity_id`,`locale`,`field`);--> statement-breakpoint
CREATE TABLE `user_activity_preferences` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`user_id` text NOT NULL,
	`activity_type_id` integer NOT NULL,
	`skill_level` text,
	`weekly_target_sessions` integer,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`activity_type_id`) REFERENCES `activity_types`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE UNIQUE INDEX `user_activity_pref_uq` ON `user_activity_preferences` (`user_id`,`activity_type_id`);--> statement-breakpoint
CREATE TABLE `user_profiles` (
	`user_id` text PRIMARY KEY NOT NULL,
	`date_of_birth` text,
	`biological_sex` text,
	`activity_level` text DEFAULT 'moderate' NOT NULL,
	`max_heart_rate_override` integer,
	`resting_heart_rate` integer,
	`lactate_threshold_hr` integer,
	`target_sleep_minutes` integer DEFAULT 480 NOT NULL,
	`bedtime_target` text,
	`waketime_target` text,
	`onboarding_completed_at` integer,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	CONSTRAINT "user_profiles_sex_ck" CHECK("user_profiles"."biological_sex" is null or "user_profiles"."biological_sex" in ('male','female')),
	CONSTRAINT "user_profiles_activity_ck" CHECK("user_profiles"."activity_level" in ('sedentary','light','moderate','active','very_active'))
);
--> statement-breakpoint
CREATE TABLE `daily_activity_summaries` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`user_id` text NOT NULL,
	`local_date` text NOT NULL,
	`steps` integer,
	`active_calories_kcal` real,
	`resting_calories_kcal` real,
	`exercise_minutes` integer,
	`avg_resting_hr` integer,
	`is_estimated` integer DEFAULT false NOT NULL,
	`source` text,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `daily_activity_uq` ON `daily_activity_summaries` (`user_id`,`local_date`);--> statement-breakpoint
CREATE TABLE `health_connections` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`platform` text NOT NULL,
	`is_enabled` integer DEFAULT true NOT NULL,
	`granted_scopes` text,
	`last_synced_at` integer,
	`last_sync_error` text,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `health_connections_uq` ON `health_connections` (`user_id`,`platform`);--> statement-breakpoint
CREATE TABLE `health_sync_cursors` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`user_id` text NOT NULL,
	`data_type` text NOT NULL,
	`last_record_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `health_sync_cursors_uq` ON `health_sync_cursors` (`user_id`,`data_type`);--> statement-breakpoint
CREATE TABLE `barcode_scan_misses` (
	`id` text PRIMARY KEY NOT NULL,
	`barcode` text NOT NULL,
	`scan_count` integer DEFAULT 1 NOT NULL,
	`first_scanned_by` text,
	`product_name_hint` text,
	`photo_asset_id` text,
	`status` text DEFAULT 'pending' NOT NULL,
	`resolved_food_id` text,
	`resolved_by` text,
	`resolved_at` integer,
	`admin_note` text,
	`first_scanned_at` integer NOT NULL,
	`last_scanned_at` integer NOT NULL,
	FOREIGN KEY (`first_scanned_by`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`photo_asset_id`) REFERENCES `media_assets`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`resolved_food_id`) REFERENCES `foods`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`resolved_by`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE no action,
	CONSTRAINT "barcode_misses_status_ck" CHECK("barcode_scan_misses"."status" in ('pending','resolved','rejected'))
);
--> statement-breakpoint
CREATE UNIQUE INDEX `barcode_scan_misses_barcode_unique` ON `barcode_scan_misses` (`barcode`);--> statement-breakpoint
CREATE INDEX `barcode_misses_queue_idx` ON `barcode_scan_misses` (`status`,`scan_count`);--> statement-breakpoint
CREATE TABLE `daily_nutrition_summaries` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`user_id` text NOT NULL,
	`local_date` text NOT NULL,
	`calories_consumed_kcal` real DEFAULT 0 NOT NULL,
	`protein_g` real,
	`carbs_g` real,
	`fat_g` real,
	`fiber_g` real,
	`sugar_g` real,
	`sodium_mg` real,
	`bmr_kcal` real,
	`tdee_kcal` real,
	`calories_burned_workout_kcal` real DEFAULT 0 NOT NULL,
	`calorie_balance_kcal` real,
	`meals_logged` integer DEFAULT 0 NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `daily_nutrition_uq` ON `daily_nutrition_summaries` (`user_id`,`local_date`);--> statement-breakpoint
CREATE TABLE `food_kb_documents` (
	`id` text PRIMARY KEY NOT NULL,
	`title` text NOT NULL,
	`content` text NOT NULL,
	`food_id` text,
	`locale` text DEFAULT 'vi' NOT NULL,
	`vectorize_id` text,
	`embedding_model` text,
	`embedding_status` text,
	`uploaded_by` text NOT NULL,
	`is_active` integer DEFAULT true NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`food_id`) REFERENCES `foods`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`uploaded_by`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE UNIQUE INDEX `food_kb_documents_vectorize_id_unique` ON `food_kb_documents` (`vectorize_id`);--> statement-breakpoint
CREATE TABLE `foods` (
	`id` text PRIMARY KEY NOT NULL,
	`barcode` text,
	`name` text NOT NULL,
	`brand` text,
	`category` text,
	`serving_size_g` real DEFAULT 100 NOT NULL,
	`serving_label` text,
	`calories_kcal` real NOT NULL,
	`protein_g` real,
	`carbs_g` real,
	`fat_g` real,
	`saturated_fat_g` real,
	`fiber_g` real,
	`sugar_g` real,
	`sodium_mg` real,
	`cholesterol_mg` real,
	`potassium_mg` real,
	`calcium_mg` real,
	`iron_mg` real,
	`micronutrients_json` text,
	`source` text NOT NULL,
	`source_url` text,
	`is_verified` integer DEFAULT false NOT NULL,
	`embedding_status` text,
	`created_by` text,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`created_by`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE no action,
	CONSTRAINT "foods_source_ck" CHECK("foods"."source" in ('admin_barcode','admin_manual','rag_matched','web_search','ai_estimated'))
);
--> statement-breakpoint
CREATE UNIQUE INDEX `foods_barcode_unique` ON `foods` (`barcode`);--> statement-breakpoint
CREATE INDEX `foods_name_idx` ON `foods` (`name`);--> statement-breakpoint
CREATE TABLE `meal_ai_analyses` (
	`id` text PRIMARY KEY NOT NULL,
	`meal_log_id` text NOT NULL,
	`status` text DEFAULT 'pending' NOT NULL,
	`model` text NOT NULL,
	`prompt_version` text NOT NULL,
	`raw_response_json` text,
	`retrieval_json` text,
	`web_sources_json` text,
	`overall_confidence` real,
	`latency_ms` integer,
	`error_message` text,
	`created_at` integer NOT NULL,
	`completed_at` integer,
	FOREIGN KEY (`meal_log_id`) REFERENCES `meal_logs`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `meal_ai_analyses_meal_idx` ON `meal_ai_analyses` (`meal_log_id`);--> statement-breakpoint
CREATE TABLE `meal_items` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`meal_log_id` text NOT NULL,
	`food_id` text,
	`user_food_id` text,
	`ingredient_name` text NOT NULL,
	`quantity_g` real NOT NULL,
	`quantity_label` text,
	`calories_kcal` real NOT NULL,
	`protein_g` real,
	`carbs_g` real,
	`fat_g` real,
	`saturated_fat_g` real,
	`fiber_g` real,
	`sugar_g` real,
	`sodium_mg` real,
	`cholesterol_mg` real,
	`source` text NOT NULL,
	`confidence` real,
	`ai_predicted_json` text,
	`is_user_corrected` integer DEFAULT false NOT NULL,
	`corrected_at` integer,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`meal_log_id`) REFERENCES `meal_logs`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`food_id`) REFERENCES `foods`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`user_food_id`) REFERENCES `user_foods`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE INDEX `meal_items_meal_idx` ON `meal_items` (`meal_log_id`);--> statement-breakpoint
CREATE TABLE `meal_logs` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`meal_type` text NOT NULL,
	`photo_asset_id` text,
	`logged_at` integer NOT NULL,
	`local_date` text NOT NULL,
	`note` text,
	`total_calories_kcal` real DEFAULT 0 NOT NULL,
	`total_protein_g` real DEFAULT 0 NOT NULL,
	`total_carbs_g` real DEFAULT 0 NOT NULL,
	`total_fat_g` real DEFAULT 0 NOT NULL,
	`total_fiber_g` real,
	`total_sugar_g` real,
	`total_sodium_mg` real,
	`from_meal_plan_id` text,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`photo_asset_id`) REFERENCES `media_assets`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`from_meal_plan_id`) REFERENCES `meal_plans`(`id`) ON UPDATE no action ON DELETE no action,
	CONSTRAINT "meal_logs_type_ck" CHECK("meal_logs"."meal_type" in ('breakfast','lunch','dinner','snack'))
);
--> statement-breakpoint
CREATE INDEX `meal_logs_user_date_idx` ON `meal_logs` (`user_id`,`local_date`);--> statement-breakpoint
CREATE TABLE `meal_plans` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`plan_date` text NOT NULL,
	`meal_type` text NOT NULL,
	`title` text NOT NULL,
	`description` text,
	`target_calories_kcal` real,
	`target_protein_g` real,
	`target_carbs_g` real,
	`target_fat_g` real,
	`suggested_food_id` text,
	`suggested_user_food_id` text,
	`rationale` text,
	`generated_by_model` text,
	`status` text DEFAULT 'suggested' NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`suggested_food_id`) REFERENCES `foods`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`suggested_user_food_id`) REFERENCES `user_foods`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE INDEX `meal_plans_user_date_idx` ON `meal_plans` (`user_id`,`plan_date`);--> statement-breakpoint
CREATE TABLE `user_food_ingredients` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`user_food_id` text NOT NULL,
	`food_id` text,
	`ingredient_name` text NOT NULL,
	`quantity_g` real NOT NULL,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`user_food_id`) REFERENCES `user_foods`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`food_id`) REFERENCES `foods`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE INDEX `user_food_ingredients_parent_idx` ON `user_food_ingredients` (`user_food_id`);--> statement-breakpoint
CREATE TABLE `user_foods` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`based_on_food_id` text,
	`name` text NOT NULL,
	`serving_size_g` real DEFAULT 100 NOT NULL,
	`serving_label` text,
	`calories_kcal` real NOT NULL,
	`protein_g` real,
	`carbs_g` real,
	`fat_g` real,
	`saturated_fat_g` real,
	`fiber_g` real,
	`sugar_g` real,
	`sodium_mg` real,
	`cholesterol_mg` real,
	`micronutrients_json` text,
	`is_recipe` integer DEFAULT false NOT NULL,
	`usage_count` integer DEFAULT 0 NOT NULL,
	`last_used_at` integer,
	`notes` text,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`based_on_food_id`) REFERENCES `foods`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE INDEX `user_foods_user_name_idx` ON `user_foods` (`user_id`,`name`);--> statement-breakpoint
CREATE TABLE `heart_rate_zones` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`user_id` text NOT NULL,
	`zone_number` integer NOT NULL,
	`min_bpm` integer NOT NULL,
	`max_bpm` integer NOT NULL,
	`method` text DEFAULT 'auto_age_based' NOT NULL,
	`max_heart_rate_used` integer NOT NULL,
	`effective_from` integer NOT NULL,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `hr_zones_uq` ON `heart_rate_zones` (`user_id`,`effective_from`,`zone_number`);--> statement-breakpoint
CREATE TABLE `personal_records` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`activity_type_id` integer,
	`exercise_id` integer,
	`metric` text NOT NULL,
	`distance_m` real,
	`value` real NOT NULL,
	`unit` text NOT NULL,
	`achieved_at` integer NOT NULL,
	`workout_session_id` text,
	`strength_set_id` integer,
	`previous_value` real,
	`is_current` integer DEFAULT true NOT NULL,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`activity_type_id`) REFERENCES `activity_types`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`exercise_id`) REFERENCES `workout_exercises`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`workout_session_id`) REFERENCES `workout_sessions`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`strength_set_id`) REFERENCES `workout_strength_sets`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE INDEX `personal_records_user_current_idx` ON `personal_records` (`user_id`,`is_current`);--> statement-breakpoint
CREATE TABLE `workout_exercises` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`code` text NOT NULL,
	`muscle_group` text NOT NULL,
	`equipment` text,
	`is_unilateral` integer DEFAULT false NOT NULL,
	`sort_order` integer DEFAULT 0 NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `workout_exercises_code_unique` ON `workout_exercises` (`code`);--> statement-breakpoint
CREATE TABLE `workout_sessions` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`activity_type_id` integer NOT NULL,
	`source` text DEFAULT 'in_app' NOT NULL,
	`external_id` text,
	`title` text,
	`started_at` integer NOT NULL,
	`ended_at` integer,
	`local_date` text NOT NULL,
	`duration_seconds` integer,
	`moving_seconds` integer,
	`distance_m` real,
	`avg_heart_rate` integer,
	`max_heart_rate` integer,
	`avg_pace_sec_per_km` real,
	`best_pace_sec_per_km` real,
	`avg_cadence` integer,
	`avg_power_w` real,
	`elevation_gain_m` real,
	`calories_burned_kcal` real,
	`calories_are_estimated` integer DEFAULT true NOT NULL,
	`perceived_exertion` integer,
	`notes` text,
	`is_deleted` integer DEFAULT false NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`activity_type_id`) REFERENCES `activity_types`(`id`) ON UPDATE no action ON DELETE no action,
	CONSTRAINT "workout_sessions_source_ck" CHECK("workout_sessions"."source" in ('in_app','health_sync','manual_entry'))
);
--> statement-breakpoint
CREATE INDEX `workout_sessions_user_started_idx` ON `workout_sessions` (`user_id`,`started_at`);--> statement-breakpoint
CREATE UNIQUE INDEX `workout_sessions_external_uq` ON `workout_sessions` (`source`,`external_id`);--> statement-breakpoint
CREATE TABLE `workout_splits` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`workout_session_id` text NOT NULL,
	`split_index` integer NOT NULL,
	`split_distance_m` real DEFAULT 1000 NOT NULL,
	`elapsed_seconds` integer NOT NULL,
	`moving_seconds` integer,
	`avg_heart_rate` integer,
	`elevation_gain_m` real,
	`avg_pace_sec_per_km` real,
	FOREIGN KEY (`workout_session_id`) REFERENCES `workout_sessions`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `workout_splits_uq` ON `workout_splits` (`workout_session_id`,`split_index`);--> statement-breakpoint
CREATE TABLE `workout_streams` (
	`workout_session_id` text PRIMARY KEY NOT NULL,
	`r2_asset_id` text,
	`sample_count` integer,
	`sample_interval_s` real,
	`encoded_polyline` text,
	`downsampled_json` text,
	`start_latitude` real,
	`start_longitude` real,
	`bounds_json` text,
	`has_gps` integer DEFAULT false NOT NULL,
	`has_heart_rate` integer DEFAULT false NOT NULL,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`workout_session_id`) REFERENCES `workout_sessions`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`r2_asset_id`) REFERENCES `media_assets`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE TABLE `workout_strength_sets` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`workout_session_id` text NOT NULL,
	`exercise_id` integer NOT NULL,
	`set_index` integer NOT NULL,
	`reps` integer,
	`weight_kg` real,
	`duration_seconds` integer,
	`distance_m` real,
	`rpe` real,
	`is_warmup` integer DEFAULT false NOT NULL,
	`rest_seconds` integer,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`workout_session_id`) REFERENCES `workout_sessions`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`exercise_id`) REFERENCES `workout_exercises`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE UNIQUE INDEX `workout_sets_uq` ON `workout_strength_sets` (`workout_session_id`,`exercise_id`,`set_index`);--> statement-breakpoint
CREATE TABLE `workout_zone_summaries` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`workout_session_id` text NOT NULL,
	`zone_number` integer NOT NULL,
	`seconds_in_zone` integer NOT NULL,
	`percent_of_session` real,
	FOREIGN KEY (`workout_session_id`) REFERENCES `workout_sessions`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `workout_zone_uq` ON `workout_zone_summaries` (`workout_session_id`,`zone_number`);--> statement-breakpoint
CREATE TABLE `sleep_audio_events` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`sleep_session_id` text NOT NULL,
	`event_type` text NOT NULL,
	`occurred_at` integer NOT NULL,
	`duration_ms` integer,
	`peak_db` real,
	`confidence` real,
	`audio_asset_id` text,
	`transcript` text,
	`stage_at_event` text,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`sleep_session_id`) REFERENCES `sleep_sessions`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`audio_asset_id`) REFERENCES `media_assets`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE INDEX `sleep_audio_events_idx` ON `sleep_audio_events` (`sleep_session_id`,`occurred_at`);--> statement-breakpoint
CREATE TABLE `sleep_debt_daily` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`user_id` text NOT NULL,
	`local_date` text NOT NULL,
	`target_sleep_seconds` integer NOT NULL,
	`actual_sleep_seconds` integer DEFAULT 0 NOT NULL,
	`daily_diff_seconds` integer NOT NULL,
	`rolling_14d_debt_seconds` integer NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `sleep_debt_uq` ON `sleep_debt_daily` (`user_id`,`local_date`);--> statement-breakpoint
CREATE TABLE `sleep_reminders` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`reminder_type` text NOT NULL,
	`remind_at_local` text NOT NULL,
	`days_of_week` text NOT NULL,
	`is_enabled` integer DEFAULT true NOT NULL,
	`last_fired_at` integer,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `sleep_reminders_user_idx` ON `sleep_reminders` (`user_id`,`is_enabled`);--> statement-breakpoint
CREATE TABLE `sleep_sessions` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`source` text NOT NULL,
	`external_id` text,
	`started_at` integer NOT NULL,
	`ended_at` integer,
	`local_date` text NOT NULL,
	`in_bed_seconds` integer,
	`total_sleep_seconds` integer,
	`awake_seconds` integer,
	`light_seconds` integer,
	`deep_seconds` integer,
	`rem_seconds` integer,
	`sleep_latency_seconds` integer,
	`sleep_efficiency` real,
	`sleep_score` integer,
	`avg_heart_rate` integer,
	`stages_are_estimated` integer DEFAULT false NOT NULL,
	`audio_recording_enabled` integer DEFAULT false NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	CONSTRAINT "sleep_sessions_source_ck" CHECK("sleep_sessions"."source" in ('health_sync','phone_mic','manual'))
);
--> statement-breakpoint
CREATE UNIQUE INDEX `sleep_sessions_user_date_uq` ON `sleep_sessions` (`user_id`,`local_date`);--> statement-breakpoint
CREATE UNIQUE INDEX `sleep_sessions_external_uq` ON `sleep_sessions` (`source`,`external_id`);--> statement-breakpoint
CREATE TABLE `sleep_stage_segments` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`sleep_session_id` text NOT NULL,
	`stage` text NOT NULL,
	`started_at` integer NOT NULL,
	`ended_at` integer NOT NULL,
	`confidence` real,
	FOREIGN KEY (`sleep_session_id`) REFERENCES `sleep_sessions`(`id`) ON UPDATE no action ON DELETE cascade,
	CONSTRAINT "sleep_stage_ck" CHECK("sleep_stage_segments"."stage" in ('awake','light','deep','rem'))
);
--> statement-breakpoint
CREATE INDEX `sleep_stage_segments_idx` ON `sleep_stage_segments` (`sleep_session_id`,`started_at`);--> statement-breakpoint
CREATE TABLE `coach_conversations` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`title` text,
	`last_message_at` integer,
	`message_count` integer DEFAULT 0 NOT NULL,
	`is_archived` integer DEFAULT false NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `coach_conversations_user_idx` ON `coach_conversations` (`user_id`,`last_message_at`);--> statement-breakpoint
CREATE TABLE `coach_insights` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`domain` text NOT NULL,
	`local_date` text NOT NULL,
	`period` text NOT NULL,
	`title` text NOT NULL,
	`body` text NOT NULL,
	`severity` text,
	`action_json` text,
	`model` text,
	`is_read` integer DEFAULT false NOT NULL,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `coach_insights_user_date_idx` ON `coach_insights` (`user_id`,`local_date`);--> statement-breakpoint
CREATE TABLE `coach_messages` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`conversation_id` text NOT NULL,
	`role` text NOT NULL,
	`content` text NOT NULL,
	`context_json` text,
	`model` text,
	`prompt_tokens` integer,
	`completion_tokens` integer,
	`latency_ms` integer,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`conversation_id`) REFERENCES `coach_conversations`(`id`) ON UPDATE no action ON DELETE cascade,
	CONSTRAINT "coach_messages_role_ck" CHECK("coach_messages"."role" in ('user','assistant','system'))
);
--> statement-breakpoint
CREATE INDEX `coach_messages_conversation_idx` ON `coach_messages` (`conversation_id`);--> statement-breakpoint
CREATE TABLE `friendships` (
	`id` text PRIMARY KEY NOT NULL,
	`requester_id` text NOT NULL,
	`addressee_id` text NOT NULL,
	`status` text DEFAULT 'pending' NOT NULL,
	`requested_at` integer NOT NULL,
	`responded_at` integer,
	FOREIGN KEY (`requester_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`addressee_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	CONSTRAINT "friendships_status_ck" CHECK("friendships"."status" in ('pending','accepted','blocked'))
);
--> statement-breakpoint
CREATE UNIQUE INDEX `friendships_uq` ON `friendships` (`requester_id`,`addressee_id`);--> statement-breakpoint
CREATE INDEX `friendships_addressee_idx` ON `friendships` (`addressee_id`,`status`);--> statement-breakpoint
CREATE TABLE `moment_posts` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`photo_asset_id` text NOT NULL,
	`caption` text,
	`visibility` text DEFAULT 'friends' NOT NULL,
	`linked_meal_log_id` text,
	`linked_workout_session_id` text,
	`expires_at` integer,
	`created_at` integer NOT NULL,
	`deleted_at` integer,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`photo_asset_id`) REFERENCES `media_assets`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`linked_meal_log_id`) REFERENCES `meal_logs`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`linked_workout_session_id`) REFERENCES `workout_sessions`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE INDEX `moment_posts_user_created_idx` ON `moment_posts` (`user_id`,`created_at`);--> statement-breakpoint
CREATE TABLE `moment_reactions` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`moment_post_id` text NOT NULL,
	`user_id` text NOT NULL,
	`emoji` text NOT NULL,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`moment_post_id`) REFERENCES `moment_posts`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `moment_reactions_uq` ON `moment_reactions` (`moment_post_id`,`user_id`);--> statement-breakpoint
CREATE TABLE `moment_views` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`moment_post_id` text NOT NULL,
	`viewer_id` text NOT NULL,
	`viewed_at` integer NOT NULL,
	FOREIGN KEY (`moment_post_id`) REFERENCES `moment_posts`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`viewer_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `moment_views_uq` ON `moment_views` (`moment_post_id`,`viewer_id`);