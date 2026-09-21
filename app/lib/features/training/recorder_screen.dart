import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart' hide ActivityType;
import 'package:geolocator/geolocator.dart' as geo show ActivityType;
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../core/format/units.dart';
import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/storage/uuid.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/retro_widgets.dart';
import 'activity_format.dart';
import 'route_map.dart';
import 'workout_form.dart';
import '../../core/l10n/gen/app_localizations.dart';

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

  /// Moving time summed from the gaps between GPS fixes while moving, so it
  /// stays right when the app sleeps between them.
  int _movingMs = 0;
  double _distanceM = 0;
  double _elevationGainM = 0;
  Position? _last;
  bool _running = false;
  bool _paused = false;
  bool _saving = false;

  /// Paused by the athlete (the button), as opposed to [_paused] (auto-pause).
  /// The clock stops and nothing is recorded until "Tiếp tục".
  bool _stopped = false;

  /// The clock runs on wall time, not on ticks: with the screen off the OS
  /// throttles or freezes timers, and a tick counter would lose that time.
  /// [_activeMs] holds finished segments, [_segmentStart] the running one.
  int _activeMs = 0;
  int? _segmentStart;

  /// Seconds on the clock: wall time minus manual pauses.
  int get _activeSeconds {
    final running = _segmentStart == null
        ? 0
        : DateTime.now().millisecondsSinceEpoch - _segmentStart!;
    return (_activeMs + running) ~/ 1000;
  }

  /// Without GPS there is no way to tell standing from moving.
  int get _movingSeconds =>
      (_activity?.supportsGps ?? false) ? _movingMs ~/ 1000 : _activeSeconds;

  void _closeSegment() {
    final start = _segmentStart;
    if (start == null) return;
    _activeMs += DateTime.now().millisecondsSinceEpoch - start;
    _segmentStart = null;
  }

  /// After "Hoàn thành": the save form, Strava's review step.
  bool _reviewing = false;
  int? _endedAt;
  WorkoutDraft? _draft;

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
          SnackBar(content: Text(AppL10n.of(context).canQuyenViTriDeGhi)),
        );
      }
      return;
    }

    setState(() {
      _sessionId = uuidV7();
      _startedAt = DateTime.now().millisecondsSinceEpoch;
      _running = true;
      _paused = false;
      _stopped = false;
      _activeMs = 0;
      _segmentStart = _startedAt;
      _samples.clear();
      _distanceM = 0;
      _elevationGainM = 0;
      _movingMs = 0;
      _last = null;
      _route.clear();
    });

    _startSensors(activity);
  }

  void _startSensors(ActivityType activity) {
    // Only repaints the clock; the time itself comes from the wall clock.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _running && !_stopped) setState(() {});
    });

    if (activity.supportsGps) {
      _gps = Geolocator.getPositionStream(
        locationSettings: _backgroundLocationSettings(context),
      ).listen(_onPosition);
    }
  }

  /// Keeps GPS flowing with the screen off or the app in the background:
  /// a foreground service (with its ongoing notification) on Android, and
  /// background location updates on iOS (UIBackgroundModes: location).
  /// A browser tab cannot do either; the wall clock still keeps time there.
  static LocationSettings _backgroundLocationSettings(BuildContext context) {
    if (kIsWeb) {
      return const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 0,
      );
    }
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 1),
        foregroundNotificationConfig: ForegroundNotificationConfig(
          notificationTitle: AppL10n.of(context).dangGhiBuoiTap,
          notificationText: AppL10n.of(context).chiphealthVanGhiLoTrinhKhi,
          enableWakeLock: true,
          setOngoing: true,
        ),
      ),
      TargetPlatform.iOS || TargetPlatform.macOS => AppleSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 0,
        activityType: geo.ActivityType.fitness,
        pauseLocationUpdatesAutomatically: false,
        allowBackgroundLocationUpdates: true,
        showBackgroundLocationIndicator: true,
      ),
      _ => const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 0,
      ),
    };
  }

  void _onPosition(Position position) {
    if (!_running) return;
    final here = LatLng(position.latitude, position.longitude);

    // Paused: keep the dot on the map moving but record nothing. Tracking the
    // fix in _last means the resume does not credit the distance covered
    // while stopped.
    if (_stopped) {
      setState(() {
        _last = position;
        _here = here;
      });
      return;
    }

    final speed = position.speed.isFinite ? position.speed : 0.0;
    final movingNow = speed >= _autoPauseSpeedMs;
    final previous = _last;

    if (previous != null && movingNow) {
      final gap = position.timestamp.difference(previous.timestamp);
      if (!gap.isNegative) _movingMs += gap.inMilliseconds;
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

    setState(() {
      _last = position;
      _paused = !movingNow;
      _here = here;
      if (movingNow || _route.isEmpty) _route.add(here);
    });
  }

  void _pause() => setState(() {
    _closeSegment();
    _stopped = true;
  });

  /// "Ghi tiếp" from the review: back to the paused recorder, sensors on.
  void _resumeAfterReview() {
    final activity = _activity;
    if (activity == null) return;
    _running = true;
    _stopped = true;
    _endedAt = null;
    _startSensors(activity);
  }

  void _resume() => setState(() {
    _segmentStart = DateTime.now().millisecondsSinceEpoch;
    _stopped = false;
  });

  /// "Hoàn thành": stop sensors and show the review form. Nothing is sent
  /// until "Lưu hoạt động", so the athlete can still discard.
  Future<void> _complete() async {
    await _gps?.cancel();
    _gps = null;
    _ticker?.cancel();
    if (!mounted) return;
    setState(() {
      _closeSegment();
      _running = false;
      _reviewing = true;
      _endedAt = DateTime.now().millisecondsSinceEpoch;
      _draft = WorkoutDraft(
        activity: _activity,
        title: defaultTitleFor(context, _startedAt!, _activity),
        notes: '',
      );
    });
  }

  Future<bool> _confirmDiscard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(AppL10n.of(context).huyBaiTap),
        content: Text(AppL10n.of(context).toanBoDuLieuVuaGhi),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(AppL10n.of(context).giuLai),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: RetroTokens.accent),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(AppL10n.of(context).huyBai),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _discard() async {
    if (!await _confirmDiscard()) return;
    await _gps?.cancel();
    _ticker?.cancel();
    if (!mounted) return;
    setState(() {
      // Lets the PopScope below through.
      _running = false;
      _reviewing = false;
    });
    context.pop();
  }

  Future<void> _save() async {
    final sessionId = _sessionId;
    final startedAt = _startedAt;
    final draft = _draft;
    final activity = draft?.activity ?? _activity;
    if (sessionId == null || startedAt == null || activity == null) return;

    setState(() => _saving = true);

    try {
      final training = ref.read(trainingRepositoryProvider);
      await training.saveSession(
        id: sessionId,
        activityTypeId: activity.id,
        startedAt: startedAt,
        endedAt: _endedAt ?? DateTime.now().millisecondsSinceEpoch,
        durationSeconds: _activeSeconds,
        movingSeconds: _movingSeconds,
        distanceM: _distanceM,
        elevationGainM: _elevationGainM,
        title: (draft?.title.isEmpty ?? true) ? null : draft!.title,
        notes: (draft?.notes.isEmpty ?? true) ? null : draft!.notes,
        perceivedExertion: draft?.perceivedExertion,
        photoAssetIds: draft?.photoAssetIds ?? const [],
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
              title: Text(AppL10n.of(context).kyLucMoi),
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
                  child: Text(AppL10n.of(context).tuyet),
                ),
              ],
            ),
          );
        }
      }

      ref.invalidate(workoutFeedProvider);
      ref.invalidate(personalRecordsProvider);
      if (mounted) {
        setState(() => _reviewing = false);
        context.pushReplacement('/workouts/$sessionId');
      }
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

    // Mid-recording or mid-review, back must not silently throw the session
    // away: it asks, like the "Huỷ bài" button.
    return PopScope(
      canPop: !_running && !_reviewing,
      // A blocked back does nothing at all. Once the session is running,
      // leaving it is a decision made with the "×" on screen, not something
      // a back gesture can do by accident mid-run.
      onPopInvokedWithResult: (didPop, _) {},
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _reviewing
                ? AppL10n.of(context).luuHoatDong
                : _stopped
                ? AppL10n.of(context).daTamDung
                : _running
                ? AppL10n.of(context).dangGhi
                : AppL10n.of(context).buoiTapMoi,
          ),
        ),
        body: SafeArea(
          child: PhoneFrame(
            child: _reviewing
                ? _review(activities.valueOrNull ?? const [], units)
                : _recorder(context, activities, feed, units, showMap),
          ),
        ),
      ),
    );
  }

  Widget _recorder(
    BuildContext context,
    AsyncValue<List<ActivityType>> activities,
    AsyncValue<List<WorkoutSession>> feed,
    Units units,
    bool showMap,
  ) {
    final started = _running;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!started)
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
                      hint: Text(AppL10n.of(context).chonMon),
                      decoration: InputDecoration(
                        labelText: AppL10n.of(context).mon,
                      ),
                      items: [
                        for (final a in list)
                          DropdownMenuItem(
                            value: a,
                            child: Row(
                              children: [
                                Icon(activityIcon(a.code), size: 18),
                                const SizedBox(width: 8),
                                Text(a.name),
                              ],
                            ),
                          ),
                      ],
                      onChanged: (value) => setState(() => _activity = value),
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
                          started
                              ? AppL10n.of(context).dangTimTinHieuGps
                              : AppL10n.of(context).banDoHienKhiBatDau,
                          style: const TextStyle(color: RetroTokens.inkSoft),
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
                  Units.duration(_activeSeconds),
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontSize: showMap ? 44 : 56,
                    color: _stopped ? RetroTokens.inkFaint : null,
                  ),
                ),
                Text(
                  _stopped
                      ? AppL10n.of(context).daTamDung2
                      : _paused
                      ? AppL10n.of(context).tamDungTuDong
                      : AppL10n.of(context).thoiGian2,
                  style: TextStyle(
                    color: _stopped || _paused
                        ? RetroTokens.warn
                        : RetroTokens.inkSoft,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _metricsRow(context, units),
          if (showMap) const SizedBox(height: 16) else const Spacer(),
          if (!started)
            FilledButton(
              onPressed: _activity == null ? null : _start,
              child: Text(AppL10n.of(context).batDau),
            )
          else if (!_stopped)
            FilledButton.icon(
              onPressed: _pause,
              style: FilledButton.styleFrom(
                backgroundColor: RetroTokens.ink,
                minimumSize: const Size.fromHeight(52),
              ),
              icon: const Icon(Icons.pause),
              label: Text(AppL10n.of(context).tamDung),
            )
          else
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _resume,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                    icon: const Icon(Icons.play_arrow),
                    label: Text(AppL10n.of(context).tiepTuc),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _complete,
                    style: FilledButton.styleFrom(
                      backgroundColor: RetroTokens.accent,
                      minimumSize: const Size.fromHeight(52),
                    ),
                    icon: const Icon(Icons.flag),
                    label: Text(AppL10n.of(context).hoanThanh),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _metricsRow(BuildContext context, Units units) => Row(
    children: [
      Expanded(
        child: _metric(
          context,
          units.distance(_distanceM),
          AppL10n.of(context).quangDuong2,
        ),
      ),
      Expanded(
        child: _metric(
          context,
          units.pace(
            _distanceM > 0 ? _movingSeconds / (_distanceM / 1000) : null,
          ),
          'pace',
        ),
      ),
      Expanded(
        child: _metric(
          context,
          '${_elevationGainM.round()} m',
          AppL10n.of(context).doCao,
        ),
      ),
    ],
  );

  /// Strava's save screen: the route, the numbers, then title / sport / notes,
  /// with "Huỷ bài" to throw the recording away instead.
  Widget _review(List<ActivityType> activities, Units units) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_route.length > 1)
          ClipRRect(
            borderRadius: BorderRadius.circular(RetroTokens.radiusLg),
            child: SizedBox(height: 200, child: RouteMap(points: _route)),
          ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _metric(
                context,
                Units.duration(_activeSeconds),
                AppL10n.of(context).thoiGian2,
              ),
            ),
            Expanded(
              child: _metric(
                context,
                units.distance(_distanceM),
                AppL10n.of(context).quangDuong2,
              ),
            ),
            Expanded(
              child: _metric(
                context,
                units.pace(
                  _distanceM > 0 ? _movingSeconds / (_distanceM / 1000) : null,
                ),
                'pace',
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        WorkoutFormFields(
          activities: activities,
          startedAt: _startedAt!,
          initial: _draft!,
          onChanged: (d) => _draft = d,
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _saving ? null : _save,
          style: FilledButton.styleFrom(
            backgroundColor: RetroTokens.accent,
            minimumSize: const Size.fromHeight(52),
          ),
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Text(AppL10n.of(context).luuHoatDong),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextButton.icon(
                onPressed: _saving
                    ? null
                    : () => setState(() {
                        // Back to the paused recorder; sensors restart.
                        _reviewing = false;
                        _resumeAfterReview();
                      }),
                icon: const Icon(Icons.arrow_back),
                label: Text(AppL10n.of(context).ghiTiep),
              ),
            ),
            Expanded(
              child: TextButton.icon(
                onPressed: _saving ? null : _discard,
                style: TextButton.styleFrom(
                  foregroundColor: RetroTokens.accent,
                ),
                icon: const Icon(Icons.delete_outline),
                label: Text(AppL10n.of(context).huyBai),
              ),
            ),
          ],
        ),
      ],
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
