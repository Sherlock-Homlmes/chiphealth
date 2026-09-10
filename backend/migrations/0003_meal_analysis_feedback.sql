-- The meal detail screen asks "ChipHealth phân tích thế nào?" after every
-- analysis. The answer belongs next to the attempt it judges — the analysis row
-- is already the fine-tuning corpus, so the thumb is the label on that sample.
-- Nullable: most analyses are never voted on.
ALTER TABLE meal_ai_analyses ADD COLUMN user_feedback TEXT;
ALTER TABLE meal_ai_analyses ADD COLUMN feedback_at INTEGER;
