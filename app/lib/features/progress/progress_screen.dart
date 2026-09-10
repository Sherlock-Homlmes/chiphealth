import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/format/date_range.dart';
import '../../core/models/models.dart';
import '../../core/nutrition/daily_targets.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/retro_widgets.dart';
import '../home/home_widgets.dart';
import '../home/water_controller.dart';
import 'progress_charts.dart';

/// Which slice of time the whole screen is reading.
final periodProvider = StateProvider<Period>((ref) => Period.thisWeek());

/// Tiến trình: weight against the goal, then calories in, calories out, water
/// and BMI — all for the selected period.
class ProgressScreen extends ConsumerWidget {
  const ProgressScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final period = ref.watch(periodProvider);
    final range = period.range;

    // Same rule as the home screen: no request goes out before the session is
    // restored, or every card renders a 401 for a frame.
    final signedIn = ref.watch(authControllerProvider).isSignedIn;
    final nutrition = signedIn
        ? ref.watch(nutritionRangeProvider(range))
        : const AsyncValue<List<DailyNutrition>>.loading();
    final metrics = signedIn
        ? ref.watch(bodyMetricsRangeProvider(range))
        : const AsyncValue<List<BodyMetric>>.loading();
    final allMetrics = signedIn
        ? ref.watch(allBodyMetricsProvider)
        : const AsyncValue<List<BodyMetric>>.loading();
    final goals = signedIn
        ? ref.watch(goalsProvider)
        : const AsyncValue<List<Goal>>.loading();
    final water = ref.watch(waterRangeProvider(range));

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: PhoneFrame(
          child: RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(nutritionRangeProvider);
              ref.invalidate(bodyMetricsRangeProvider);
              ref.invalidate(allBodyMetricsProvider);
              ref.invalidate(goalsProvider);
              ref.invalidate(waterRangeProvider);
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                _Header(period: period),
                const SizedBox(height: 16),
                _WeightCard(
                  metrics: metrics,
                  allMetrics: allMetrics,
                  goals: goals,
                ),
                const SizedBox(height: 12),
                _ChartCard(
                  title: 'Tiến trình cân nặng (kg)',
                  child: _WeightChart(
                      range: range, metrics: metrics, goals: goals),
                ),
                const SizedBox(height: 12),
                _ChartCard(
                  title: 'Theo dõi calo',
                  child: _CaloriesInChart(range: range, daily: nutrition),
                ),
                const SizedBox(height: 12),
                _ChartCard(
                  title: 'Theo dõi calo tiêu hao',
                  child: _CaloriesOutChart(range: range, daily: nutrition),
                ),
                const SizedBox(height: 12),
                _ChartCard(
                  title: 'Theo dõi nước',
                  child: _WaterChart(range: range, water: water),
                ),
                const SizedBox(height: 12),
                _BmiCard(allMetrics: allMetrics),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/* -------------------------------------------------------------------------- */
/* Header                                                                      */
/* -------------------------------------------------------------------------- */

class _Header extends ConsumerWidget {
  const _Header({required this.period});

  final Period period;

  Future<void> _pickMode(BuildContext context, WidgetRef ref) async {
    final mode = await showModalBottomSheet<PeriodMode>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final m in PeriodMode.values)
              ListTile(
                title: Text(m.label),
                trailing: m == period.mode
                    ? const Icon(Icons.check, color: RetroTokens.accent)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(m),
              ),
          ],
        ),
      ),
    );
    if (mode == null || !context.mounted) return;

    if (mode != PeriodMode.custom) {
      final now = DateTime.now();
      ref.read(periodProvider.notifier).state =
          Period(mode: mode, anchor: DateTime(now.year, now.month, now.day));
      return;
    }

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final firstDate = DateTime(now.year - 3);

    // The current period usually runs past today, and showDateRangePicker
    // asserts its initial range sits inside firstDate..lastDate — clamping
    // keeps the picker opening with the visible slice preselected.
    final initial = period.range.clampedTo(firstDate, today);

    final picked = await showDateRangePicker(
      context: context,
      firstDate: firstDate,
      lastDate: today,
      initialDateRange: DateTimeRange(start: initial.start, end: initial.end),
      helpText: 'CHỌN KHOẢNG THỜI GIAN',
    );
    if (picked == null) return;
    ref.read(periodProvider.notifier).state = Period(
      mode: PeriodMode.custom,
      anchor: picked.start,
      custom: DateRange(
        DateTime(picked.start.year, picked.start.month, picked.start.day),
        DateTime(picked.end.year, picked.end.month, picked.end.day),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A hand-picked range has nothing to step to, and there is no data after
    // today, so both arrows can be dead in the right circumstances.
    final canStep = period.mode != PeriodMode.custom;
    final canForward = canStep && !period.isLatest;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Tiến trình',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                  color: RetroTokens.ink,
                ),
              ),
            ),
            _ArrowButton(
              icon: Icons.chevron_left,
              tooltip: 'Kỳ trước',
              onTap: canStep
                  ? () =>
                      ref.read(periodProvider.notifier).state = period.step(-1)
                  : null,
            ),
            const SizedBox(width: 8),
            _ArrowButton(
              icon: Icons.chevron_right,
              tooltip: 'Kỳ sau',
              onTap: canForward
                  ? () =>
                      ref.read(periodProvider.notifier).state = period.step(1)
                  : null,
            ),
          ],
        ),
        const SizedBox(height: 2),
        InkWell(
          onTap: () => _pickMode(context, ref),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  period.label,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: RetroTokens.inkSoft,
                  ),
                ),
                const Icon(Icons.expand_more,
                    size: 18, color: RetroTokens.inkSoft),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ArrowButton extends StatelessWidget {
  const _ArrowButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: RetroTokens.paperRaised,
              shape: BoxShape.circle,
              border: Border.all(
                color: onTap == null ? RetroTokens.inkFaint : RetroTokens.ink,
                width: RetroTokens.border,
              ),
            ),
            child: Icon(icon,
                size: 20,
                color: onTap == null ? RetroTokens.inkFaint : RetroTokens.ink),
          ),
        ),
      );
}

/* -------------------------------------------------------------------------- */
/* Aggregation                                                                 */
/* -------------------------------------------------------------------------- */

enum _Agg { sum, average, last }

/// Turns a date→value map into the chart's buckets: one per day for a week or
/// a month, one per calendar month for anything longer.
List<Bucket> _bucketize(
  DateRange range,
  Map<String, double> byDate,
  _Agg agg,
) {
  if (range.days <= 31) {
    return [
      for (final day in range.dates)
        Bucket(
          label: range.tick(day),
          value: byDate[DateRange.iso(day)] ?? 0,
          hasData: byDate.containsKey(DateRange.iso(day)),
        ),
    ];
  }

  final months = <String, List<double>>{};
  for (final day in range.dates) {
    final value = byDate[DateRange.iso(day)];
    if (value == null) continue;
    months.putIfAbsent(DateFormat('MM/yy').format(day), () => []).add(value);
  }
  final labels = <String>[];
  for (final day in range.dates) {
    final label = DateFormat('MM/yy').format(day);
    if (labels.isEmpty || labels.last != label) labels.add(label);
  }
  return [
    for (final label in labels)
      Bucket(
        label: label,
        value: _reduce(months[label] ?? const [], agg),
        hasData: (months[label] ?? const []).isNotEmpty,
      ),
  ];
}

double _reduce(List<double> values, _Agg agg) {
  if (values.isEmpty) return 0;
  return switch (agg) {
    _Agg.sum => values.reduce((a, b) => a + b),
    _Agg.average => values.reduce((a, b) => a + b) / values.length,
    _Agg.last => values.last,
  };
}

/// Weight measurements keyed by local date, oldest first.
Map<String, double> _weightsByDate(List<BodyMetric> metrics) {
  final sorted = metrics.where((m) => m.weightKg != null).toList()
    ..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
  return {for (final m in sorted) m.localDate: m.weightKg!};
}

/// The active weight goal, if the user has one.
Goal? _weightGoal(List<Goal> goals) {
  for (final goal in goals) {
    final isWeight = goal.goalType == 'lose_weight' ||
        goal.goalType == 'gain_weight' ||
        goal.targetUnit == 'kg';
    if (isWeight && goal.status == 'active' && goal.targetValue != null) {
      return goal;
    }
  }
  return null;
}

/* -------------------------------------------------------------------------- */
/* Cards                                                                       */
/* -------------------------------------------------------------------------- */

class _ChartCard extends StatelessWidget {
  const _ChartCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => HomeCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(height: 14),
            child,
          ],
        ),
      );
}

class _WeightCard extends StatelessWidget {
  const _WeightCard({
    required this.metrics,
    required this.allMetrics,
    required this.goals,
  });

  final AsyncValue<List<BodyMetric>> metrics;
  final AsyncValue<List<BodyMetric>> allMetrics;
  final AsyncValue<List<Goal>> goals;

  static final _kg = NumberFormat('#,##0.#');

  @override
  Widget build(BuildContext context) {
    final inRange = _weightsByDate(metrics.valueOrNull ?? const []);
    final everything = _weightsByDate(allMetrics.valueOrNull ?? const []);
    final goal = _weightGoal(goals.valueOrNull ?? const []);

    final periodValues = inRange.values.toList();
    final current = periodValues.isNotEmpty
        ? periodValues.last
        : (everything.values.isNotEmpty ? everything.values.last : null);
    final change = periodValues.length >= 2
        ? periodValues.last - periodValues.first
        : null;
    final start = goal?.startValue ??
        (everything.values.isNotEmpty ? everything.values.first : null);
    final progress = goal?.progress(current) ?? 0;

    return HomeCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _PanelStat(
                  label: 'THAY ĐỔI',
                  value: change == null
                      ? '—'
                      : '${change > 0 ? '+' : ''}${_kg.format(change)} kg',
                  tone: change == null
                      ? RetroTokens.ink
                      : (change <= 0 ? RetroTokens.fat : RetroTokens.protein),
                ),
              ),
              Expanded(
                child: _PanelStat(
                  label: 'CÂN NẶNG HIỆN TẠI',
                  value: current == null ? '—' : '${_kg.format(current)} kg',
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(color: RetroTokens.paperSunk, height: 1, thickness: 1),
          const SizedBox(height: 14),
          Text(
            'ĐÃ ĐẠT ĐƯỢC ${(progress * 100).round()}% MỤC TIÊU',
            style: const TextStyle(
              fontSize: 11,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w700,
              color: RetroTokens.inkSoft,
            ),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(RetroTokens.radiusPill),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 10,
              backgroundColor: RetroTokens.paperSunk,
              valueColor: const AlwaysStoppedAnimation(RetroTokens.fat),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(start == null ? '—' : '${_kg.format(start)} kg',
                  style: const TextStyle(
                      fontSize: 12, color: RetroTokens.inkSoft)),
              const Expanded(
                child: Icon(Icons.arrow_forward,
                    size: 14, color: RetroTokens.inkSoft),
              ),
              Text(
                goal?.targetValue == null
                    ? 'chưa đặt mục tiêu'
                    : '${_kg.format(goal!.targetValue)} kg',
                style:
                    const TextStyle(fontSize: 12, color: RetroTokens.inkSoft),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PanelStat extends StatelessWidget {
  const _PanelStat({
    required this.label,
    required this.value,
    this.tone = RetroTokens.ink,
  });

  final String label;
  final String value;
  final Color tone;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                fontSize: 10,
                letterSpacing: 0.8,
                fontWeight: FontWeight.w700,
                color: RetroTokens.inkSoft,
              )),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              softWrap: false,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(color: tone, fontSize: 24),
            ),
          ),
        ],
      );
}

class _WeightChart extends StatelessWidget {
  const _WeightChart({
    required this.range,
    required this.metrics,
    required this.goals,
  });

  final DateRange range;
  final AsyncValue<List<BodyMetric>> metrics;
  final AsyncValue<List<Goal>> goals;

  @override
  Widget build(BuildContext context) {
    if (metrics.isLoading) return const ChartEmpty();
    final goal = _weightGoal(goals.valueOrNull ?? const []);
    final buckets = _bucketize(
        range, _weightsByDate(metrics.valueOrNull ?? const []), _Agg.last);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        WeightLineChart(buckets: buckets, goalWeightKg: goal?.targetValue),
        const SizedBox(height: 10),
        const ChartLegend(items: [
          (RetroTokens.warn, 'Mục tiêu cân nặng'),
          (RetroTokens.accent, 'Cân nặng ghi nhận'),
        ]),
      ],
    );
  }
}

class _CaloriesInChart extends StatelessWidget {
  const _CaloriesInChart({required this.range, required this.daily});

  final DateRange range;
  final AsyncValue<List<DailyNutrition>> daily;

  @override
  Widget build(BuildContext context) {
    final days = daily.valueOrNull ?? const <DailyNutrition>[];
    if (daily.isLoading) return const ChartEmpty();

    final byDate = {
      for (final d in days)
        if (d.consumedKcal > 0) d.date: d.consumedKcal,
    };
    // Target: the day's own TDEE where the API computed one, otherwise the
    // shared fallback — the same number the home screen calls "Mục tiêu".
    final tdees = days.map((d) => d.tdeeKcal).whereType<double>().toList();
    final target = tdees.isEmpty
        ? DailyTargets.fallbackKcal
        : tdees.reduce((a, b) => a + b) / tdees.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SeriesBarChart(
          buckets: _bucketize(range, byDate, _Agg.average),
          color: RetroTokens.fat,
          overColor: RetroTokens.accent,
          target: target,
        ),
        const SizedBox(height: 10),
        ChartLegend(items: [
          (RetroTokens.fat, 'Trong mục tiêu'),
          (RetroTokens.accent, 'Vượt mục tiêu'),
          (RetroTokens.ink, 'Mục tiêu ${target.round()} kcal'),
        ]),
      ],
    );
  }
}

class _CaloriesOutChart extends StatelessWidget {
  const _CaloriesOutChart({required this.range, required this.daily});

  final DateRange range;
  final AsyncValue<List<DailyNutrition>> daily;

  @override
  Widget build(BuildContext context) {
    if (daily.isLoading) return const ChartEmpty();
    final byDate = {
      for (final d in daily.valueOrNull ?? const <DailyNutrition>[])
        if (d.burnedKcal > 0) d.date: d.burnedKcal,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SeriesBarChart(
          buckets: _bucketize(range, byDate, _Agg.average),
          color: RetroTokens.info,
        ),
        const SizedBox(height: 10),
        const ChartLegend(items: [
          (RetroTokens.info, 'Calo tiêu hao từ vận động'),
        ]),
      ],
    );
  }
}

class _WaterChart extends ConsumerWidget {
  const _WaterChart({required this.range, required this.water});

  final DateRange range;
  final AsyncValue<Map<String, int>> water;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (water.isLoading) return const ChartEmpty();
    final target = ref.watch(waterTargetProvider).toDouble();
    final byDate = {
      for (final entry in (water.valueOrNull ?? const <String, int>{}).entries)
        if (entry.value > 0) entry.key: entry.value.toDouble(),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SeriesBarChart(
          buckets: _bucketize(range, byDate, _Agg.average),
          color: RetroTokens.water,
          target: target,
        ),
        const SizedBox(height: 10),
        ChartLegend(items: [
          (RetroTokens.water, 'Lượng nước (ml)'),
          (RetroTokens.ink, 'Mục tiêu ${target.round()} ml'),
        ]),
      ],
    );
  }
}

/* -------------------------------------------------------------------------- */
/* BMI                                                                         */
/* -------------------------------------------------------------------------- */

class _BmiBand {
  const _BmiBand(this.label, this.range, this.color);

  final String label;
  final String range;
  final Color color;
}

const _bmiBands = [
  _BmiBand('Thiếu cân', '<18.5', RetroTokens.info),
  _BmiBand('Khỏe mạnh', '18.5–24.9', RetroTokens.fat),
  _BmiBand('Thừa cân', '25.0–29.9', RetroTokens.warn),
  _BmiBand('Béo phì', '>30.0', RetroTokens.accent),
];

class _BmiCard extends StatelessWidget {
  const _BmiCard({required this.allMetrics});

  final AsyncValue<List<BodyMetric>> allMetrics;

  /// The marker spans 15–40 BMI; anything outside pins to an edge.
  static const _min = 15.0;
  static const _max = 40.0;

  static _BmiBand _bandFor(double bmi) {
    if (bmi < 18.5) return _bmiBands[0];
    if (bmi < 25) return _bmiBands[1];
    if (bmi < 30) return _bmiBands[2];
    return _bmiBands[3];
  }

  @override
  Widget build(BuildContext context) {
    final metrics = (allMetrics.valueOrNull ?? const <BodyMetric>[]).toList()
      ..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
    final weight = metrics.lastWhere((m) => m.weightKg != null,
        orElse: () => const BodyMetric(recordedAt: 0, localDate: ''));
    // Height is entered once and rarely again, so the latest known one wins
    // even if it predates the current period.
    final height = metrics.lastWhere((m) => m.heightCm != null,
        orElse: () => const BodyMetric(recordedAt: 0, localDate: ''));
    final kg = weight.weightKg;
    final cm = height.heightCm;
    final bmi = (kg == null || cm == null || cm <= 0)
        ? null
        : kg / ((cm / 100) * (cm / 100));

    return HomeCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Chỉ số BMI của bạn',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              ),
              Tooltip(
                triggerMode: TooltipTriggerMode.tap,
                showDuration: const Duration(seconds: 6),
                message: 'BMI = cân nặng (kg) chia cho bình phương chiều cao '
                    '(m). Là chỉ số tham khảo, không phân biệt cơ và mỡ.',
                child: Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: RetroTokens.inkSoft),
                  ),
                  child: const Text('?',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: RetroTokens.inkSoft)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (bmi == null)
            const Text(
              'Cần cân nặng và chiều cao để tính BMI.',
              style: TextStyle(fontSize: 12, color: RetroTokens.inkFaint),
            )
          else ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(bmi.toStringAsFixed(1),
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(width: 10),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _bandFor(bmi).color,
                    borderRadius: BorderRadius.circular(RetroTokens.radiusPill),
                  ),
                  child: Text(
                    _bandFor(bmi).label,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.white),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, constraints) {
                final ratio = ((bmi - _min) / (_max - _min)).clamp(0.0, 1.0);
                return SizedBox(
                  height: 18,
                  child: Stack(
                    children: [
                      Container(
                        height: 18,
                        decoration: BoxDecoration(
                          borderRadius:
                              BorderRadius.circular(RetroTokens.radiusPill),
                          gradient: const LinearGradient(
                            colors: [
                              RetroTokens.info,
                              RetroTokens.fat,
                              RetroTokens.warn,
                              RetroTokens.accent,
                            ],
                            // Stops mirror the real BMI cut-offs on a 15–40
                            // scale: 18.5, 25 and 30.
                            stops: [0.14, 0.40, 0.60, 1.0],
                          ),
                        ),
                      ),
                      Positioned(
                        left: (constraints.maxWidth - 3) * ratio,
                        child: Container(
                          width: 3,
                          height: 18,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(2),
                            border:
                                Border.all(color: RetroTokens.ink, width: 0.5),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 14,
              runSpacing: 8,
              children: [
                for (final band in _bmiBands)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                            color: band.color, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 6),
                      Text('${band.label} ${band.range}',
                          style: const TextStyle(
                              fontSize: 11, color: RetroTokens.inkSoft)),
                    ],
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
