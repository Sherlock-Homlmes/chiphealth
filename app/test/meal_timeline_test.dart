import 'package:chiphealth/core/models/models.dart';
import 'package:chiphealth/features/nutrition/meal_timeline.dart';
import 'package:flutter_test/flutter_test.dart';

MealLog _meal(String id, String date, int hour, double kcal) => MealLog(
  id: id,
  mealType: 'lunch',
  loggedAt: DateTime(2026, 9, 9, hour).millisecondsSinceEpoch,
  localDate: date,
  totalCaloriesKcal: kcal,
);

MealItem _item(
  int id,
  String name,
  double kcal, {
  double protein = 0,
  double carbs = 0,
  double fat = 0,
}) => MealItem(
  id: id,
  ingredientName: name,
  quantityG: 100,
  caloriesKcal: kcal,
  proteinG: protein,
  carbsG: carbs,
  fatG: fat,
);

void main() {
  group('meal timeline', () {
    test('groups the diary by day, newest day first', () {
      final state = MealTimelineState(
        meals: [
          _meal('c', '2026-09-10', 8, 300),
          _meal('b', '2026-09-09', 19, 700),
          _meal('a', '2026-09-09', 7, 400),
        ],
      );

      final days = state.days;
      expect(days.map((d) => d.date), ['2026-09-10', '2026-09-09']);
      expect(days[1].meals.map((m) => m.id), ['b', 'a']);
    });

    test('a day lists the latest-eaten meal first, not the latest created', () {
      // 'z' was created last but eaten first (breakfast typed up at noon).
      final state = MealTimelineState(
        meals: [
          _meal('a', '2026-09-09', 12, 500),
          _meal('z', '2026-09-09', 7, 300),
          _meal('m', '2026-09-09', 19, 700),
        ],
      );

      expect(state.days.single.meals.map((m) => m.id), ['m', 'a', 'z']);
    });

    test('a day heading carries what that day added up to', () {
      final state = MealTimelineState(
        meals: [
          _meal('b', '2026-09-09', 19, 700.5),
          _meal('a', '2026-09-09', 7, 400.25),
        ],
      );

      expect(state.days.single.meals.length, 2);
      expect(state.days.single.totalKcal, closeTo(1100.75, 0.001));
    });
  });

  group('staged corrections', () {
    test('withItems re-sums the totals it is left with', () {
      final meal = MealLog(
        id: 'm',
        mealType: 'lunch',
        loggedAt: 0,
        localDate: '2026-09-09',
        totalCaloriesKcal: 500,
        totalProteinG: 30,
        totalCarbsG: 60,
        totalFatG: 10,
        items: [
          _item(1, 'Cơm', 300, carbs: 60),
          _item(2, 'Thịt kho', 200, protein: 30, fat: 10),
        ],
      );

      // What the detail screen shows after "−" on the second component, before
      // anything has been sent to the server.
      final staged = meal.withItems([meal.items.first]);

      expect(staged.totalCaloriesKcal, 300);
      expect(staged.totalProteinG, 0);
      expect(staged.totalCarbsG, 60);
      expect(staged.totalFatG, 0);
      expect(staged.componentCount, 1);
      // Identity is untouched: it is the same meal, minus a component.
      expect(staged.id, meal.id);
      expect(meal.totalCaloriesKcal, 500);
    });

    test('withItems keeps the analysis state for the staged view', () {
      final meal = MealLog.fromJson({
        'id': 'm',
        'mealType': 'lunch',
        'loggedAt': 0,
        'localDate': '2026-09-09',
        'totalCaloriesKcal': 0,
        'analysis': {'status': 'failed', 'timedOut': true, 'createdAt': 123},
      });

      final staged = meal.withItems(const []);

      expect(staged.analysisStatus, 'failed');
      expect(staged.analysisTimedOut, true);
      expect(staged.analysisStartedAt, 123);
      // A timed-out run with nothing to show is the same failed draft as any
      // other: retry or throw away.
      expect(staged.isFailedDraft, true);
    });
  });

  group('analysis timeout', () {
    MealLog analysing(int startedAt) => MealLog.fromJson({
      'id': 'm',
      'mealType': 'lunch',
      'loggedAt': 0,
      'localDate': '2026-09-09',
      'totalCaloriesKcal': 0,
      'analysis': {'status': 'running', 'createdAt': startedAt},
    });

    test('the deadline is five minutes', () {
      expect(MealLog.analysisTimeout, const Duration(minutes: 5));
    });

    test('the server verdict is parsed and marks a failed draft', () {
      final meal = MealLog.fromJson({
        'id': 'm',
        'mealType': 'lunch',
        'loggedAt': 0,
        'localDate': '2026-09-09',
        'totalCaloriesKcal': 0,
        'analysis': {'status': 'failed', 'timedOut': true, 'createdAt': 1000},
      });

      expect(meal.analysisTimedOut, true);
      expect(meal.isFailedDraft, true);
      // The local clock has nothing left to say once the verdict landed.
      expect(meal.timedOutAt(1000 + 10 * 60 * 1000), false);
    });

    test('a run past the deadline times out on the local clock too', () {
      final started = 1000;
      final meal = analysing(started);

      // One millisecond short of the deadline: still waiting.
      expect(
        meal.timedOutAt(started + MealLog.analysisTimeout.inMilliseconds - 1),
        false,
      );
      // At and past it: the wait is over even though the server said running.
      expect(
        meal.timedOutAt(started + MealLog.analysisTimeout.inMilliseconds),
        true,
      );
      expect(meal.timedOutAt(started + 10 * 60 * 1000), true);
    });

    test('a missing start time or a landed run never trips the clock', () {
      final noStart = MealLog.fromJson({
        'id': 'm',
        'mealType': 'lunch',
        'loggedAt': 0,
        'localDate': '2026-09-09',
        'totalCaloriesKcal': 0,
        'analysis': {'status': 'running'},
      });
      expect(
        noStart.timedOutAt(
          DateTime.now().millisecondsSinceEpoch + 10 * 60 * 1000,
        ),
        false,
      );

      final done = MealLog.fromJson({
        'id': 'm',
        'mealType': 'lunch',
        'loggedAt': 0,
        'localDate': '2026-09-09',
        'totalCaloriesKcal': 500,
        'analysis': {'status': 'completed', 'createdAt': 1000},
      });
      expect(done.timedOutAt(1000 + 10 * 60 * 1000), false);
    });
  });
}
