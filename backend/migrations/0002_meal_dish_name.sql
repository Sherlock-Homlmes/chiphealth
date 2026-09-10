-- The vision model names the dish as a whole ("bún riêu cua"), not just its
-- parts, and the meal detail screen leads with that name. Nullable: meals
-- logged by hand or still being analysed have no name yet.
ALTER TABLE meal_logs ADD COLUMN dish_name TEXT;
