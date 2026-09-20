-- Deleting a workout used to set is_deleted = 1. The feed and the day's totals
-- honoured the flag, but everything the session had produced stayed behind —
-- most visibly the personal records it set, which kept standing on the board
-- and kept being read back by the assistant. A workout the user threw away is
-- now really deleted (DELETE /v1/workouts/:id); this clears out the rows that
-- were hidden under the old flag.
--
-- Nothing cascades from personal_records, and a strength record points at the
-- set rather than the session, so both have to go before the sessions do.
DELETE FROM personal_records
WHERE workout_session_id IN (SELECT id FROM workout_sessions WHERE is_deleted = 1);

DELETE FROM personal_records
WHERE strength_set_id IN (
  SELECT id FROM workout_strength_sets
  WHERE workout_session_id IN (SELECT id FROM workout_sessions WHERE is_deleted = 1)
);

-- Streams, splits, zone summaries, strength sets and photo links cascade.
DELETE FROM workout_sessions WHERE is_deleted = 1;

-- A board whose holder just went away rolls back to the best record still
-- standing, rather than disappearing: those older rows are sitting there with
-- is_current = 0 because this record beat them. Lower is better for pace and
-- for a timed distance; higher for everything else.
UPDATE personal_records SET is_current = 1
WHERE id IN (
  SELECT id FROM (
    SELECT pr.id,
      ROW_NUMBER() OVER (
        PARTITION BY pr.user_id, pr.metric,
          ifnull(pr.activity_type_id, -1), ifnull(pr.exercise_id, -1),
          ifnull(pr.distance_m, -1)
        ORDER BY CASE
          WHEN pr.metric IN ('fastest_distance', 'best_pace') THEN pr.value
          ELSE -pr.value
        END ASC
      ) AS rn
    FROM personal_records pr
    WHERE NOT EXISTS (
      SELECT 1 FROM personal_records held
      WHERE held.user_id = pr.user_id
        AND held.metric = pr.metric
        AND ifnull(held.activity_type_id, -1) = ifnull(pr.activity_type_id, -1)
        AND ifnull(held.exercise_id, -1) = ifnull(pr.exercise_id, -1)
        AND ifnull(held.distance_m, -1) = ifnull(pr.distance_m, -1)
        AND held.is_current = 1
    )
  ) WHERE rn = 1
);
