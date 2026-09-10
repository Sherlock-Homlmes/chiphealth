import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/format/units.dart';
import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/retro_widgets.dart';

final meProvider = FutureProvider<Map<String, dynamic>>(
    (ref) => ref.watch(profileRepositoryProvider).me());

final bodyMetricsProvider = FutureProvider<List<BodyMetric>>(
    (ref) => ref.watch(profileRepositoryProvider).bodyMetrics());

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    final metrics = ref.watch(bodyMetricsProvider);
    final units = Units(ref.watch(unitSystemProvider));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cá nhân'),
        actions: [
          TextButton(
            onPressed: () =>
                ref.read(authControllerProvider.notifier).signOut(),
            child: const Text('Đăng xuất'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(meProvider);
          ref.invalidate(bodyMetricsProvider);
        },
        child: PhoneFrame(
          child: asyncBody(
            me,
            onRetry: () => ref.invalidate(meProvider),
            data: (data) {
              final goals = (data['goals'] as List? ?? const [])
                  .whereType<Map>()
                  .map((e) => Goal.fromJson(e.cast<String, dynamic>()))
                  .toList();
              final conditions = (data['conditions'] as List? ?? const [])
                  .whereType<Map>()
                  .map((e) =>
                      ChronicCondition.fromJson(e.cast<String, dynamic>()))
                  .toList();
              final latest =
                  (data['latestBodyMetric'] as Map?)?.cast<String, dynamic>();

              return ListView(
                children: [
                  const SectionTitle('Cơ thể'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Expanded(
                            child: StatTile(
                          value: units.weight(
                              (latest?['weightKg'] as num?)?.toDouble()),
                          label: 'cân nặng',
                        )),
                        const SizedBox(width: 12),
                        Expanded(
                            child: StatTile(
                          value: units.height(
                              (latest?['heightCm'] as num?)?.toDouble()),
                          label: 'chiều cao',
                        )),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: asyncBody(
                      metrics,
                      emptyWhen: (list) => list.length < 2,
                      emptyText: 'Ghi thêm vài lần cân để thấy biểu đồ.',
                      data: (list) =>
                          RetroBox(child: _WeightSparkline(metrics: list)),
                    ),
                  ),
                  const SectionTitle('Mục tiêu'),
                  if (goals.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Text('Chưa đặt mục tiêu nào.',
                          style: TextStyle(color: RetroTokens.inkFaint)),
                    ),
                  for (final goal in goals)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: RetroBox(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_goalLabel(goal.goalType),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                            Text(
                              'từ ${goal.startValue.toStringAsFixed(1)} → '
                              '${goal.targetValue?.toStringAsFixed(1) ?? '—'} ${goal.targetUnit ?? ''}'
                              '${goal.deadline != null ? ' · hạn ${goal.deadline}' : ''}',
                              style: const TextStyle(
                                  fontSize: 12, color: RetroTokens.inkSoft),
                            ),
                            const SizedBox(height: 6),
                            LinearProgressIndicator(
                              value: goal.progress(
                                  (latest?['weightKg'] as num?)?.toDouble()),
                              backgroundColor: RetroTokens.paperSunk,
                              color: RetroTokens.accent,
                              minHeight: 8,
                            ),
                          ],
                        ),
                      ),
                    ),
                  const SectionTitle('Bệnh nền'),
                  if (conditions.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Text('Không khai báo bệnh nền.',
                          style: TextStyle(color: RetroTokens.inkFaint)),
                    ),
                  for (final condition in conditions)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: RetroBox(child: Text(condition.description)),
                    ),
                  const SizedBox(height: 40),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

String _goalLabel(String type) => switch (type) {
      'lose_weight' => 'Giảm cân',
      'gain_weight' => 'Tăng cân',
      'gain_muscle' => 'Tăng cơ',
      'reduce_body_fat' => 'Giảm mỡ',
      'improve_endurance' => 'Tăng sức bền',
      'improve_strength' => 'Tăng sức mạnh',
      'sleep_better' => 'Ngủ tốt hơn',
      _ => 'Kiểm soát bệnh nền',
    };

/// Weight over time. A sparkline rather than a full chart: the trend is the
/// message, and the exact numbers are one tap away.
class _WeightSparkline extends StatelessWidget {
  const _WeightSparkline({required this.metrics});

  final List<BodyMetric> metrics;

  @override
  Widget build(BuildContext context) {
    final points = metrics.where((m) => m.weightKg != null).toList()
      ..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
    if (points.length < 2) return const SizedBox.shrink();

    return SizedBox(
      height: 80,
      child: CustomPaint(
        painter: _SparklinePainter(points.map((p) => p.weightKg!).toList()),
        size: Size.infinite,
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.values);

  final List<double> values;

  @override
  void paint(Canvas canvas, Size size) {
    final min = values.reduce((a, b) => a < b ? a : b);
    final max = values.reduce((a, b) => a > b ? a : b);
    final span = (max - min).abs() < 0.01 ? 1.0 : max - min;

    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = size.width * (i / (values.length - 1));
      final y = size.height - ((values[i] - min) / span) * size.height;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = RetroTokens.accent
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) =>
      oldDelegate.values != values;
}
