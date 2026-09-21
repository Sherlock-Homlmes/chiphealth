-- D1 bills rows read, so an index that turns a scan into a seek is a bill, not
-- just a latency figure. Every index here answers one query the app runs on
-- every screen open; the columns are in the order that query uses them
-- (equality first, then the range or the sort).

-- The diary pages by (logged_at, id), but the only index was (user_id,
-- local_date): the day filter used it and the sort was done in memory over
-- every meal the user has ever logged.
CREATE INDEX meal_logs_user_logged_idx
  ON meal_logs (user_id, logged_at, id);

-- The workout feed pages by id under (user_id, is_deleted); the existing index
-- is (user_id, local_date) and does not serve that order.
CREATE INDEX workout_sessions_user_id_idx
  ON workout_sessions (user_id, is_deleted, id);

-- Same shape for nights: listed newest-id first per user.
CREATE INDEX sleep_sessions_user_id_idx
  ON sleep_sessions (user_id, id);

-- The moments feed is "these authors, not deleted, newest first".
CREATE INDEX moment_posts_feed_idx
  ON moment_posts (user_id, deleted_at, id);

-- (coach_messages needs nothing: its id is the rowid, so the existing
-- conversation index already hands rows back in id order.)

-- The 15-minute sweeper looks for runs that are still open and old. Without
-- this it reads every analysis row in the table, every 15 minutes, forever.
CREATE INDEX meal_ai_analyses_open_idx
  ON meal_ai_analyses (status, created_at);

-- The meal detail asks for the newest run of one meal.
CREATE INDEX meal_ai_analyses_latest_idx
  ON meal_ai_analyses (meal_log_id, id);

-- Deleting a workout has to find the records it set. personal_records was
-- indexed by (user_id, is_current) only, so that lookup scanned the table.
CREATE INDEX personal_records_session_idx
  ON personal_records (workout_session_id);
CREATE INDEX personal_records_set_idx
  ON personal_records (strength_set_id);

-- "Is this asset still referenced by anything?" — asked on every photo detach.
CREATE INDEX workout_photos_asset_idx ON workout_photos (asset_id);
CREATE INDEX sleep_photos_asset_idx ON sleep_photos (asset_id);
