-- Drinks and soupy dishes are most of what a Vietnamese meal contributes to the
-- day's fluid, and the analysis threw that away: a glass of orange juice logged
-- as 250 g of food said nothing about the 220 ml of water in it. The model now
-- estimates the fluid each component carries, so the meal can report it.
--
-- Nullable rather than 0: a component analysed before this column existed has
-- no estimate, which is not the same as "no water in it".
ALTER TABLE meal_items ADD COLUMN water_ml REAL;
ALTER TABLE meal_logs ADD COLUMN total_water_ml REAL;
