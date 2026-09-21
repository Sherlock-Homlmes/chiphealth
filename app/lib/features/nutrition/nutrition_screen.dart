import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format/date_range.dart';
import '../../core/format/units.dart';
import '../../core/models/models.dart';
import '../../core/nutrition/daily_targets.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/retro_widgets.dart';
import '../home/add_water_sheet.dart';
import '../home/home_widgets.dart';
import '../home/water_controller.dart';
import '../home/water_info.dart';
import 'barcode_scan_screen.dart';
import 'log_meal_sheet.dart';
import 'meal_photo.dart';
import 'meal_timeline.dart';
import '../../core/l10n/gen/app_localizations.dart';

class NutritionScreen extends ConsumerStatefulWidget {
  const NutritionScreen({super.key});

  @override
  ConsumerState<NutritionScreen> createState() => _NutritionScreenState();
}

class _NutritionScreenState extends ConsumerState<NutritionScreen> {
  /// Anything that changes a meal changes both the day card and the diary, so
  /// the two are always refreshed together.
  void _reload() {
    ref.invalidate(dailyNutritionProvider);
    ref.read(mealTimelineProvider.notifier).refresh();
  }

  /// Every way into a meal goes through the one "+": the entry points are
  /// different inputs to the same analysis, not different features — which is
  /// why the photo and the typed/spoken description share one screen. Water
  /// rides along because it is the other thing logged by hand during the day.
  Future<void> _pickLogMethod() async {
    final method = await showLogMealSheet(context);
    if (method == null || !mounted) return;

    switch (method) {
      case LogMealMethod.meal:
        await context.push<void>('/meals/new');
      case LogMealMethod.barcode:
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const BarcodeScanScreen()),
        );
      case LogMealMethod.water:
        // Water is device-local and touches neither the day card nor the
        // diary, so it skips the reload the meal paths need.
        await _logWater();
        return;
    }
    _reload();
  }

  /// The home screen's water sheet, raised from here. Nothing on this screen
  /// shows millilitres, so the total comes back as a snackbar.
  Future<void> _logWater() async {
    final date = DateRange.iso(DateTime.now());
    final added = await addWater(
      context,
      ref,
      date: date,
      drunk: ref.read(waterProvider(date)),
      target: ref.read(waterTargetProvider),
    );
    if (added == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            AppL10n.of(
              context,
            ).waterAddedToday('$added', '${ref.read(waterProvider(date))}'),
          ),
        ),
      );
  }

  /// A meal can be edited or thrown away on the detail screen, so both lists are
  /// refreshed on the way back rather than guessing what happened there.
  Future<void> _openMeal(String id) async {
    await context.push<void>('/meals/$id');
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final daily = ref.watch(dailyNutritionProvider(null));
    final timeline = ref.watch(mealTimelineProvider);
    // Water loads from the device asynchronously; watching it here means the
    // sheet opens on today's real total rather than on a zero still loading.
    ref.watch(waterProvider(DateRange.iso(DateTime.now())));

    return Scaffold(
      appBar: AppBar(title: Text(AppL10n.of(context).dinhDuong)),
      floatingActionButton: FloatingActionButton(
        // The work all happens on the screen the "+" opens, so nothing here
        // has a busy state to show.
        onPressed: _pickLogMethod,
        backgroundColor: RetroTokens.accent,
        foregroundColor: Colors.white,
        child: const Icon(Icons.add, size: 30),
      ),
      body: RefreshIndicator(
        onRefresh: () async => _reload(),
        // The diary pages backwards forever, so loading is driven by how close
        // the list is to its end rather than by a "tải thêm" button.
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            final m = n.metrics;
            if (m.axis == Axis.vertical && m.pixels > m.maxScrollExtent - 400) {
              ref.read(mealTimelineProvider.notifier).loadMore();
            }
            return false;
          },
          child: PhoneFrame(
            child: ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: asyncBody(
                    daily,
                    onRetry: () => ref.invalidate(dailyNutritionProvider),
                    data: (d) => _TodayCard(d),
                  ),
                ),
                ..._diary(timeline),
                const SizedBox(height: 96),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Every meal ever, newest first, under one subtitle per day.
  List<Widget> _diary(MealTimelineState timeline) {
    if (timeline.loading) {
      return const [
        Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }

    final days = timeline.days;
    if (days.isEmpty && timeline.error != null) {
      return [
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Text(
                '${timeline.error}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: RetroTokens.inkSoft),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () =>
                    ref.read(mealTimelineProvider.notifier).refresh(),
                child: Text(AppL10n.of(context).thuLai),
              ),
            ],
          ),
        ),
      ];
    }

    if (days.isEmpty) {
      return [
        Padding(
          padding: EdgeInsets.all(32),
          child: Center(
            child: Text(
              AppL10n.of(context).chuaGhiBuaNaoNhanDe,
              style: TextStyle(color: RetroTokens.inkFaint),
            ),
          ),
        ),
      ];
    }

    return [
      for (final day in days) ...[
        _DayHeading(day: day),
        for (final meal in day.meals)
          _MealTile(meal: meal, onTap: () => _openMeal(meal.id)),
      ],
      if (timeline.loadingMore)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Center(
            child: SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        )
      else if (!timeline.hasMore)
        Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Center(
            child: Text(
              AppL10n.of(context).hetRoi,
              style: TextStyle(color: RetroTokens.inkFaint, fontSize: 12),
            ),
          ),
        ),
    ];
  }
}

/// Today's totals against TDEE. The diary under it is history; this is the
/// number the user is actually steering — and water rides in the same card
/// rather than a second one, because it is the same day being measured.
class _TodayCard extends ConsumerWidget {
  const _TodayCard(this.d);

  final DailyNutrition d;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final targets = DailyTargets.fromDaily(d);
    final date = DateRange.iso(DateTime.now());
    // The same total the home screen shows: what was tapped in by hand plus
    // the fluid the analysis found in today's meals. "Đặt lại hôm nay" only
    // clears the hand-logged half, so the meals' water survives it.
    final drunk = ref.watch(waterProvider(date));
    final fromMeals = d.waterFromMealsMl.round();
    final waterTarget = ref.watch(waterTargetProvider);

    return RetroBox(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                Units.kcal(d.consumedKcal),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(width: 8),
              if (d.tdeeKcal != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '/ ${d.tdeeKcal!.round()} TDEE',
                    style: const TextStyle(color: RetroTokens.inkSoft),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            d.balanceKcal == null
                ? AppL10n.of(context).chuaDuDuLieuDeTinh
                : d.isDeficit
                ? AppL10n.of(
                    context,
                  ).deficitKcal('${d.balanceKcal!.abs().round()}')
                : AppL10n.of(context).surplusKcal('${d.balanceKcal!.round()}'),
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: d.isDeficit ? RetroTokens.ok : RetroTokens.warn,
            ),
          ),
          const _CardRule(),
          // The same three bars as the home screen: a grey track for the day's
          // target, filled in the macro's colour as far as it has been eaten.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: MacroBar(
                  label: AppL10n.of(context).tinhBot,
                  value: d.carbsG,
                  target: targets.carbsG,
                  unit: 'g',
                  color: RetroTokens.carbs,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: MacroBar(
                  label: AppL10n.of(context).chatDam,
                  value: d.proteinG,
                  target: targets.proteinG,
                  unit: 'g',
                  color: RetroTokens.protein,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: MacroBar(
                  label: AppL10n.of(context).chatBeo,
                  value: d.fatG,
                  target: targets.fatG,
                  unit: 'g',
                  color: RetroTokens.fat,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // The home screen hides these behind a swipe; the diary is the screen
          // you open *for* the detail, so the second trio is simply shown. Sugar
          // and sodium are ceilings, not goals — a full bar there is a warning.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: MacroBar(
                  label: AppL10n.of(context).duong,
                  value: d.sugarG,
                  target: targets.sugarG,
                  unit: 'g',
                  color: RetroTokens.sugar,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: MacroBar(
                  label: 'Natri',
                  value: d.sodiumMg,
                  target: targets.sodiumMg,
                  unit: 'mg',
                  color: RetroTokens.sodium,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: MacroBar(
                  label: AppL10n.of(context).chatXo,
                  value: d.fiberG,
                  target: targets.fiberG,
                  unit: 'g',
                  color: RetroTokens.fiber,
                ),
              ),
            ],
          ),
          const _CardRule(),
          // Read-only here: water is added from the "+" at the foot of the
          // screen like everything else, so this card is a summary of the day
          // rather than a second place to log from. The "i" carries the same
          // split as the home card.
          Row(
            children: [
              Expanded(
                child: MacroBar(
                  label: AppL10n.of(context).nuoc,
                  value: (drunk + fromMeals).toDouble(),
                  target: waterTarget.toDouble(),
                  unit: 'ml',
                  color: RetroTokens.water,
                ),
              ),
              const SizedBox(width: 8),
              WaterInfoButton(drunk: drunk, fromMeals: fromMeals),
            ],
          ),
        ],
      ),
    );
  }
}

/// The hairline between the card's three blocks, spaced the same either side.
class _CardRule extends StatelessWidget {
  const _CardRule();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 14),
    child: Divider(color: RetroTokens.paperSunk, height: 1, thickness: 1),
  );
}

/// The date subtitle, with what that day added up to on the right.
class _DayHeading extends StatelessWidget {
  const _DayHeading({required this.day});

  final MealDay day;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(
            child: Text(
              Units.dayHeading(context, day.date),
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 15,
                color: RetroTokens.ink,
              ),
            ),
          ),
          Text(
            AppL10n.of(
              context,
            ).mealsAndKcal('${day.meals.length}', Units.kcal(day.totalKcal)),
            style: const TextStyle(color: RetroTokens.inkFaint, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _MealTile extends StatelessWidget {
  const _MealTile({required this.meal, required this.onTap});

  final MealLog meal;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The dish is the headline when the model named it; otherwise the meal type
    // is, and repeating it on the line below would say nothing.
    final dish = meal.dishName?.isNotEmpty == true ? meal.dishName : null;
    final subtitle = [
      if (dish != null) _mealLabel(context, meal.mealType),
      Units.timeOfDay(meal.loggedAt),
      AppL10n.of(context).componentCount('${meal.componentCount}'),
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: RetroBox(
        onTap: onTap,
        child: Row(
          children: [
            // Only meals logged from a photo carry one; the rest keep the
            // text-only row they had rather than showing an empty plate.
            if (meal.photoAssetId != null) ...[
              MealPhotoThumb(assetId: meal.photoAssetId, size: 44),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    dish ?? _mealLabel(context, meal.mealType),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: RetroTokens.inkSoft,
                    ),
                  ),
                ],
              ),
            ),
            if (meal.isAnalysing)
              const SizedBox(
                height: 16,
                width: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            // A failed photo analysis stays listed; the detail screen it opens
            // carries the retry.
            else if (meal.isFailedDraft)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.refresh, size: 16, color: RetroTokens.accent),
                  SizedBox(width: 4),
                  Text(
                    AppL10n.of(context).loiThuLai,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                      color: RetroTokens.accent,
                    ),
                  ),
                ],
              )
            else
              Text(
                Units.kcal(meal.totalCaloriesKcal),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
          ],
        ),
      ),
    );
  }
}

String _mealLabel(BuildContext context, String type) => switch (type) {
  'breakfast' => AppL10n.of(context).buaSang,
  'lunch' => AppL10n.of(context).buaTrua,
  'dinner' => AppL10n.of(context).buaToi,
  _ => AppL10n.of(context).buaPhu,
};
