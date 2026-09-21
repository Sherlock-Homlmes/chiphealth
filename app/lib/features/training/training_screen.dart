import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/format/units.dart';
import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/retro_widgets.dart';
import 'activity_format.dart';
import 'progress_tab.dart';
import 'route_map.dart';
import 'workout_photos.dart';
import '../../core/l10n/gen/app_localizations.dart';

class TrainingScreen extends ConsumerWidget {
  const TrainingScreen({super.key});

  /// Record live (GPS / stopwatch) or type in a session that already happened.
  Future<void> _chooseEntry(BuildContext context) async {
    final path = await showModalBottomSheet<String>(
      context: context,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.play_circle_outline),
              title: Text(AppL10n.of(context).ghiTrucTiep),
              subtitle: Text(AppL10n.of(context).bamGioTheoDoiGps),
              onTap: () => Navigator.of(sheet).pop('/record'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_note),
              title: Text(AppL10n.of(context).nhapTay),
              subtitle: Text(AppL10n.of(context).buoiDaTapTinhKcalVao),
              onTap: () => Navigator.of(sheet).pop('/workouts/manual'),
            ),
          ],
        ),
      ),
    );
    if (path != null && context.mounted) await context.push<void>(path);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Progress first, and the tab the screen opens on: what the training is
    // adding up to is the question this screen is opened with, and the feed is
    // one tap away for the session someone is looking for.
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(AppL10n.of(context).hoatDong),
          bottom: TabBar(
            tabs: [
              Tab(text: AppL10n.of(context).tienTrinh),
              Tab(text: AppL10n.of(context).hoatDong),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton(
          tooltip: AppL10n.of(context).ghiHoatDongMoi,
          onPressed: () => _chooseEntry(context),
          backgroundColor: RetroTokens.accent,
          foregroundColor: Colors.white,
          child: const Icon(Icons.add),
        ),
        body: const TabBarView(
          children: [TrainingProgressTab(), _ActivityFeed()],
        ),
      ),
    );
  }
}

/// The feed tab: personal records across the top, then every session, newest
/// first — the screen this one used to be before the progress tab joined it.
class _ActivityFeed extends ConsumerWidget {
  const _ActivityFeed();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(workoutFeedProvider);
    final records = ref.watch(personalRecordsProvider);
    final units = Units(ref.watch(unitSystemProvider));
    final user = ref.watch(authControllerProvider).user;
    final types = {
      for (final t
          in ref.watch(activityTypesProvider).valueOrNull ??
              const <ActivityType>[])
        t.id: t,
    };

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(workoutFeedProvider);
        ref.invalidate(personalRecordsProvider);
      },
      child: PhoneFrame(
        child: ListView(
          children: [
            SectionTitle(AppL10n.of(context).kyLucCaNhan),
            SizedBox(
              // Tall enough for a two-word caption under the value; 96 clipped it.
              height: 108,
              child: asyncBody(
                records,
                emptyWhen: (list) => list.isEmpty,
                emptyText: AppL10n.of(context).chuaCoPrNaoTapMot,
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
                        label: _prLabel(context, pr.metric, pr.distanceM),
                      ),
                    );
                  },
                ),
              ),
            ),
            SectionTitle(AppL10n.of(context).hoatDong),
            asyncBody(
              feed,
              emptyWhen: (list) => list.isEmpty,
              emptyText: AppL10n.of(context).chuaCoHoatDongNaoBam,
              onRetry: () => ref.invalidate(workoutFeedProvider),
              data: (list) => Column(
                // Without this the cards size to their text and the feed looks ragged.
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final session in list)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: ActivityCard(
                        session: session,
                        type: types[session.activityTypeId],
                        user: user,
                        units: units,
                      ),
                    ),
                  const SizedBox(height: 96),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One feed entry, laid out like Strava's: who and when, title, three stats,
/// then the route map edge to edge.
class ActivityCard extends StatelessWidget {
  const ActivityCard({
    super.key,
    required this.session,
    required this.type,
    required this.user,
    required this.units,
  });

  final WorkoutSession session;
  final ActivityType? type;
  final AppUser? user;
  final Units units;

  @override
  Widget build(BuildContext context) {
    final route = decodePolyline(session.polyline);
    final stats = workoutStats(context, session, type, units);
    final name =
        user?.displayName ??
        user?.email.split('@').first ??
        AppL10n.of(context).ban;

    return RetroBox(
      padding: EdgeInsets.zero,
      onTap: () => context.push('/workouts/${session.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _Avatar(url: user?.avatarUrl, name: name),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Icon(
                                activityIcon(type?.code),
                                size: 14,
                                color: RetroTokens.inkSoft,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  workoutWhen(context, session.startedAt),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: RetroTokens.inkSoft,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  session.title ?? defaultWorkoutTitle(context, session, type),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < stats.length; i++) ...[
                        if (i > 0)
                          const VerticalDivider(
                            width: 24,
                            thickness: 1,
                            color: RetroTokens.paperSunk,
                          ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              stats[i].label,
                              style: const TextStyle(
                                fontSize: 11,
                                color: RetroTokens.inkSoft,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              stats[i].value,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                // The first photos of the session, like the meal diary's tile:
                // enough to recognise the session, tap through for the rest.
                if (session.photoAssetIds.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 56,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: session.photoAssetIds.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (_, i) => WorkoutPhotoTile(
                        assetId: session.photoAssetIds[i],
                        size: 56,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (route.isNotEmpty)
            SizedBox(height: 200, child: RouteMap(points: route)),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.url, required this.name});

  final String? url;
  final String name;

  @override
  Widget build(BuildContext context) => CircleAvatar(
    radius: 18,
    backgroundColor: RetroTokens.accentSoft,
    foregroundImage: url == null ? null : NetworkImage(url!),
    child: Text(
      name.isEmpty ? '?' : name.characters.first.toUpperCase(),
      style: const TextStyle(
        color: RetroTokens.accent,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

String _prValue(String metric, double value, Units units) => switch (metric) {
  'fastest_distance' || 'longest_duration' => Units.duration(value.round()),
  'longest_distance' => units.distance(value),
  'max_weight' => units.weight(value),
  'best_pace' => units.pace(value),
  _ => value.toStringAsFixed(0),
};

String _prLabel(BuildContext context, String metric, double? distanceM) =>
    switch (metric) {
      'fastest_distance' => AppL10n.of(context).prFastestDistance(
        ((distanceM ?? 0) / 1000).toStringAsFixed(
          distanceM == 21097 || distanceM == 42195 ? 1 : 0,
        ),
      ),
      'longest_distance' => AppL10n.of(context).quangDuongDaiNhat,
      'longest_duration' => AppL10n.of(context).buoiDaiNhat,
      'max_weight' => AppL10n.of(context).taNangNhat,
      'max_reps' => AppL10n.of(context).soRepNhieuNhat,
      'max_volume' => AppL10n.of(context).khoiLuongLonNhat,
      'best_pace' => AppL10n.of(context).paceTotNhat,
      // Every metric the server can send needs a case here: without one the raw
      // column name ("max_elevation_gain") went straight onto the card.
      'max_elevation_gain' => AppL10n.of(context).doCaoLonNhat,
      _ => metric,
    };
