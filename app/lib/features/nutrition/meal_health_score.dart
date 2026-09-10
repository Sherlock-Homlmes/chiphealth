import '../../core/models/models.dart';

/// A 0-10 read on how well a single meal is put together.
///
/// Deliberately simple and client-side: the rules are the ones a dietitian would
/// state out loud, so a user who disagrees can see exactly which one cost them a
/// point. Nothing here is stored — recomputing is cheap, and a stored score
/// would go stale the moment the user corrects an item.
class MealHealthScore {
  const MealHealthScore(this.value, this.reasons);

  /// Rounded to a whole number out of 10.
  final int value;

  /// Why points were lost, worst first. Empty when the meal scores full marks.
  final List<String> reasons;

  static MealHealthScore of(MealLog meal) {
    final kcal = meal.totalCaloriesKcal;
    if (kcal <= 0) return const MealHealthScore(0, ['Chưa có số liệu']);

    final reasons = <(double, String)>[];
    var score = 10.0;

    // Energy share of the macros, which is what "balanced" actually refers to.
    final proteinKcal = meal.totalProteinG * 4;
    final carbsKcal = meal.totalCarbsG * 4;
    final fatKcal = meal.totalFatG * 9;
    final macroKcal = proteinKcal + carbsKcal + fatKcal;

    if (macroKcal > 0) {
      final proteinShare = proteinKcal / macroKcal;
      final carbShare = carbsKcal / macroKcal;
      final fatShare = fatKcal / macroKcal;

      if (proteinShare < 0.15) {
        final lost = ((0.15 - proteinShare) * 20).clamp(0.0, 3.0);
        score -= lost;
        reasons.add((lost, 'Ít đạm'));
      }
      if (carbShare > 0.60) {
        final lost = ((carbShare - 0.60) * 10).clamp(0.0, 2.5);
        score -= lost;
        reasons.add((lost, 'Nhiều tinh bột'));
      }
      if (fatShare > 0.40) {
        final lost = ((fatShare - 0.40) * 10).clamp(0.0, 2.5);
        score -= lost;
        reasons.add((lost, 'Nhiều chất béo'));
      }
    }

    // Fibre, sugar and salt, each measured per 1000 kcal so a big meal is not
    // punished simply for being big.
    final per1000 = 1000 / kcal;
    final fiber = _sum(meal, (i) => i.fiberG) * per1000;
    final sugar = _sum(meal, (i) => i.sugarG) * per1000;
    final sodium = _sum(meal, (i) => i.sodiumMg) * per1000;

    if (fiber < 7) {
      final lost = ((7 - fiber) / 7 * 2).clamp(0.0, 2.0);
      score -= lost;
      reasons.add((lost, 'Ít chất xơ'));
    }
    if (sugar > 25) {
      final lost = ((sugar - 25) / 25 * 2).clamp(0.0, 2.0);
      score -= lost;
      reasons.add((lost, 'Nhiều đường'));
    }
    if (sodium > 1000) {
      final lost = ((sodium - 1000) / 1000 * 2).clamp(0.0, 2.0);
      score -= lost;
      reasons.add((lost, 'Nhiều muối'));
    }

    reasons.sort((a, b) => b.$1.compareTo(a.$1));
    return MealHealthScore(
      score.clamp(1, 10).round(),
      reasons.map((r) => r.$2).toList(),
    );
  }

  /// Nutrients are nullable per item, so a missing value counts as zero rather
  /// than sinking the whole sum.
  static double _sum(MealLog meal, double? Function(MealItem) pick) =>
      meal.items.fold(0.0, (s, i) => s + (pick(i) ?? 0));
}
