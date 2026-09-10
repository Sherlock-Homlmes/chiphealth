import 'package:chiphealth/core/format/date_range.dart';
import 'package:chiphealth/core/models/models.dart';
import 'package:chiphealth/core/nutrition/daily_targets.dart';
import 'package:chiphealth/features/home/water_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('period', () {
    test('a week runs Monday to Sunday whatever day it is anchored on', () {
      // 2026-09-09 is a Wednesday.
      final period =
          Period(mode: PeriodMode.week, anchor: DateTime(2026, 9, 9));
      expect(DateRange.iso(period.range.start), '2026-09-07');
      expect(DateRange.iso(period.range.end), '2026-09-13');
      expect(period.range.days, 7);
    });

    test('stepping a month lands on the month, not 30 days back', () {
      final period =
          Period(mode: PeriodMode.month, anchor: DateTime(2026, 3, 31));
      final previous = period.step(-1);
      expect(DateRange.iso(previous.range.start), '2026-02-01');
      expect(DateRange.iso(previous.range.end), '2026-02-28');
    });

    test('a year covers the whole calendar year', () {
      final period = Period(mode: PeriodMode.year, anchor: DateTime(2025, 6, 4));
      expect(DateRange.iso(period.range.start), '2025-01-01');
      expect(DateRange.iso(period.range.end), '2025-12-31');
      expect(period.range.days, 365);
    });

    test('a custom range does not step', () {
      final custom = DateRange(DateTime(2026, 1, 5), DateTime(2026, 1, 9));
      final period = Period(
          mode: PeriodMode.custom, anchor: custom.start, custom: custom);
      expect(period.step(1).range, custom);
      expect(period.range.days, 5);
    });

    test('the current week is the latest one, last week is not', () {
      final now = Period.thisWeek();
      expect(now.isLatest, isTrue);
      expect(now.step(-1).isLatest, isFalse);
      expect(now.label, 'Tuần này');
      expect(now.step(-1).label, 'Tuần trước');
    });

    test('a period ending in the future clamps onto the pickable window', () {
      // This week is Mon 7 – Sun 13 with today on Wed 9. showDateRangePicker
      // refuses an initial range ending after lastDate, so the preselection
      // folds its end onto today instead of crashing the picker.
      final period =
          Period(mode: PeriodMode.week, anchor: DateTime(2026, 9, 9));
      final clamped =
          period.range.clampedTo(DateTime(2023, 1, 1), DateTime(2026, 9, 9));
      expect(DateRange.iso(clamped.start), '2026-09-07');
      expect(DateRange.iso(clamped.end), '2026-09-09');
    });

    test('a range older than the earliest pickable date clamps forward', () {
      // Stepped back past firstDate, the whole range is unpickable: the
      // preselection collapses onto a single legal day.
      final old = DateRange(DateTime(2020, 1, 5), DateTime(2020, 1, 9));
      final clamped =
          old.clampedTo(DateTime(2023, 1, 1), DateTime(2026, 9, 9));
      expect(DateRange.iso(clamped.start), '2023-01-01');
      expect(DateRange.iso(clamped.end), '2023-01-01');
    });
  });

  group('daily targets', () {
    test('macros split 50/20/30 of energy at 4/4/9 kcal per gram', () {
      final targets = DailyTargets.fromKcal(2000);
      expect(targets.carbsG, 250);
      expect(targets.proteinG, 100);
      expect(targets.fatG.round(), 67);
      expect(targets.sugarG, 50);
      expect(targets.sodiumMg, 2000);
      expect(targets.fiberG, 25);
    });

    test('a profile with no TDEE falls back rather than targeting zero', () {
      const daily = DailyNutrition(date: '2026-09-09', consumedKcal: 0);
      expect(DailyTargets.fromDaily(daily).kcal, DailyTargets.fallbackKcal);
    });
  });

  group('water glasses', () {
    test('a glass fills by millilitres, not by whole cups', () {
      // 380 ml of 250 ml glasses: one full, one just over half, rest empty.
      expect(cupFillRatio(0, 380), 1.0);
      expect(cupFillRatio(1, 380), closeTo(0.52, 0.001));
      expect(cupFillRatio(2, 380), 0.0);
    });

    test('a part-drunk first glass shows that part', () {
      expect(cupFillRatio(0, 0), 0.0);
      expect(cupFillRatio(0, 125), 0.5);
      expect(cupFillRatio(0, 250), 1.0);
    });

    test('drinking past the last glass does not overflow it', () {
      expect(cupFillRatio(7, 5000), 1.0);
    });
  });

  group('daily nutrition', () {
    test('the day summary carries fibre, sugar, sodium and burned calories', () {
      final daily = DailyNutrition.fromJson({
        'date': '2026-09-09',
        'summary': {
          'caloriesConsumedKcal': 1800,
          'proteinG': 90,
          'carbsG': 200,
          'fatG': 60,
          'fiberG': 21,
          'sugarG': 40,
          'sodiumMg': 2400,
          'caloriesBurnedWorkoutKcal': 320,
        },
      });
      expect(daily.fiberG, 21);
      expect(daily.sugarG, 40);
      expect(daily.sodiumMg, 2400);
      expect(daily.burnedKcal, 320);
    });
  });
}
