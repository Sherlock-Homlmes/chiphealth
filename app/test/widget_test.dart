import 'package:chiphealth/core/format/units.dart';
import 'package:chiphealth/core/models/models.dart';
import 'package:chiphealth/core/storage/uuid.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('units', () {
    test('metric renders kilograms and kilometres', () {
      const units = Units(UnitSystem.metric);
      expect(units.weight(70.4), '70.4 kg');
      expect(units.distance(5200), '5.2 km');
      expect(units.height(175), '175 cm');
    });

    test('imperial converts at the display edge only', () {
      const units = Units(UnitSystem.imperial);
      expect(units.weight(70), '154.3 lb');
      expect(units.distance(1609.344), '1 mi');
      expect(units.height(175), "5'9\"");
    });

    test('pace is per mile for imperial users', () {
      // 5:00/km is 8:03/mi.
      expect(const Units(UnitSystem.metric).pace(300), '5:00/km');
      expect(const Units(UnitSystem.imperial).pace(300), '8:03/mi');
    });

    test('durations collapse sensibly', () {
      expect(Units.duration(45), '45s');
      expect(Units.duration(605), '10m 05s');
      expect(Units.duration(3725), '1h 02m');
      expect(Units.hoursMinutes(28800), '8h00');
    });
  });

  group('uuid v7', () {
    test('is version 7 and variant 10', () {
      final id = uuidV7();
      expect(id.length, 36);
      expect(id[14], '7');
      expect('89ab'.contains(id[19]), isTrue);
    });

    test('sorts chronologically, which is what offline ids rely on', () {
      final older = uuidV7(DateTime.utc(2026, 1, 1));
      final newer = uuidV7(DateTime.utc(2026, 6, 1));
      expect(older.compareTo(newer) < 0, isTrue);
    });
  });

  group('models', () {
    test('a meal whose analysis failed with nothing to show is a draft', () {
      const failed = MealLog(
        id: 'm1',
        mealType: 'lunch',
        loggedAt: 0,
        localDate: '2026-09-09',
        totalCaloriesKcal: 0,
        analysisStatus: 'failed',
        itemCount: 0,
      );
      // A re-analysis that failed over items the user already has is not a
      // draft: throwing it away would take real data with it.
      const failedButFull = MealLog(
        id: 'm2',
        mealType: 'lunch',
        loggedAt: 0,
        localDate: '2026-09-09',
        totalCaloriesKcal: 420,
        analysisStatus: 'failed',
        itemCount: 3,
      );
      expect(failed.isFailedDraft, isTrue);
      expect(failedButFull.isFailedDraft, isFalse);
    });

    test('goal progress is clamped between the baseline and the target', () {
      const goal = Goal(
        id: 'g',
        goalType: 'lose_weight',
        startValue: 75,
        status: 'active',
        targetValue: 70,
      );
      expect(goal.progress(75), 0);
      expect(goal.progress(72.5), 0.5);
      expect(goal.progress(69), 1);
      expect(goal.progress(null), 0);
    });

    test('sleep debt reports hours from the rolling window', () {
      const debt = SleepDebt(
        targetSeconds: 28800,
        windowDays: 14,
        rollingDebtSeconds: 38520,
        daysRecorded: 10,
        byDay: [],
      );
      expect(debt.debtHours.toStringAsFixed(1), '10.7');
    });
  });
}
