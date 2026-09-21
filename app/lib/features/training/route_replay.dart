import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/format/units.dart';
import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import 'route_map.dart';
import '../../core/l10n/gen/app_localizations.dart';

/// The detail screen's map with a play button: replays the recording as a dot
/// running the route, the covered part in orange, with a scrub bar underneath.
/// The timed track is only fetched on the first press.
class RouteReplayMap extends ConsumerStatefulWidget {
  const RouteReplayMap({
    super.key,
    required this.sessionId,
    required this.route,
    this.height = 280,
  });

  final String sessionId;

  /// The stored polyline, shown until the timed track has loaded.
  final List<LatLng> route;
  final double height;

  @override
  ConsumerState<RouteReplayMap> createState() => _RouteReplayMapState();
}

class _RouteReplayMapState extends ConsumerState<RouteReplayMap>
    with SingleTickerProviderStateMixin {
  late final _anim = AnimationController(vsync: this);
  List<TrackPoint>? _track;
  bool _loading = false;

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_track == null) {
      setState(() => _loading = true);
      try {
        final track = await ref.read(
          workoutTrackProvider(widget.sessionId).future,
        );
        if (!mounted) return;
        if (track.length < 2) {
          setState(() => _loading = false);
          return;
        }
        final span = track.last.t - track.first.t;
        // Whole recording in 10–40 s, whatever its length.
        _anim.duration = Duration(
          milliseconds: (span / 20 * 1000).clamp(10000, 40000).round(),
        );
        setState(() {
          _track = track;
          _loading = false;
        });
      } catch (err) {
        if (mounted) {
          setState(() => _loading = false);
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('$err')));
        }
        return;
      }
    }
    if (_anim.isAnimating) {
      _anim.stop();
    } else {
      if (_anim.value >= 1) _anim.value = 0;
      await _anim.forward();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final track = _track;
    final units = Units(ref.watch(unitSystemProvider));

    return AnimatedBuilder(
      animation: _anim,
      builder: (context, _) {
        final playing = _anim.isAnimating;
        Widget map;
        String? readout;
        if (track == null) {
          map = RouteMap(points: widget.route, interactive: true);
        } else {
          final t0 = track.first.t;
          final t = t0 + (track.last.t - t0) * _anim.value;
          final here = trackPositionAt(track, t);
          final all = track.map(trackLatLng).toList();
          final done = [...all.sublist(0, trackIndexAt(track, t) + 1), here.at];
          map = RouteCanvas(
            fit: all,
            interactive: true,
            polylines: [mutedPolyline(all), ...routePolylines(done)],
            markers: [endpointDot(all.first), _runner(here.at)],
          );
          readout =
              '${Units.duration((t - t0).round())} · ${units.distance(here.d)}';
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: widget.height,
              child: Stack(
                children: [
                  Positioned.fill(child: map),
                  if (readout != null)
                    Positioned(
                      left: 12,
                      top: 12,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.92),
                          borderRadius: BorderRadius.circular(
                            RetroTokens.radiusPill,
                          ),
                        ),
                        child: Text(
                          readout,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    right: 12,
                    bottom: 24,
                    child: FloatingActionButton.small(
                      heroTag: null,
                      tooltip: playing
                          ? AppL10n.of(context).tamDung
                          : AppL10n.of(context).xemLaiQuaTrinh,
                      backgroundColor: RetroTokens.accent,
                      foregroundColor: Colors.white,
                      onPressed: _loading ? null : _toggle,
                      child: _loading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Icon(playing ? Icons.pause : Icons.play_arrow),
                    ),
                  ),
                ],
              ),
            ),
            if (track != null)
              Slider(
                value: _anim.value,
                activeColor: RetroTokens.accent,
                onChanged: (v) {
                  _anim.stop();
                  _anim.value = v;
                },
              ),
          ],
        );
      },
    );
  }

  Marker _runner(LatLng at) => Marker(
    point: at,
    width: 20,
    height: 20,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: RetroTokens.accent,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 6)],
      ),
    ),
  );
}
