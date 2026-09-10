-- Replies turned out to be direct messages: Instagram-shaped, not Locket-shaped.
-- A message belongs to a conversation between two people, and a reply to a photo
-- is one that happens to pin the moment it answers. Reactions land here too, so
-- everything a friend sends arrives in one list.
CREATE TABLE `moment_messages` (
	`id` text PRIMARY KEY NOT NULL,
	`sender_id` text NOT NULL,
	`recipient_id` text NOT NULL,
	`moment_post_id` text,
	`kind` text DEFAULT 'text' NOT NULL,
	`body` text NOT NULL,
	`created_at` integer NOT NULL,
	`read_at` integer,
	FOREIGN KEY (`sender_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`recipient_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`moment_post_id`) REFERENCES `moment_posts`(`id`) ON UPDATE no action ON DELETE set null
);--> statement-breakpoint
-- Both halves of a conversation, newest last: one index serves either direction
-- of "everything between me and X".
CREATE INDEX `moment_messages_pair_idx` ON `moment_messages` (`sender_id`,`recipient_id`,`created_at`);--> statement-breakpoint
CREATE INDEX `moment_messages_inbox_idx` ON `moment_messages` (`recipient_id`,`created_at`);--> statement-breakpoint
-- Carry the replies written before the model changed: their recipient is
-- whoever posted the moment they answer.
INSERT INTO `moment_messages`
	(`id`, `sender_id`, `recipient_id`, `moment_post_id`, `kind`, `body`, `created_at`, `read_at`)
SELECT r.`id`, r.`user_id`, p.`user_id`, r.`moment_post_id`, 'text', r.`body`, r.`created_at`, r.`read_at`
FROM `moment_replies` r
JOIN `moment_posts` p ON p.`id` = r.`moment_post_id`;--> statement-breakpoint
DROP TABLE `moment_replies`;
