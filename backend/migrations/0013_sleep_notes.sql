-- "Tôi dậy rồi" used to save the night and drop the user straight back on the
-- list, with nothing to say about it. A night now gets the same review a
-- workout gets: a name, a note, and photos.
ALTER TABLE sleep_sessions ADD COLUMN title TEXT;
ALTER TABLE sleep_sessions ADD COLUMN notes TEXT;

-- Same shape as workout_photos: the join table owns the order, and an asset
-- stays referenced until every night that used it has let it go.
CREATE TABLE sleep_photos (
  sleep_session_id TEXT NOT NULL REFERENCES sleep_sessions(id) ON DELETE CASCADE,
  asset_id TEXT NOT NULL REFERENCES media_assets(id),
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (sleep_session_id, asset_id)
);

CREATE INDEX sleep_photos_order_idx ON sleep_photos (sleep_session_id, sort_order);
