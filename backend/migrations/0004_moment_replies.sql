-- Locket-style replies: a message written under someone's moment, delivered to
-- whoever posted it. `read_at` is the recipient's, so the inbox can show an
-- unread count without a second table.
CREATE TABLE `moment_replies` (
	`id` text PRIMARY KEY NOT NULL,
	`moment_post_id` text NOT NULL,
	`user_id` text NOT NULL,
	`body` text NOT NULL,
	`created_at` integer NOT NULL,
	`read_at` integer,
	FOREIGN KEY (`moment_post_id`) REFERENCES `moment_posts`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);--> statement-breakpoint
CREATE INDEX `moment_replies_post_idx` ON `moment_replies` (`moment_post_id`,`created_at`);--> statement-breakpoint
-- The SSE stream and the inbox both ask "what arrived for me since T".
CREATE INDEX `moment_replies_created_idx` ON `moment_replies` (`created_at`);
