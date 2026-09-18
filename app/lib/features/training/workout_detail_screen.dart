import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/units.dart';
import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/retro_widgets.dart';
import 'activity_format.dart';
import 'route_map.dart';

class WorkoutDetailScreen extends ConsumerWidget {
  const WorkoutDetailScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final units = Units(ref.watch(unitSystemProvider));
    final detail = ref.watch(workoutDetailProvider(sessionId));
    final types = ref.watch(activityTypesProvider).valueOrNull ?? const [];

    return Scaffold(
      appBar: AppBar(title: const Text('Buổi tập')),
      body: PhoneFrame(
        child: asyncBody(
          detail,
          onRetry: () => ref.invalidate(workoutDetailProvider(sessionId)),
          data: (data) {
            final session = WorkoutSession.fromJson(data);
            final splits = (data['splits'] as List? ?? const [])
                .whereType<Map>()
                .map((e) => WorkoutSplit.fromJson(e.cast<String, dynamic>()))
                .toList();
            final zones = (data['zones'] as List? ?? const [])
                .whereType<Map>()
                .map((e) => ZoneSummary.fromJson(e.cast<String, dynamic>()))
                .toList();
            final stream = data['stream'];
            final route = decodePolyline(
              stream is Map ? stream['encodedPolyline'] as String? : null,
            );
            final type = types
                .where((t) => t.id == session.activityTypeId)
                .firstOrNull;

            return ListView(
              children: [
                if (route.isNotEmpty)
                  SizedBox(
                    height: 280,
                    child: RouteMap(points: route, interactive: true),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            activityIcon(type?.code),
                            size: 16,
                            color: RetroTokens.inkSoft,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            workoutWhen(session.startedAt),
                            style: const TextStyle(
                              fontSize: 12,
                              color: RetroTokens.inkSoft,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        session.title ?? defaultWorkoutTitle(session, type),
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: RetroBox(
                    child: Row(
                      children: [
                        Expanded(
                          child: _stat(
                            context,
                            units.distance(session.distanceM),
                            'quãng đường',
                          ),
                        ),
                        Expanded(
                          child: _stat(
                            context,
                            Units.duration(session.durationSeconds),
                            'thời gian',
                          ),
                        ),
                        Expanded(
                          child: _stat(
                            context,
                            units.pace(session.avgPaceSecPerKm),
                            'pace',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (zones.isNotEmpty) ...[
                  const SectionTitle('Vùng nhịp tim'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: RetroBox(child: _ZoneBars(zones: zones)),
                  ),
                ],
                if (splits.isNotEmpty) ...[
                  const SectionTitle('Chia chặng (mỗi km)'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: RetroBox(
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: [
                          for (final split in splits)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 28,
                                    child: Text(
                                      '${split.splitIndex}',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.labelSmall,
                                    ),
                                  ),
                                  Expanded(
                                    child: Text(
                                      units.pace(split.avgPaceSecPerKm),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    split.avgHeartRate == null
                                        ? '—'
                                        : '${split.avgHeartRate} bpm',
                                    style: const TextStyle(
                                      color: RetroTokens.inkSoft,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 40),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _stat(BuildContext context, String value, String label) => Column(
    children: [
      Text(
        value,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 20),
      ),
      Text(
        label,
        style: const TextStyle(fontSize: 12, color: RetroTokens.inkSoft),
      ),
    ],
  );
}

/// Time-in-zone. Zone colours are fixed in the tokens so Z4 always looks like Z4.
class _ZoneBars extends StatelessWidget {
  const _ZoneBars({required this.zones});

  final List<ZoneSummary> zones;

  @override
  Widget build(BuildContext context) {
    final maxSeconds = zones
        .map((z) => z.secondsInZone)
        .fold<int>(1, (a, b) => a > b ? a : b);
    return Column(
      children: [
        for (final zone in zones)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: Text(
                    'Z${zone.zoneNumber}',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
                Expanded(
                  child: Stack(
                    children: [
                      Container(height: 16, color: RetroTokens.paperSunk),
                      FractionallySizedBox(
                        widthFactor: (zone.secondsInZone / maxSeconds).clamp(
                          0.02,
                          1,
                        ),
                        child: Container(
                          height: 16,
                          color:
                              RetroTokens.zoneColors[(zone.zoneNumber - 1)
                                  .clamp(0, RetroTokens.zoneColors.length - 1)],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 64,
                  child: Text(
                    Units.duration(zone.secondsInZone),
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 12,
                      color: RetroTokens.inkSoft,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
