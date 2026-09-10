import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format/units.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/retro_widgets.dart';

class TrainingScreen extends ConsumerWidget {
  const TrainingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(workoutFeedProvider);
    final records = ref.watch(personalRecordsProvider);
    final units = Units(ref.watch(unitSystemProvider));

    return Scaffold(
      appBar: AppBar(title: const Text('Luyện tập')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/record'),
        backgroundColor: RetroTokens.accent,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.play_arrow),
        label: const Text('Bắt đầu'),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(workoutFeedProvider);
          ref.invalidate(personalRecordsProvider);
        },
        child: PhoneFrame(
          child: ListView(
            children: [
              const SectionTitle('Kỷ lục cá nhân'),
              SizedBox(
                // Tall enough for a two-word caption under the value; 96 clipped it.
                height: 108,
                child: asyncBody(
                  records,
                  emptyWhen: (list) => list.isEmpty,
                  emptyText:
                      'Chưa có PR nào — tập một buổi để hệ thống tự phát hiện.',
                  data: (list) => ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 12),
                    itemBuilder: (_, i) {
                      final pr = list[i];
                      return SizedBox(
                        width: 160,
                        child: StatTile(
                          value: _prValue(pr.metric, pr.value, units),
                          label: _prLabel(pr.metric, pr.distanceM),
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SectionTitle('Buổi tập gần đây'),
              asyncBody(
                feed,
                emptyWhen: (list) => list.isEmpty,
                emptyText: 'Chưa có buổi tập nào.',
                onRetry: () => ref.invalidate(workoutFeedProvider),
                data: (list) => Column(
                  // Without this the cards size to their text and the feed looks ragged.
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final session in list)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: RetroBox(
                          onTap: () => context.push('/workouts/${session.id}'),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(session.title ?? 'Buổi tập',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700)),
                              const SizedBox(height: 4),
                              Text(
                                '${session.localDate} · '
                                '${units.distance(session.distanceM)} · '
                                '${Units.duration(session.durationSeconds)} · '
                                '${units.pace(session.avgPaceSecPerKm)}',
                                style: const TextStyle(
                                    fontSize: 12, color: RetroTokens.inkSoft),
                              ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 96),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _prValue(String metric, double value, Units units) => switch (metric) {
      'fastest_distance' || 'longest_duration' => Units.duration(value.round()),
      'longest_distance' => units.distance(value),
      'max_weight' => units.weight(value),
      'best_pace' => units.pace(value),
      _ => value.toStringAsFixed(0),
    };

String _prLabel(String metric, double? distanceM) => switch (metric) {
      'fastest_distance' =>
        'nhanh nhất ${((distanceM ?? 0) / 1000).toStringAsFixed(distanceM == 21097 || distanceM == 42195 ? 1 : 0)} km',
      'longest_distance' => 'quãng đường dài nhất',
      'longest_duration' => 'buổi dài nhất',
      'max_weight' => 'tạ nặng nhất',
      'max_reps' => 'số rep nhiều nhất',
      'max_volume' => 'khối lượng lớn nhất',
      'best_pace' => 'pace tốt nhất',
      _ => metric,
    };
