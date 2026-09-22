-- The run detail screen: what a finished run is worth, beyond its totals.
--
-- Four numbers the screen shows that nothing computed before go on the session
-- itself, because they are one value per run and the stat grid reads them
-- without touching R2: the highest point reached, the grade-adjusted average
-- pace, the step count (cadence x moving minutes, when the recorder gave us a
-- cadence), and whether the athlete saved the run.
ALTER TABLE workout_sessions ADD COLUMN is_bookmarked INTEGER NOT NULL DEFAULT 0;
ALTER TABLE workout_sessions ADD COLUMN elevation_max_m REAL;
ALTER TABLE workout_sessions ADD COLUMN gap_sec_per_km REAL;
ALTER TABLE workout_sessions ADD COLUMN steps INTEGER;

-- Time-in-zone now comes in two flavours: heart-rate zones (what this table
-- has always held) and pace zones derived from the predicted 5 km time. They
-- are the same shape — a zone number, seconds, a percentage — so they share the
-- table and are told apart by `kind` rather than by a second table that would
-- be a copy of this one.
ALTER TABLE workout_zone_summaries ADD COLUMN kind TEXT NOT NULL DEFAULT 'hr';
DROP INDEX IF EXISTS workout_zone_uq;
CREATE UNIQUE INDEX workout_zone_uq
  ON workout_zone_summaries (workout_session_id, kind, zone_number);

-- Best efforts are not personal records. A record is the one standing best; an
-- effort is what THIS run did over a standard distance, with the position it
-- took on the all-time board at the moment it was run ("second fastest 2 miles
-- ever"). That rank is frozen on purpose: a later, faster run does not rewrite
-- what this run's page said the day it happened.
--
-- start/end_distance_m locate the effort along the route, which is how the map
-- knows where to pin the medal.
CREATE TABLE IF NOT EXISTS workout_best_efforts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  workout_session_id TEXT NOT NULL REFERENCES workout_sessions(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  activity_type_id INTEGER NOT NULL REFERENCES activity_types(id),
  distance_m REAL NOT NULL,
  elapsed_seconds REAL NOT NULL,
  start_distance_m REAL NOT NULL,
  end_distance_m REAL NOT NULL,
  rank INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS workout_best_efforts_uq
  ON workout_best_efforts (workout_session_id, distance_m);
-- "How many efforts beat this one?", asked once per standard distance at ingest.
CREATE INDEX IF NOT EXISTS workout_best_efforts_board_idx
  ON workout_best_efforts (user_id, activity_type_id, distance_m, elapsed_seconds);

-- Riegel predictions, kept as a history rather than a single row per distance,
-- so a run can say how much it moved the number ("31 seconds faster"). The
-- session reference is SET NULL rather than CASCADE: deleting the run should
-- not delete the athlete's prediction line.
CREATE TABLE IF NOT EXISTS race_predictions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  activity_type_id INTEGER NOT NULL REFERENCES activity_types(id),
  distance_m REAL NOT NULL,
  predicted_seconds REAL NOT NULL,
  previous_seconds REAL,
  workout_session_id TEXT REFERENCES workout_sessions(id) ON DELETE SET NULL,
  is_current INTEGER NOT NULL DEFAULT 1,
  computed_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS race_predictions_current_idx
  ON race_predictions (user_id, activity_type_id, distance_m, is_current);
CREATE INDEX IF NOT EXISTS race_predictions_session_idx
  ON race_predictions (workout_session_id);

-- The coach's one-liners about a run. Generated once and cached: input_hash is
-- a digest of the numbers the model was shown, so re-deriving the stream (a
-- crop, a re-upload) invalidates the line while a plain re-read does not.
CREATE TABLE IF NOT EXISTS workout_insights (
  workout_session_id TEXT NOT NULL REFERENCES workout_sessions(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,
  language TEXT NOT NULL,
  body TEXT NOT NULL,
  input_hash TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (workout_session_id, kind, language)
);
