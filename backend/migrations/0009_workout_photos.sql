-- Workout photos: up to 5 per session, ordered. Detaching a photo only
-- removes the link (asset goes back to is_orphan = 1); the sweeper collects
-- the R2 object after the orphan TTL, so "unattach" never deletes evidence
-- another row might still point at.
--
-- The assets themselves are uploaded with the existing kind 'meal_photo',
-- same as chat photos (0008): widening media_assets' kind CHECK would mean
-- rebuilding the table under the FKs of six tables, which D1's migration
-- runner cannot do. Revisit if D1 grows ALTER CONSTRAINT.
CREATE TABLE `workout_photos` (
	`workout_session_id` text NOT NULL,
	`asset_id` text NOT NULL,
	`sort_order` integer DEFAULT 0 NOT NULL,
	`created_at` integer NOT NULL,
	PRIMARY KEY (`workout_session_id`,`asset_id`),
	FOREIGN KEY (`workout_session_id`) REFERENCES `workout_sessions`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`asset_id`) REFERENCES `media_assets`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE INDEX `workout_photos_order_idx` ON `workout_photos` (`workout_session_id`,`sort_order`);
