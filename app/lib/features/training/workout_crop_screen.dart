import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format/units.dart';
import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/retro_widgets.dart';
import 'route_map.dart';
import '../../core/l10n/gen/app_localizations.dart';

/// Strava's Crop: drag the two handles to trim the start and end of a
/// recording (the walk to the start line, the forgotten stop button).
class WorkoutCropScreen extends ConsumerStatefulWidget {
  const WorkoutCropScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<WorkoutCropScreen> createState() => _WorkoutCropScreenState();
}

class _WorkoutCropScreenState extends ConsumerState<WorkoutCropScreen> {
  RangeValues? _range;
  bool _saving = false;

  Future<void> _crop(List<TrackPoint> track, RangeValues range) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(AppL10n.of(context).catHoatDong2),
        content: Text(AppL10n.of(context).phanBiCatSeBiXoa),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(AppL10n.of(context).khong),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(AppL10n.of(context).cat),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _saving = true);
    try {
      await ref
          .read(trainingRepositoryProvider)
          .crop(widget.sessionId, range.start, range.end);
      ref.invalidate(workoutDetailProvider(widget.sessionId));
      ref.invalidate(workoutTrackProvider(widget.sessionId));
      ref.invalidate(workoutFeedProvider);
      if (mounted) context.pop();
    } catch (err) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$err')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final track = ref.watch(workoutTrackProvider(widget.sessionId));
    final units = Units(ref.watch(unitSystemProvider));
    final list = track.valueOrNull;
    final full = list == null || list.length < 2
        ? null
        : RangeValues(list.first.t, list.last.t);
    final range = _range ?? full;
    final changed = range != null && full != null && range != full;

    return Scaffold(
      appBar: AppBar(
        title: Text(AppL10n.of(context).catHoatDong),
        actions: [
          TextButton(
            onPressed: !changed || _saving ? null : () => _crop(list!, range),
            child: Text(AppL10n.of(context).luu),
          ),
        ],
      ),
      body: PhoneFrame(
        child: asyncBody(
          track,
          onRetry: () => ref.invalidate(workoutTrackProvider(widget.sessionId)),
          emptyWhen: (l) => l.length < 2,
          emptyText: AppL10n.of(context).hoatDongNayKhongCoLo,
          data: (points) {
            final r = range!;
            final all = points.map(trackLatLng).toList();
            final from = trackIndexAt(points, r.start);
            final to = trackIndexAt(points, r.end);
            final kept = all.sublist(from, to + 1);
            final start = trackPositionAt(points, r.start);
            final end = trackPositionAt(points, r.end);

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: RouteCanvas(
                    fit: all,
                    interactive: true,
                    polylines: [mutedPolyline(all), ...routePolylines(kept)],
                    markers: [
                      endpointDot(start.at),
                      endpointDot(end.at, start: false),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: _stat(
                          AppL10n.of(context).batDau,
                          Units.duration(r.start.round()),
                        ),
                      ),
                      Expanded(
                        child: _stat(
                          AppL10n.of(context).quangDuong,
                          units.distance(end.d - start.d),
                        ),
                      ),
                      Expanded(
                        child: _stat(
                          AppL10n.of(context).thoiGian,
                          Units.duration((r.end - r.start).round()),
                        ),
                      ),
                    ],
                  ),
                ),
                RangeSlider(
                  values: r,
                  min: full!.start,
                  max: full.end,
                  activeColor: RetroTokens.accent,
                  onChanged: _saving
                      ? null
                      : (v) {
                          // Keep at least a few seconds between the handles.
                          if (v.end - v.start < 5) return;
                          setState(() => _range = v);
                        },
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 24),
                  child: Text(
                    AppL10n.of(context).keoHaiDauDeBoPhan,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: RetroTokens.inkSoft),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _stat(String label, String value) => Column(
    children: [
      Text(
        value,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
      ),
      Text(
        label,
        style: const TextStyle(fontSize: 12, color: RetroTokens.inkSoft),
      ),
    ],
  );
}
