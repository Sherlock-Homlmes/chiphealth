-- Write proposals from the AI assistant. The agent never writes health data on
-- its own: every create/update/delete tool call becomes a row here, and only the
-- user's "Xác nhận" executes it (POST /v1/coach/actions/:id/confirm).
CREATE TABLE `coach_actions` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`conversation_id` text NOT NULL,
	`message_id` integer,
	`tool` text NOT NULL,
	`args_json` text NOT NULL,
	`summary` text NOT NULL,
	`details_json` text,
	`status` text DEFAULT 'pending' NOT NULL,
	`result_json` text,
	`error_message` text,
	`created_at` integer NOT NULL,
	`resolved_at` integer,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`conversation_id`) REFERENCES `coach_conversations`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`message_id`) REFERENCES `coach_messages`(`id`) ON UPDATE no action ON DELETE set null,
	CONSTRAINT "coach_actions_status_ck" CHECK("coach_actions"."status" in ('pending','confirmed','cancelled','failed','expired'))
);
--> statement-breakpoint
CREATE INDEX `coach_actions_conversation_idx` ON `coach_actions` (`conversation_id`);--> statement-breakpoint
CREATE INDEX `coach_actions_user_idx` ON `coach_actions` (`user_id`,`created_at`);
