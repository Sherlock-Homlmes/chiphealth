-- The assistant's long-term memory of the person it is talking to: allergies,
-- injuries, chronic conditions, food they refuse, when they train, why they are
-- cutting. Without it every conversation starts from nothing and the same
-- questions get asked again next week.
--
-- Two lifetimes in one table: expires_at NULL is permanent ("dị ứng hải sản"),
-- a timestamp is true only for a while ("nghỉ chạy 3 tuần vì đau gối"). Readers
-- filter on expires_at themselves — the nightly purge only reclaims space.
--
-- fact_key is the normalised sentence, unique per user, so remembering the same
-- thing twice updates one row instead of stacking near-duplicates.
CREATE TABLE user_facts (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  category TEXT NOT NULL DEFAULT 'other',
  fact TEXT NOT NULL,
  fact_key TEXT NOT NULL,
  expires_at INTEGER,
  source TEXT NOT NULL DEFAULT 'assistant',
  conversation_id TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  CHECK (category IN ('health','nutrition','training','sleep','preference','other'))
);

CREATE UNIQUE INDEX user_facts_key_uq ON user_facts (user_id, fact_key);
CREATE INDEX user_facts_user_idx ON user_facts (user_id, expires_at);
