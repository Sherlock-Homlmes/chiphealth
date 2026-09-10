-- FTS5 layer for hybrid food retrieval (BM25 half of the BM25 + Vectorize + RRF pipeline).
-- Hand-written: drizzle cannot express SQLite virtual tables or triggers.
--
-- Column order is load-bearing: services/foodSearch.ts weights bm25() columns
-- positionally — bm25(foods_fts, 4.0, 2.0, 1.0) => name, brand, category
-- and bm25(food_kb_fts, 3.0, 1.0)               => title, content.
--
-- `remove_diacritics 2` folds Vietnamese tone marks, so "com ga" matches "cơm gà".

CREATE VIRTUAL TABLE `foods_fts` USING fts5(
  name,
  brand,
  category,
  content = 'foods',
  content_rowid = 'rowid',
  tokenize = "unicode61 remove_diacritics 2"
);
--> statement-breakpoint
CREATE TRIGGER `foods_fts_ai` AFTER INSERT ON `foods` BEGIN
  INSERT INTO `foods_fts`(rowid, name, brand, category)
  VALUES (new.rowid, new.name, new.brand, new.category);
END;
--> statement-breakpoint
CREATE TRIGGER `foods_fts_ad` AFTER DELETE ON `foods` BEGIN
  INSERT INTO `foods_fts`(`foods_fts`, rowid, name, brand, category)
  VALUES ('delete', old.rowid, old.name, old.brand, old.category);
END;
--> statement-breakpoint
CREATE TRIGGER `foods_fts_au` AFTER UPDATE ON `foods` BEGIN
  INSERT INTO `foods_fts`(`foods_fts`, rowid, name, brand, category)
  VALUES ('delete', old.rowid, old.name, old.brand, old.category);
  INSERT INTO `foods_fts`(rowid, name, brand, category)
  VALUES (new.rowid, new.name, new.brand, new.category);
END;
--> statement-breakpoint
CREATE VIRTUAL TABLE `food_kb_fts` USING fts5(
  title,
  content,
  content = 'food_kb_documents',
  content_rowid = 'rowid',
  tokenize = "unicode61 remove_diacritics 2"
);
--> statement-breakpoint
CREATE TRIGGER `food_kb_fts_ai` AFTER INSERT ON `food_kb_documents` BEGIN
  INSERT INTO `food_kb_fts`(rowid, title, content)
  VALUES (new.rowid, new.title, new.content);
END;
--> statement-breakpoint
CREATE TRIGGER `food_kb_fts_ad` AFTER DELETE ON `food_kb_documents` BEGIN
  INSERT INTO `food_kb_fts`(`food_kb_fts`, rowid, title, content)
  VALUES ('delete', old.rowid, old.title, old.content);
END;
--> statement-breakpoint
CREATE TRIGGER `food_kb_fts_au` AFTER UPDATE ON `food_kb_documents` BEGIN
  INSERT INTO `food_kb_fts`(`food_kb_fts`, rowid, title, content)
  VALUES ('delete', old.rowid, old.title, old.content);
  INSERT INTO `food_kb_fts`(rowid, title, content)
  VALUES (new.rowid, new.title, new.content);
END;
