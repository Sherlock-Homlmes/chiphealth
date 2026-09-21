-- "Trọng tâm của bạn", the first card of the activity screen's progress tab:
-- what the athlete is training for right now. It is not one of the rows in
-- `goals` — a goal is a measurable target with a deadline, this is a standing
-- intent with neither — so it lives on the profile, next to the other
-- preferences the coach reads before it answers.
--
-- 'stay_active' is the default because it is the assumption the app already
-- makes everywhere else: keep the weekly habit going.
ALTER TABLE user_profiles ADD COLUMN training_focus TEXT NOT NULL DEFAULT 'stay_active';

-- The progress tab reads twelve weeks of sessions by local_date, and the month
-- cards read two more. Without this the only usable index is on started_at,
-- which is an instant rather than the user's own calendar day.
CREATE INDEX IF NOT EXISTS workout_sessions_user_local_date_idx
  ON workout_sessions (user_id, local_date);
