import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import '../../core/l10n/gen/app_localizations.dart';

/// One plotted column: an x label plus the value, already aggregated. Charts
/// never see raw dates, so a week (7 daily buckets) and a year (12 monthly
/// buckets) render through exactly the same code.
class Bucket {
  const Bucket({required this.label, required this.value, this.hasData = true});

  final String label;
  final double value;
  final bool hasData;
}

/// Bottom-axis labels thin out as the period grows: 7 buckets show every label,
/// a month shows every fifth.
int _labelStride(int count) => count <= 8 ? 1 : (count / 6).ceil();

Widget _bottomLabel(List<Bucket> buckets, double value, TitleMeta meta) {
  final i = value.round();
  if (i < 0 || i >= buckets.length) return const SizedBox.shrink();
  if (i % _labelStride(buckets.length) != 0) return const SizedBox.shrink();
  return Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Text(
      buckets[i].label,
      style: const TextStyle(fontSize: 10, color: RetroTokens.inkFaint),
    ),
  );
}

Widget _leftLabel(double value, TitleMeta meta) => Text(
  value.round().toString(),
  style: const TextStyle(fontSize: 10, color: RetroTokens.inkFaint),
);

FlGridData _grid(double interval) => FlGridData(
  show: true,
  drawVerticalLine: false,
  horizontalInterval: interval <= 0 ? 1 : interval,
  getDrawingHorizontalLine: (_) =>
      const FlLine(color: RetroTokens.paperSunk, strokeWidth: 1),
);

/// A dashed horizontal reference line — the weight goal, the calorie target,
/// the water target. Always the same look so it reads as "target" everywhere.
ExtraLinesData _targetLine(double? y, Color color) => ExtraLinesData(
  horizontalLines: [
    if (y != null)
      HorizontalLine(
        y: y,
        color: color,
        strokeWidth: 2,
        dashArray: const [6, 4],
      ),
  ],
);

class ChartEmpty extends StatelessWidget {
  const ChartEmpty({super.key, this.height = 160});

  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: Center(
      child: Text(
        AppL10n.of(context).chuaCoDuLieuTrongKy,
        style: TextStyle(fontSize: 12, color: RetroTokens.inkFaint),
      ),
    ),
  );
}

/// Weight over the period, with a dashed line at the goal weight.
class WeightLineChart extends StatelessWidget {
  const WeightLineChart({
    super.key,
    required this.buckets,
    this.goalWeightKg,
    this.height = 180,
  });

  final List<Bucket> buckets;
  final double? goalWeightKg;
  final double height;

  @override
  Widget build(BuildContext context) {
    final spots = [
      for (var i = 0; i < buckets.length; i++)
        if (buckets[i].hasData) FlSpot(i.toDouble(), buckets[i].value),
    ];
    if (spots.length < 2) return const ChartEmpty();

    final values = [
      ...spots.map((s) => s.y),
      if (goalWeightKg != null) goalWeightKg!,
    ];
    // Whole-kilogram bounds: with a fractional max the axis draws a label at
    // the edge *and* at the last interval, and the two round to the same number
    // and overprint each other.
    final min = (values.reduce((a, b) => a < b ? a : b) - 1).floorToDouble();
    var max = (values.reduce((a, b) => a > b ? a : b) + 1).ceilToDouble();
    if (max - min < 4) max = min + 4;

    return SizedBox(
      height: height,
      child: LineChart(
        LineChartData(
          minY: min,
          maxY: max,
          minX: 0,
          maxX: (buckets.length - 1).toDouble(),
          gridData: _grid((max - min) / 4),
          borderData: FlBorderData(show: false),
          lineTouchData: const LineTouchData(enabled: false),
          extraLinesData: _targetLine(goalWeightKg, RetroTokens.warn),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 30,
                interval: (max - min) / 4,
                getTitlesWidget: _leftLabel,
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 24,
                interval: 1,
                getTitlesWidget: (v, meta) => _bottomLabel(buckets, v, meta),
              ),
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              curveSmoothness: 0.2,
              color: RetroTokens.accent,
              barWidth: 2.5,
              dotData: const FlDotData(show: true),
              belowBarData: BarAreaData(show: false),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bars per bucket with an optional target line. `overColor` marks buckets that
/// exceed the target — used for calories, where over is the bad direction.
class SeriesBarChart extends StatelessWidget {
  const SeriesBarChart({
    super.key,
    required this.buckets,
    required this.color,
    this.target,
    this.overColor,
    this.height = 180,
  });

  final List<Bucket> buckets;
  final Color color;
  final double? target;
  final Color? overColor;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (buckets.every((b) => b.value <= 0)) return const ChartEmpty();

    final peak = buckets.map((b) => b.value).reduce((a, b) => a > b ? a : b);
    final max = [peak, target ?? 0].reduce((a, b) => a > b ? a : b) * 1.2;
    final interval = (max / 4).ceilToDouble();

    return SizedBox(
      height: height,
      child: BarChart(
        BarChartData(
          maxY: max <= 0 ? 1 : max,
          alignment: BarChartAlignment.spaceAround,
          barTouchData: BarTouchData(
            enabled: true,
            touchTooltipData: BarTouchTooltipData(
              getTooltipItem: (group, _, rod, __) => BarTooltipItem(
                '${buckets[group.x].label}\n${rod.toY.round()}',
                const TextStyle(color: Colors.white, fontSize: 11),
              ),
            ),
          ),
          gridData: _grid(interval),
          borderData: FlBorderData(show: false),
          extraLinesData: _targetLine(target, RetroTokens.ink),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 36,
                interval: interval <= 0 ? 1 : interval,
                getTitlesWidget: _leftLabel,
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 24,
                getTitlesWidget: (v, meta) => _bottomLabel(buckets, v, meta),
              ),
            ),
          ),
          barGroups: [
            for (var i = 0; i < buckets.length; i++)
              BarChartGroupData(
                x: i,
                barRods: [
                  BarChartRodData(
                    toY: buckets[i].value,
                    width: buckets.length > 14 ? 6 : 14,
                    borderRadius: BorderRadius.circular(4),
                    color:
                        target != null &&
                            overColor != null &&
                            buckets[i].value > target!
                        ? overColor
                        : color,
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Legend row under a chart: a colour swatch and what it means.
class ChartLegend extends StatelessWidget {
  const ChartLegend({super.key, required this.items});

  final List<(Color, String)> items;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 14,
    runSpacing: 6,
    children: [
      for (final (color, label) in items)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 14, height: 3, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(fontSize: 11, color: RetroTokens.inkSoft),
            ),
          ],
        ),
    ],
  );
}
