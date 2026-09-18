import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart' hide ActivityType;
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../core/format/units.dart';
import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/storage/uuid.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/retro_widgets.dart';
import 'route_map.dart';

/// Strava-style recorder. Samples are buffered on device and uploaded as ONE
/// file when the session ends — the server derives polyline, splits, time-in-zone
/// and PRs from it, so no per-point rows ever hit the database.
class RecorderScreen extends ConsumerStatefulWidget {
  const RecorderScreen({super.key});

  @override
  ConsumerState<RecorderScreen> createState() => _RecorderScreenState();
}

class _RecorderScreenState extends ConsumerState<RecorderScreen> {
  /// Below this speed the session auto-pauses, so a traffic light does not wreck
  /// the moving time or the pace.
  static const _autoPauseSpeedMs = 0.5;

  final _samples = <Map<String, dynamic>>[];
  StreamSubscription<Position>? _gps;
  Timer? _ticker;

  ActivityType? _activity;
  bool _activitySeeded = false;
  String? _sessionId;
  int? _startedAt;
  int _elapsedSeconds = 0;
  int _movingSeconds = 0;
  double _distanceM = 0;
  double _elevationGainM = 0;
  Position? _last;
  bool _running = false;
  bool _paused = false;
  bool _saving = false;

  /// Route drawn on the live map, and the newest fix (known before the first
  /// route point when location was already granted).
  final _route = <LatLng>[];
  LatLng? _here;

  @override
  void initState() {
    super.initState();
    _locateOnce();
  }

  /// Centres the map before Start, like Strava — but only if permission is
  /// already there; asking happens on Start, not on opening the screen.
  Future<void> _locateOnce() async {
    try {
      final permission = await Geolocator.checkPermission();
      if (permission != LocationPermission.always &&
          permission != LocationPermission.whileInUse) {
        return;
      }
      final position = await Geolocator.getCurrentPosition();
      if (mounted && _here == null) {
        setState(() => _here = LatLng(position.latitude, position.longitude));
      }
    } catch (_) {
      // No fix yet; the map appears with the first GPS sample instead.
    }
  }

  @override
  void dispose() {
    _gps?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  Future<bool> _ensureLocationPermission() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  Future<void> _start() async {
    final activity = _activity;
    if (activity == null) return;

    if (activity.supportsGps && !await _ensureLocationPermission()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cần quyền vị trí để ghi lộ trình')),
        );
      }
      return;
    }

    setState(() {
      _sessionId = uuidV7();
      _startedAt = DateTime.now().millisecondsSinceEpoch;
      _running = true;
      _paused = false;
      _samples.clear();
      _distanceM = 0;
      _elevationGainM = 0;
      _elapsedSeconds = 0;
      _movingSeconds = 0;
      _last = null;
      _route.clear();
    });

    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !_running) return;
      setState(() {
        _elapsedSeconds++;
        if (!_paused) _movingSeconds++;
      });
    });

    if (activity.supportsGps) {
      _gps = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 0,
        ),
      ).listen(_onPosition);
    }
  }

  void _onPosition(Position position) {
    if (!_running) return;

    final speed = position.speed.isFinite ? position.speed : 0.0;
    final movingNow = speed >= _autoPauseSpeedMs;
    final previous = _last;

    if (previous != null && movingNow) {
      _distanceM += Geolocator.distanceBetween(
        previous.latitude,
        previous.longitude,
        position.latitude,
        position.longitude,
      );
      final climb = position.altitude - previous.altitude;
      if (climb > 0) _elevationGainM += climb;
    }

    _samples.add({
      't': position.timestamp.millisecondsSinceEpoch,
      'lat': position.latitude,
      'lng': position.longitude,
      'ele': position.altitude,
      'speed': speed,
    });

    final here = LatLng(position.latitude, position.longitude);
    setState(() {
      _last = position;
      _paused = !movingNow;
      _here = here;
      if (movingNow || _route.isEmpty) _route.add(here);
    });
  }

  Future<void> _finish() async {
    final sessionId = _sessionId;
    final startedAt = _startedAt;
    final activity = _activity;
    if (sessionId == null || startedAt == null || activity == null) return;

    setState(() => _saving = true);
    await _gps?.cancel();
    _ticker?.cancel();

    try {
      final training = ref.read(trainingRepositoryProvider);
      await training.saveSession(
        id: sessionId,
        activityTypeId: activity.id,
        startedAt: startedAt,
        endedAt: DateTime.now().millisecondsSinceEpoch,
        durationSeconds: _elapsedSeconds,
        movingSeconds: _movingSeconds,
        distanceM: _distanceM,
        elevationGainM: _elevationGainM,
      );

      if (_samples.isNotEmpty) {
        final assetId = await ref
            .read(mediaRepositoryProvider)
            .upload(
              _encodeStream(),
              kind: 'workout_stream',
              mimeType: 'application/x-ndjson',
            );
        final records = await training.uploadStream(sessionId, assetId);
        if (records.isNotEmpty && mounted) {
          await showDialog<void>(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('Kỷ lục mới!'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final pr in records)
                    Text(
                      '${pr.metric} · ${pr.value.toStringAsFixed(0)} ${pr.unit}',
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Tuyệt'),
                ),
              ],
            ),
          );
        }
      }

      ref.invalidate(workoutFeedProvider);
      ref.invalidate(personalRecordsProvider);
      if (mounted) context.pushReplacement('/workouts/$sessionId');
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$err')));
        setState(() => _saving = false);
      }
    }
  }

  /// NDJSON: one sample per line. Even a three-hour session at 1 Hz is only a
  /// few MB, so building it in memory keeps the upload path identical on every
  /// platform instead of needing a writable temp directory.
  Uint8List _encodeStream() =>
      utf8.encode(_samples.map(jsonEncode).join(String.fromCharCode(10)));

  @override
  Widget build(BuildContext context) {
    final activities = ref.watch(activityTypesProvider);
    final feed = ref.watch(workoutFeedProvider);
    final units = Units(ref.watch(unitSystemProvider));

    // Seed the dropdown exactly once, after both the catalog and the workout
    // history resolve: the activity of the most recent session, or nothing at
    // all on a fresh account. Mutating without setState is safe because the
    // value is only consumed later in this same build.
    if (_activity == null && !_activitySeeded) {
      final list = activities.valueOrNull;
      if (list != null && !feed.isLoading) {
        _activitySeeded = true;
        final latest = feed.valueOrNull?.firstOrNull;
        if (latest != null) {
          _activity = list
              .where((a) => a.id == latest.activityTypeId)
              .firstOrNull;
        }
      }
    }

    final showMap = _activity?.supportsGps ?? false;

    return Scaffold(
      appBar: AppBar(title: Text(_running ? 'Đang ghi' : 'Buổi tập mới')),
      body: SafeArea(
        child: PhoneFrame(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!_running)
                  activities.when(
                    loading: () => const LinearProgressIndicator(),
                    error: (err, _) => Text('$err'),
                    data: (list) => feed.isLoading
                        ? const LinearProgressIndicator()
                        : DropdownButtonFormField<ActivityType>(
                            // Held back until the feed resolves (above), so the
                            // seed is already applied when the field is created
                            // and initialValue is honored.
                            initialValue: _activity,
                            hint: const Text('Chọn môn'),
                            decoration: const InputDecoration(labelText: 'Môn'),
                            items: [
                              for (final a in list)
                                DropdownMenuItem(value: a, child: Text(a.name)),
                            ],
                            onChanged: (value) =>
                                setState(() => _activity = value),
                          ),
                  ),
                if (showMap) ...[
                  const SizedBox(height: 12),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(RetroTokens.radiusLg),
                      child: _here == null
                          ? Container(
                              color: RetroTokens.paperSunk,
                              alignment: Alignment.center,
                              child: Text(
                                _running
                                    ? 'Đang tìm tín hiệu GPS…'
                                    : 'Bản đồ hiện khi bắt đầu ghi',
                                style: const TextStyle(
                                  color: RetroTokens.inkSoft,
                                ),
                              ),
                            )
                          : LiveRouteMap(points: _route, center: _here!),
                    ),
                  ),
                  const SizedBox(height: 16),
                ] else
                  const Spacer(),
                Center(
                  child: Column(
                    children: [
                      Text(
                        Units.duration(_elapsedSeconds),
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontSize: showMap ? 44 : 56,
                        ),
                      ),
                      Text(
                        _paused ? 'tạm dừng tự động' : 'thời gian',
                        style: TextStyle(
                          color: _paused
                              ? RetroTokens.warn
                              : RetroTokens.inkSoft,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: _metric(
                        context,
                        units.distance(_distanceM),
                        'quãng đường',
                      ),
                    ),
                    Expanded(
                      child: _metric(
                        context,
                        units.pace(
                          _distanceM > 0
                              ? _movingSeconds / (_distanceM / 1000)
                              : null,
                        ),
                        'pace',
                      ),
                    ),
                    Expanded(
                      child: _metric(
                        context,
                        '${_elevationGainM.round()} m',
                        'độ cao',
                      ),
                    ),
                  ],
                ),
                if (showMap) const SizedBox(height: 16) else const Spacer(),
                if (!_running)
                  FilledButton(
                    onPressed: _activity == null ? null : _start,
                    child: const Text('Bắt đầu'),
                  )
                else
                  FilledButton(
                    onPressed: _saving ? null : _finish,
                    child: _saving
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Kết thúc và lưu'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _metric(BuildContext context, String value, String label) => Column(
    children: [
      Text(
        value,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 22),
      ),
      Text(
        label,
        style: const TextStyle(fontSize: 12, color: RetroTokens.inkSoft),
      ),
    ],
  );
}
