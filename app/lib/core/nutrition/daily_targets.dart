import '../models/models.dart';

/// The numbers the home screen measures the day against.
///
/// The API returns what was eaten, never what should be eaten, so the targets
/// are derived here — one place, so a bar and the number under it can never
/// disagree about what "mục tiêu" means.
class DailyTargets {
  const DailyTargets({
    required this.kcal,
    required this.carbsG,
    required this.proteinG,
    required this.fatG,
    required this.sugarG,
    required this.sodiumMg,
    required this.fiberG,
  });

  final double kcal;
  final double carbsG;
  final double proteinG;
  final double fatG;

  /// Sugar and sodium are ceilings, not goals: a full bar is a warning.
  final double sugarG;
  final double sodiumMg;
  final double fiberG;

  /// Used until the profile is complete enough to compute a TDEE.
  static const fallbackKcal = 2000.0;

  /// Energy split: 50% carbs / 20% protein / 30% fat, at 4/4/9 kcal per gram.
  /// Sugar caps at 10% of energy (WHO), sodium at 2000 mg/day (WHO), fibre at
  /// 25 g/day.
  factory DailyTargets.fromDaily(DailyNutrition daily) =>
      DailyTargets.fromKcal(daily.tdeeKcal ?? fallbackKcal);

  factory DailyTargets.fromKcal(double kcal) {
    final energy = kcal <= 0 ? fallbackKcal : kcal;
    return DailyTargets(
      kcal: energy,
      carbsG: energy * 0.50 / 4,
      proteinG: energy * 0.20 / 4,
      fatG: energy * 0.30 / 9,
      sugarG: energy * 0.10 / 4,
      sodiumMg: 2000,
      fiberG: 25,
    );
  }
}
