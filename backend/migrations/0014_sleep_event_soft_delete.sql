-- Hiding a snore or a sleep-talk clip the user does not want to see again is
-- not the same as destroying it: the clip is evidence about their night, and
-- the classifier's output is training data. The row is kept and stamped
-- instead, and every read filters on the stamp.
ALTER TABLE sleep_audio_events ADD COLUMN deleted_at INTEGER;

-- The index the list reads through, so a night with a hundred events does not
-- scan the hidden ones.
CREATE INDEX sleep_audio_events_live_idx
  ON sleep_audio_events (sleep_session_id, deleted_at, occurred_at);
