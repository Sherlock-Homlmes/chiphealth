-- The user's own daily energy figure. Null means "use Mifflin-St Jeor x activity";
-- a value replaces that baseline, and the day's workouts are still added on top.
ALTER TABLE `user_profiles` ADD `daily_calorie_override_kcal` real;
