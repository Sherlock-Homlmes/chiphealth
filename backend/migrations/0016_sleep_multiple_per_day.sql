-- A day holds as many sleeps as the user had. (user_id, local_date) was
-- UNIQUE, so the upsert behind POST /v1/sleep/sessions treated every new
-- recording as a re-upload of that day's night: an afternoon nap overwrote
-- last night, and the night was gone with its stages, its clips and its notes.
--
-- The pair stays indexed — the debt window, the day card and the list all
-- group by it — it just stops being unique. Deduplication of a re-synced
-- wearable night still works: that is sleep_sessions_external_uq on
-- (source, external_id), which this does not touch.
DROP INDEX IF EXISTS sleep_sessions_user_date_uq;

CREATE INDEX IF NOT EXISTS sleep_sessions_user_date_idx
  ON sleep_sessions (user_id, local_date);
