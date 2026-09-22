import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/format/units.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/retro_widgets.dart';
import '../home/home_widgets.dart';
import 'route_map.dart';
import 'run_charts.dart';
import 'workout_detail_screen.dart';
import 'workout_photos.dart';

/// `/workouts/:id` picks its layout from what the session is.
///
/// A recorded run or ride has a route, splits, efforts and zones, and gets the
/// map-and-sheet screen below. A gym session has sets and a duration, and keeps
/// the plain list layout it always had. Both read the same fetch, so choosing
/// costs nothing.
class WorkoutRoute extends ConsumerWidget {
  const WorkoutRoute({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(runDetailProvider(sessionId));
    final types = ref.watch(activityTypesProvider).valueOrNull;
    final run = detail.valueOrNull;

    if (run == null || types == null) {
      // Not a decision yet: the old screen renders the loading and error states
      // for its own fetch, which is the same one.
      return WorkoutDetailScreen(sessionId: sessionId);
    }
    final type = types
        .where((t) => t.id == run.session.activityTypeId)
        .firstOrNull;
    final hasRoute = (run.session.polyline ?? '').isNotEmpty;
    return type?.supportsGps == true && hasRoute
        ? RunDetailScreen(sessionId: sessionId)
        : WorkoutDetailScreen(sessionId: sessionId);
  }
}

/// The detail screen for a recorded outdoor session: the route fills the
/// screen, and everything measured about the run lives in a sheet dragged up
/// over it.
class RunDetailScreen extends ConsumerStatefulWidget {
  const RunDetailScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<RunDetailScreen> createState() => _RunDetailScreenState();
}

/// Where the sheet rests, and how far it can be pulled.
const _sheetRest = 0.52;
const _sheetFull = 1.0;

class _RunDetailScreenState extends ConsumerState<RunDetailScreen>
    with SingleTickerProviderStateMixin {
  final _sheet = DraggableScrollableController();
  final _map = MapController();
  late final _replay = AnimationController(vsync: this);

  double _extent = _sheetRest;
  bool _mapReady = false;
  double _fittedFor = -1;

  /// Distance under a finger on one of the charts; the map marks the spot.
  double? _cursorD;

  /// The split under a finger on the bar chart; the map lights up its stretch.
  SplitBar? _cursorSplit;

  /// Set while a bookmark request is in flight, so the icon flips at once.
  bool? _pendingBookmark;

  final _paceKey = GlobalKey();
  final _scrollKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _sheet.addListener(_onSheet);
  }

  @override
  void dispose() {
    _sheet.removeListener(_onSheet);
    _sheet.dispose();
    _replay.dispose();
    super.dispose();
  }

  void _onSheet() {
    if (!_sheet.isAttached) return;
    final next = _sheet.size;
    if ((next - _extent).abs() < 0.01) return;
    setState(() => _extent = next);
  }

  /// Frames the whole route in the strip of map the sheet leaves visible.
  void _fitRoute(List<LatLng> route, Size screen) {
    if (!_mapReady || route.length < 2) return;
    final hidden = screen.height * _extent;
    if ((hidden - _fittedFor).abs() < 24) return;
    _fittedFor = hidden;
    _map.fitCamera(
      CameraFit.coordinates(
        coordinates: route,
        padding: EdgeInsets.fromLTRB(36, 96, 36, hidden + 36),
        maxZoom: 17,
      ),
    );
  }

  Future<void> _toggleBookmark(bool current) async {
    setState(() => _pendingBookmark = !current);
    try {
      await ref
          .read(trainingRepositoryProvider)
          .setBookmark(widget.sessionId, !current);
      ref.invalidate(workoutDetailProvider(widget.sessionId));
    } catch (err) {
      if (!mounted) return;
      setState(() => _pendingBookmark = null);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$err')));
    }
  }

  void _soon() => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(AppL10n.of(context).tinhNangSapCo)));

  /// The pace section, reached from "xem chi tiết về nhịp độ". The sheet has to
  /// be open before the target has a position worth scrolling to.
  Future<void> _jumpToPace() async {
    if (_extent < _sheetFull - 0.01) {
      await _sheet.animateTo(
        _sheetFull,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
    // The section's own context, not the screen's: the sheet may have rebuilt
    // while the animation ran and the target may no longer be on screen.
    final target = _paceKey.currentContext;
    if (target == null || !target.mounted) return;
    await Scrollable.ensureVisible(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(runDetailProvider(widget.sessionId));
    final track = ref.watch(runTrackProvider(widget.sessionId)).valueOrNull;
    final screen = MediaQuery.sizeOf(context);

    return Scaffold(
      body: asyncBody(
        detail,
        onRetry: () => ref.invalidate(workoutDetailProvider(widget.sessionId)),
        data: (RunDetail run) {
          final route = decodePolyline(run.session.polyline);
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _fitRoute(route, screen),
          );
          final bookmarked = _pendingBookmark ?? run.session.isBookmarked;

          return Stack(
            children: [
              Positioned.fill(
                child: _RunMap(
                  controller: _map,
                  route: route,
                  track: track,
                  efforts: run.bestEfforts,
                  cursorD: _cursorD,
                  cursorSplit: _cursorSplit,
                  replay: _replay,
                  onReady: () => _mapReady = true,
                ),
              ),
              // The play button rides the top edge of the sheet.
              Positioned(
                right: 12,
                bottom: screen.height * _extent + 12,
                child: _PlayButton(
                  controller: _replay,
                  enabled: track != null && track.length > 1,
                ),
              ),
              DraggableScrollableSheet(
                controller: _sheet,
                initialChildSize: _sheetRest,
                minChildSize: _sheetRest,
                maxChildSize: _sheetFull,
                // No explicit snap sizes: with only two stops, min and max are
                // exactly what `snap` already settles between.
                snap: true,
                builder: (context, scrollController) => _Sheet(
                  key: _scrollKey,
                  controller: scrollController,
                  children: _sections(context, run, track),
                ),
              ),
              _Header(
                expanded: _extent > (_sheetRest + _sheetFull) / 2,
                title: _sportName(run),
                bookmarked: bookmarked,
                onBack: () {
                  // Pulled up over the map, the back button puts the sheet
                  // down first — the same gesture the chevron suggests.
                  if (_extent > _sheetRest + 0.02) {
                    _sheet.animateTo(
                      _sheetRest,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                    );
                  } else if (context.canPop()) {
                    context.pop();
                  } else {
                    context.go('/training');
                  }
                },
                onBookmark: () => _toggleBookmark(bookmarked),
                onMenu: () => _menu(context, run),
              ),
            ],
          );
        },
      ),
    );
  }

  String _sportName(RunDetail run) {
    final types = ref.read(activityTypesProvider).valueOrNull ?? const [];
    return types
            .where((t) => t.id == run.session.activityTypeId)
            .firstOrNull
            ?.name ??
        AppL10n.of(context).buoiTap;
  }

  Future<void> _menu(BuildContext context, RunDetail run) async {
    final l = AppL10n.of(context);
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(l.chinhSuaHoatDong),
              onTap: () => Navigator.of(sheet).pop('edit'),
            ),
            ListTile(
              leading: const Icon(Icons.content_cut),
              title: Text(l.catHoatDong),
              onTap: () => Navigator.of(sheet).pop('crop'),
            ),
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: Text(l.chiaSe),
              onTap: () => Navigator.of(sheet).pop('share'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted || action == null) return;
    switch (action) {
      case 'edit':
        await context.push<void>('/workouts/${widget.sessionId}/edit');
      case 'crop':
        await context.push<void>('/workouts/${widget.sessionId}/crop');
      default:
        _soon();
    }
  }

  List<Widget> _sections(
    BuildContext context,
    RunDetail run,
    List<TrackPoint>? track,
  ) {
    final units = Units(ref.watch(unitSystemProvider));
    final language = Localizations.localeOf(context).languageCode;
    final user = ref.watch(authControllerProvider).user;
    final session = run.session;
    final elevation = _elevationSeries(track);
    final pace = _paceSeries(track);

    return [
      _Identity(session: session, user: user, run: run),
      if (run.headlineEffort != null)
        _PrBanner(effort: run.headlineEffort!, units: units),
      _StatGrid(run: run, units: units, language: language),
      _InsightCard(
        sessionId: widget.sessionId,
        kind: 'overview',
        showButton: true,
        onAsk: _soon,
      ),
      _SourceRow(source: session.source),
      if (session.photoAssetIds.isNotEmpty) _Photos(ids: session.photoAssetIds),
      if (run.predictionImproved.isNotEmpty)
        _PredictionCard(
          prediction: run.predictionImproved.first,
          onTrend: _soon,
        ),
      if (run.bestEfforts.isNotEmpty)
        _Results(run: run, units: units, onAll: _soon),
      if (run.splits.isNotEmpty && session.avgPaceSecPerKm != null)
        _PaceAnalysis(
          run: run,
          units: units,
          elevation: elevation,
          pace: pace,
          onCursor: (bar) => setState(() => _cursorSplit = bar),
          onDetail: _jumpToPace,
        ),
      if (run.splits.isNotEmpty) _SplitTable(run: run, units: units),
      _PaceSection(
        key: _paceKey,
        sessionId: widget.sessionId,
        run: run,
        units: units,
        track: track,
        elevation: elevation,
        onCursor: (d) => setState(() => _cursorD = d),
      ),
      if (track != null && track.any((p) => p.gap != null))
        _GapSection(
          run: run,
          units: units,
          track: track,
          elevation: elevation,
          onCursor: (d) => setState(() => _cursorD = d),
        ),
      if (run.paceZones.isNotEmpty)
        _PaceZones(
          sessionId: widget.sessionId,
          run: run,
          units: units,
          onAll: _soon,
        ),
      if (run.zones.isEmpty)
        _NoHeartRate(onHelp: _soon)
      else
        _HeartRateZones(zones: run.zones),
      if (elevation.length > 1)
        _ElevationSection(
          run: run,
          elevation: elevation,
          onCursor: (d) => setState(() => _cursorD = d),
        ),
      const SizedBox(height: 48),
    ];
  }
}

/// The elevation profile as a chart series, or empty when nothing recorded it.
List<ChartPoint> _elevationSeries(List<TrackPoint>? track) => track == null
    ? const []
    : [
        for (final p in track)
          if (p.ele != null) ChartPoint(p.d, p.ele!),
      ];

/// Instantaneous pace from the track, as a chart series.
List<ChartPoint> _paceSeries(List<TrackPoint>? track) => track == null
    ? const []
    : [
        for (final p in track)
          if (p.pace != null) ChartPoint(p.d, p.pace!),
      ];

/// Grade adjusted pace from the track, as a chart series.
List<ChartPoint> _gapSeries(List<TrackPoint>? track) => track == null
    ? const []
    : [
        for (final p in track)
          if (p.gap != null) ChartPoint(p.d, p.gap!),
      ];

/// How far either side of a point the smoothing average reaches.
///
/// Instantaneous pace between two GPS fixes a few seconds apart is mostly
/// noise, and a chart of it is a hedge rather than a line. Averaging over a
/// couple of hundred metres leaves the shape of the run — the climb, the fade,
/// the surge at the end — and drops everything shorter than a stride pattern.
/// The unsmoothed series is still drawn behind it, so nothing is hidden, only
/// ranked.
const _paceSmoothWindowM = 150.0;

/// A distance-windowed moving average. Both ends taper rather than run off, so
/// the line starts and finishes on the data instead of drifting to the middle.
List<ChartPoint> smoothSeries(
  List<ChartPoint> points, {
  double windowM = _paceSmoothWindowM,
}) {
  if (points.length < 3) return points;
  final out = <ChartPoint>[];
  var lo = 0;
  var hi = 0;
  var sum = 0.0;
  var count = 0;
  for (var i = 0; i < points.length; i++) {
    final d = points[i].d;
    while (hi < points.length && points[hi].d <= d + windowM / 2) {
      sum += points[hi].v;
      count++;
      hi++;
    }
    while (lo < hi && points[lo].d < d - windowM / 2) {
      sum -= points[lo].v;
      count--;
      lo++;
    }
    out.add(ChartPoint(d, count > 0 ? sum / count : points[i].v));
  }
  return out;
}

/// A fixed, generous band for a pace axis, in seconds per kilometre.
///
/// The split chart fits its axis tightly to the splits, because comparing one
/// kilometre with the next is the whole point of it. A continuous pace chart
/// cannot: it contains every second of the run, including the ones spent
/// standing at a crossing, where pace runs away to infinity. An axis stretched
/// to reach those is an axis on which the running is a flat line.
///
/// So the band is pinned wide and the outliers are clipped to its edges — a
/// stop becomes a stretch pressed against the bottom, which reads as what it
/// was. The bounds come from the run rather than from constants so that a
/// four-minute runner and a nine-minute runner both get a readable chart, but
/// they are deliberately loose: whole minutes, a wide percentile, and a floor
/// under how narrow the band may become.
({double lo, double hi}) paceBand(
  List<ChartPoint> series, {
  double lowPercentile = 0.05,
  double highPercentile = 0.85,
  double minSpan = 180,
}) {
  const fallback = (lo: 360.0, hi: 660.0);
  if (series.length < 2) return fallback;
  final values = series.map((p) => p.v).toList()..sort();
  final last = values.length - 1;
  final low = values[(last * lowPercentile).round()];
  final high = values[(last * highPercentile).round()];
  var lo = (low / 60).floorToDouble() * 60;
  var hi = (high / 60).ceilToDouble() * 60;
  if (hi - lo < minSpan) hi = lo + minSpan;
  return (lo: lo, hi: hi);
}

/// The fastest continuous kilometre of the run, in seconds.
///
/// Not the fastest row of the split table. A split is pinned to the whole
/// kilometre marks, so a runner who started their surge 300 m into the third
/// kilometre has their best kilometre cut in half by a boundary that means
/// nothing to them. The backend already scores every standard distance with a
/// rolling window over the raw stream; this reads the 1 km one off it.
double? fastestKilometreSeconds(RunDetail run) {
  for (final effort in run.bestEfforts) {
    if (effort.distanceM == 1000) return effort.elapsedSeconds;
  }
  return null;
}

/* ------------------------------------------------------------------ */
/* Map, header, sheet chrome                                           */
/* ------------------------------------------------------------------ */

/// The route under everything, with the medals it earned, the marker that
/// follows a finger on the charts, and the replay dot.
class _RunMap extends StatelessWidget {
  const _RunMap({
    required this.controller,
    required this.route,
    required this.track,
    required this.efforts,
    required this.cursorD,
    required this.cursorSplit,
    required this.replay,
    required this.onReady,
  });

  final MapController controller;
  final List<LatLng> route;
  final List<TrackPoint>? track;
  final List<RunEffort> efforts;
  final double? cursorD;
  final SplitBar? cursorSplit;
  final AnimationController replay;
  final VoidCallback onReady;

  /// At most two medals, best rank first: a run can set half a dozen efforts
  /// and the map is not a trophy cabinet.
  List<RunEffort> get _medals {
    final worth = efforts.where((e) => e.rank <= 3).toList()
      ..sort((a, b) {
        final byRank = a.rank.compareTo(b.rank);
        return byRank != 0 ? byRank : b.distanceM.compareTo(a.distanceM);
      });
    return worth.take(2).toList();
  }

  @override
  Widget build(BuildContext context) {
    final points = track;

    return AnimatedBuilder(
      animation: replay,
      builder: (context, _) {
        final polylines = <Polyline>[...routePolylines(route)];
        final markers = <Marker>[
          if (route.isNotEmpty) endpointDot(route.first),
        ];

        if (points != null && points.length > 1) {
          // The stretch of road a touched split covers, drawn over the route.
          if (cursorSplit != null) {
            // Splits are whole kilometres in order, so the nth one starts at
            // (n-1) km and runs for however far it went — which is less than a
            // kilometre for the remainder at the end.
            final from = (cursorSplit!.index - 1) * 1000.0;
            polylines.add(
              Polyline(
                points: trackSlice(points, from, from + cursorSplit!.distanceM),
                color: RetroTokens.ink,
                strokeWidth: 6,
              ),
            );
          }
          if (cursorD != null) {
            markers.add(
              _cursorMarker(trackPositionAtDistance(points, cursorD!)),
            );
          }
          if (replay.isAnimating || replay.value > 0) {
            final t =
                points.first.t +
                (points.last.t - points.first.t) * replay.value;
            markers.add(_runnerMarker(trackPositionAt(points, t).at));
          }
          markers.add(_headingArrow(points));
          for (final medal in _medals) {
            markers.add(
              _medalMarker(
                context,
                trackPositionAtDistance(points, medal.endDistanceM),
                medal,
              ),
            );
          }
        }

        return FlutterMap(
          mapController: controller,
          options: MapOptions(
            initialCenter: route.isEmpty ? const LatLng(0, 0) : route.first,
            initialZoom: 14,
            onMapReady: onReady,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
          ),
          children: [
            routeTileLayer(context),
            PolylineLayer(polylines: polylines),
            MarkerLayer(markers: markers),
          ],
        );
      },
    );
  }

  /// Which way round the loop the athlete went. Without it a route that
  /// doubles back on itself gives no clue which end was the start.
  Marker _headingArrow(List<TrackPoint> points) {
    // A third of the way in: far enough from the start dot to be its own mark,
    // and on a stretch rather than in a corner.
    final i = (points.length * 0.33).round().clamp(1, points.length - 1);
    final a = points[i - 1];
    final b = points[i];
    final bearing = math.atan2(b.lng - a.lng, b.lat - a.lat);
    return Marker(
      point: LatLng(b.lat, b.lng),
      width: 22,
      height: 22,
      child: Transform.rotate(
        angle: bearing,
        child: const Icon(
          Icons.navigation,
          size: 18,
          color: RetroTokens.ink,
          shadows: [Shadow(color: Colors.white, blurRadius: 3)],
        ),
      ),
    );
  }

  Marker _cursorMarker(LatLng at) => Marker(
    point: at,
    width: 18,
    height: 18,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: RetroTokens.ink,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
      ),
    ),
  );

  Marker _runnerMarker(LatLng at) => Marker(
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

  Marker _medalMarker(BuildContext context, LatLng at, RunEffort effort) {
    final l = AppL10n.of(context);
    return Marker(
      point: at,
      width: 168,
      height: 40,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Medal(rank: effort.rank, size: 26),
          const SizedBox(width: 6),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(RetroTokens.radius),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    effortTitle(context, effort),
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    l.tuTruocDenNay,
                    style: const TextStyle(
                      fontSize: 9,
                      color: RetroTokens.inkSoft,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "10 km nhanh nhất" / "Thành tích 2 dặm thứ 2" — how an effort is named
/// wherever it is shown.
String effortTitle(BuildContext context, RunEffort effort) {
  final l = AppL10n.of(context);
  final distance = effortDistanceLabel(context, effort.distanceM);
  return effort.rank == 1
      ? l.cuLyNhanhNhat(distance)
      : l.thanhTichCuLyThu(distance, '${effort.rank}');
}

/// Standard distances are named the way runners say them, not converted: a
/// 1609 m effort is "1 dặm", not "1,61 km".
String effortDistanceLabel(BuildContext context, double metres) {
  final l = AppL10n.of(context);
  final m = metres.round();
  return switch (m) {
    805 => l.nuaDam,
    1609 => l.motDam,
    3219 => l.haiDam,
    21097 => l.banMarathon,
    42195 => l.marathon,
    _ when m < 1000 => '$m m',
    _ => '${(m / 1000).round()} km',
  };
}

/// A place on the all-time board: gold for first, silver for second, bronze
/// for third, and the plain number for anything further down.
class Medal extends StatelessWidget {
  const Medal({super.key, required this.rank, this.size = 32});

  final int rank;
  final double size;

  static const _gold = Color(0xFFD9A441);
  static const _silver = Color(0xFFB9B4AA);
  static const _bronze = Color(0xFFB07A4B);

  @override
  Widget build(BuildContext context) {
    final color = switch (rank) {
      1 => _gold,
      2 => _silver,
      3 => _bronze,
      _ => RetroTokens.inkFaint,
    };
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 4)],
      ),
      child: Text(
        rank == 1 ? 'PR' : '$rank',
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: size * (rank == 1 ? 0.36 : 0.44),
        ),
      ),
    );
  }
}

/// Back, bookmark and the overflow menu, floating over the map until the sheet
/// covers it — at which point it takes a background and a title of its own and
/// the back button becomes "put the sheet down".
class _Header extends StatelessWidget {
  const _Header({
    required this.expanded,
    required this.title,
    required this.bookmarked,
    required this.onBack,
    required this.onBookmark,
    required this.onMenu,
  });

  final bool expanded;
  final String title;
  final bool bookmarked;
  final VoidCallback onBack;
  final VoidCallback onBookmark;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        color: expanded
            ? RetroTokens.paperRaised
            : RetroTokens.paperRaised.withValues(alpha: 0),
        child: SafeArea(
          bottom: false,
          child: SizedBox(
            height: 52,
            child: Row(
              children: [
                const SizedBox(width: 8),
                _Round(
                  icon: expanded ? Icons.keyboard_arrow_down : Icons.arrow_back,
                  flat: expanded,
                  tooltip: l.quayLai,
                  onTap: onBack,
                ),
                Expanded(
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 180),
                    opacity: expanded ? 1 : 0,
                    child: Text(
                      title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                _Round(
                  icon: bookmarked ? Icons.bookmark : Icons.bookmark_border,
                  flat: expanded,
                  tooltip: bookmarked ? l.boLuuHoatDong : l.luuHoatDong,
                  onTap: onBookmark,
                ),
                const SizedBox(width: 8),
                _Round(
                  icon: Icons.more_horiz,
                  flat: expanded,
                  tooltip: l.tuyChon,
                  onTap: onMenu,
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Round extends StatelessWidget {
  const _Round({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    required this.flat,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  /// Over the map the button needs its own disc to be legible; over the sheet
  /// it is just an icon.
  final bool flat;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Material(
      color: flat ? Colors.transparent : Colors.white.withValues(alpha: 0.92),
      shape: const CircleBorder(),
      elevation: flat ? 0 : 2,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 38,
          height: 38,
          child: Icon(icon, size: 20, color: RetroTokens.ink),
        ),
      ),
    ),
  );
}

class _Sheet extends StatelessWidget {
  const _Sheet({super.key, required this.controller, required this.children});

  final ScrollController controller;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      color: RetroTokens.paper,
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(RetroTokens.radiusLg),
      ),
      boxShadow: [BoxShadow(color: Color(0x33000000), blurRadius: 12)],
    ),
    child: ClipRRect(
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(RetroTokens.radiusLg),
      ),
      child: ListView(
        controller: controller,
        padding: EdgeInsets.zero,
        children: [
          Center(
            child: Container(
              width: 44,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: RetroTokens.inkFaint,
                borderRadius: BorderRadius.circular(RetroTokens.radiusPill),
              ),
            ),
          ),
          ...children,
        ],
      ),
    ),
  );
}

class _PlayButton extends StatefulWidget {
  const _PlayButton({required this.controller, required this.enabled});

  final AnimationController controller;
  final bool enabled;

  @override
  State<_PlayButton> createState() => _PlayButtonState();
}

class _PlayButtonState extends State<_PlayButton> {
  Future<void> _toggle() async {
    final anim = widget.controller;
    if (anim.isAnimating) {
      anim.stop();
    } else {
      // Whole run in twenty seconds, whatever its length.
      anim.duration = const Duration(seconds: 20);
      if (anim.value >= 1) anim.value = 0;
      await anim.forward();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => FloatingActionButton.small(
      heroTag: null,
      tooltip: widget.controller.isAnimating
          ? AppL10n.of(context).tamDung
          : AppL10n.of(context).xemLaiQuaTrinh,
      backgroundColor: RetroTokens.accent,
      foregroundColor: Colors.white,
      onPressed: widget.enabled ? _toggle : null,
      child: Icon(
        widget.controller.isAnimating ? Icons.pause : Icons.play_arrow,
      ),
    ),
  );
}

/* ------------------------------------------------------------------ */
/* Sheet sections                                                      */
/* ------------------------------------------------------------------ */

const _gutter = EdgeInsets.fromLTRB(16, 0, 16, 16);

/// A section heading, with an optional (i) that opens a short explanation.
class _Heading extends StatelessWidget {
  const _Heading(this.text, {this.icon, this.explain});

  final String text;
  final IconData? icon;
  final String? explain;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
    child: Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 18, color: RetroTokens.inkSoft),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
          ),
        ),
        if (explain != null)
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: AppL10n.of(context).giaiThich,
            icon: const Icon(
              Icons.info_outline,
              size: 18,
              color: RetroTokens.inkSoft,
            ),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => AlertDialog(
                title: Text(text),
                content: Text(explain!),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(AppL10n.of(context).dong),
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}

/// The right-aligned link that closes several sections.
class _MoreLink extends StatelessWidget {
  const _MoreLink({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Align(
      alignment: Alignment.centerRight,
      child: TextButton(
        onPressed: onTap,
        child: Text(
          label,
          style: const TextStyle(
            color: RetroTokens.accent,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    ),
  );
}

/// Who ran it, when and where it started, and what it was called.
class _Identity extends StatelessWidget {
  const _Identity({
    required this.session,
    required this.user,
    required this.run,
  });

  final WorkoutSession session;
  final AppUser? user;
  final RunDetail run;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final name = user?.displayName ?? user?.email.split('@').first ?? l.ban;
    final when = DateFormat(
      'd MMMM, y',
      Localizations.localeOf(context).toString(),
    ).format(DateTime.fromMillisecondsSinceEpoch(session.startedAt));
    final time = DateFormat(
      'HH:mm',
    ).format(DateTime.fromMillisecondsSinceEpoch(session.startedAt));

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: RetroTokens.accentSoft,
                foregroundImage: user?.avatarUrl == null
                    ? null
                    : NetworkImage(user!.avatarUrl!),
                child: Text(
                  name.isEmpty ? '?' : name.characters.first.toUpperCase(),
                  style: const TextStyle(
                    color: RetroTokens.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        const Icon(
                          Icons.directions_run,
                          size: 13,
                          color: RetroTokens.inkSoft,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            l.ngayLucGio(when, time),
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
            session.title ?? l.buoiTap,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
          if (session.notes != null) ...[
            const SizedBox(height: 6),
            Text(session.notes!),
          ],
        ],
      ),
    );
  }
}

/// The banner a run only gets when it set a personal best.
class _PrBanner extends StatelessWidget {
  const _PrBanner({required this.effort, required this.units});

  final RunEffort effort;
  final Units units;

  @override
  Widget build(BuildContext context) => Padding(
    padding: _gutter,
    child: HomeCard(
      color: RetroTokens.warnSoft,
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          const Medal(rank: 1),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              AppL10n.of(context).thanhTichNhanhNhatTuTruoc(
                effortDistanceLabel(context, effort.distanceM),
              ),
              style: const TextStyle(fontWeight: FontWeight.w800, height: 1.3),
            ),
          ),
        ],
      ),
    ),
  );
}

/// The six numbers that describe the run, two to a row.
class _StatGrid extends StatelessWidget {
  const _StatGrid({
    required this.run,
    required this.units,
    required this.language,
  });

  final RunDetail run;
  final Units units;
  final String language;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final s = run.session;
    final steps = s.steps;
    final cells = <({String label, String value})>[
      (label: l.quangDuong, value: units.distanceExact(s.distanceM, language)),
      (label: l.nhipDoTb, value: units.pace(s.avgPaceSecPerKm)),
      (
        label: l.thoiGianDiChuyen,
        value: Units.clock(s.movingSeconds ?? s.durationSeconds),
      ),
      (
        label: l.doCaoTang,
        value: s.elevationGainM == null
            ? '—'
            : '${s.elevationGainM!.round()} m',
      ),
      (
        label: l.doCaoToiDa,
        value: s.elevationMaxM == null ? '—' : '${s.elevationMaxM!.round()} m',
      ),
      if (steps != null)
        (label: l.soBuoc, value: NumberFormat('#,##0', language).format(steps)),
    ];

    return Padding(
      padding: _gutter,
      child: HomeCard(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            for (var i = 0; i < cells.length; i += 2)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Expanded(child: _cell(cells[i])),
                    Expanded(
                      child: i + 1 < cells.length
                          ? _cell(cells[i + 1])
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _cell(({String label, String value}) cell) => Column(
    children: [
      Text(
        cell.label,
        style: const TextStyle(fontSize: 11, color: RetroTokens.inkSoft),
      ),
      const SizedBox(height: 2),
      Text(
        cell.value,
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w800,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    ],
  );
}

/// One coached sentence about the run. Hidden entirely when the model had
/// nothing usable — a card with an error in it is worse than no card.
class _InsightCard extends ConsumerWidget {
  const _InsightCard({
    required this.sessionId,
    required this.kind,
    this.showButton = false,
    this.onAsk,
  });

  final String sessionId;
  final String kind;
  final bool showButton;
  final VoidCallback? onAsk;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final insight = ref.watch(
      workoutInsightProvider((id: sessionId, kind: kind)),
    );

    return insight.when(
      loading: () => const Padding(
        padding: _gutter,
        child: HomeCard(child: _InsightSkeleton()),
      ),
      error: (_, __) => const SizedBox.shrink(),
      data: (body) {
        if (body == null || body.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: _gutter,
          child: HomeCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.auto_awesome,
                      size: 16,
                      color: RetroTokens.accent,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Athlete Intelligence',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: RetroTokens.inkSoft,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(body, style: const TextStyle(fontSize: 16, height: 1.35)),
                if (showButton) ...[
                  const SizedBox(height: 12),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: RetroTokens.accent,
                    ),
                    onPressed: onAsk,
                    child: Text(l.noiChiTietHon),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _InsightSkeleton extends StatelessWidget {
  const _InsightSkeleton();

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _bar(120),
      const SizedBox(height: 12),
      _bar(double.infinity),
      const SizedBox(height: 6),
      _bar(double.infinity),
      const SizedBox(height: 6),
      _bar(180),
    ],
  );

  Widget _bar(double width) => Container(
    width: width,
    height: 12,
    decoration: BoxDecoration(
      color: RetroTokens.paperSunk,
      borderRadius: BorderRadius.circular(RetroTokens.radius),
    ),
  );
}

/// What recorded the session.
class _SourceRow extends StatelessWidget {
  const _SourceRow({required this.source});

  final String source;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final label = switch (source) {
      'health_sync' => l.dongBoTuUngDungSucKhoe,
      'manual_entry' => l.nhapTay,
      _ => l.ghiBangChipHealth,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        children: [
          const Icon(
            Icons.watch_outlined,
            size: 16,
            color: RetroTokens.inkSoft,
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(fontSize: 13, color: RetroTokens.inkSoft),
          ),
        ],
      ),
    );
  }
}

class _Photos extends StatelessWidget {
  const _Photos({required this.ids});

  final List<String> ids;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: SizedBox(
      height: 180,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: ids.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, i) => GestureDetector(
          onTap: () => showWorkoutPhotoViewer(context, ids, i),
          child: SizedBox(
            width: 180,
            child: WorkoutPhotoTile(assetId: ids[i], size: 180),
          ),
        ),
      ),
    ),
  );
}

/// "Dự đoán đã cải thiện": the new predicted time and what this run took off it.
class _PredictionCard extends StatelessWidget {
  const _PredictionCard({required this.prediction, required this.onTrend});

  final RunPrediction prediction;
  final VoidCallback onTrend;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Heading(l.duDoanDaCaiThien, icon: Icons.trending_up),
        Padding(
          padding: _gutter,
          child: HomeCard(
            child: Row(
              children: [
                _DistanceBadge(
                  label: effortDistanceLabel(
                    context,
                    prediction.distanceM,
                  ).replaceAll(' ', ''),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l.thoiGian,
                        style: const TextStyle(
                          fontSize: 11,
                          color: RetroTokens.inkSoft,
                        ),
                      ),
                      Text(
                        compactDuration(context, prediction.seconds),
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      l.lanChayNay,
                      style: const TextStyle(
                        fontSize: 11,
                        color: RetroTokens.inkSoft,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: RetroTokens.okSoft,
                        borderRadius: BorderRadius.circular(
                          RetroTokens.radiusPill,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.arrow_downward,
                            size: 13,
                            color: RetroTokens.ok,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            compactDuration(
                              context,
                              prediction.improvedBySeconds ?? 0,
                            ),
                            style: const TextStyle(
                              color: RetroTokens.ok,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        _MoreLink(label: l.xemXuHuongDuDoan, onTap: onTrend),
      ],
    );
  }
}

/// A predicted time as the app says it out loud: "1giờ15phút", "31giây".
String compactDuration(BuildContext context, int seconds) {
  final l = AppL10n.of(context);
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  if (h > 0) return l.gioPhutNgan('$h', '$m');
  if (m > 0) return l.phutNgan('$m');
  return l.giayNgan('$s');
}

/// The cogged badge a distance sits in.
class _DistanceBadge extends StatelessWidget {
  const _DistanceBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    width: 52,
    height: 52,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: RetroTokens.accentSoft,
      shape: BoxShape.circle,
      border: Border.all(color: RetroTokens.accent, width: 2),
    ),
    child: Text(
      label,
      style: const TextStyle(
        fontWeight: FontWeight.w800,
        color: RetroTokens.accent,
        fontSize: 13,
      ),
    ),
  );
}

/// "Kết quả": two counters, then the efforts worth showing.
class _Results extends StatelessWidget {
  const _Results({required this.run, required this.units, required this.onAll});

  final RunDetail run;
  final Units units;
  final VoidCallback onAll;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final shown = run.bestEfforts.toList()
      ..sort((a, b) {
        final byRank = a.rank.compareTo(b.rank);
        return byRank != 0 ? byRank : b.distanceM.compareTo(a.distanceM);
      });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Heading(l.ketQua),
        Padding(
          padding: _gutter,
          child: Row(
            children: [
              Expanded(
                child: _Counter(
                  label: l.thanhTichTotNhat,
                  value: run.bestEverCount,
                ),
              ),
              Expanded(
                child: _Counter(
                  label: l.thanhTich,
                  value: run.achievementCount,
                ),
              ),
            ],
          ),
        ),
        for (final effort in shown.take(3))
          Padding(
            padding: _gutter,
            child: HomeCard(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Medal(rank: effort.rank),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          effortDistanceLabel(context, effort.distanceM),
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${Units.clock(effort.elapsedSeconds)}   '
                          '${units.pace(effort.paceSecPerKm)}',
                          style: const TextStyle(
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          effort.rank == 1
                              ? l.thanhTichMoiTotNhat
                              : l.thanhTichMoiTotThu('${effort.rank}'),
                          style: const TextStyle(
                            fontSize: 12,
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
        if (shown.length > 3) _MoreLink(label: l.xemTatCaKetQua, onTap: onAll),
      ],
    );
  }
}

class _Counter extends StatelessWidget {
  const _Counter({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(
        label,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 11, color: RetroTokens.inkSoft),
      ),
      const SizedBox(height: 2),
      Text(
        '$value',
        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
      ),
    ],
  );
}

/// "Phân tích nhịp độ": one bar per kilometre.
class _PaceAnalysis extends StatelessWidget {
  const _PaceAnalysis({
    required this.run,
    required this.units,
    required this.elevation,
    required this.pace,
    required this.onCursor,
    required this.onDetail,
  });

  final RunDetail run;
  final Units units;
  final List<ChartPoint> elevation;

  /// Instantaneous pace, drawn over the bars — see [SplitPaceChart.overlay].
  final List<ChartPoint> pace;
  final ValueChanged<SplitBar?> onCursor;
  final VoidCallback onDetail;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    // Including the part-kilometre at the end, which the backend now sends as
    // a split of its own with its real length and a pace converted per
    // kilometre. The screen used to work that row out for itself, which meant
    // two places deciding what the last bar meant.
    final bars = [
      for (final split in run.splits)
        if (split.avgPaceSecPerKm != null)
          SplitBar(
            index: split.splitIndex,
            distanceM: split.splitDistanceM,
            paceSecPerKm: split.avgPaceSecPerKm!,
          ),
    ];
    if (bars.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Heading(l.phanTichNhipDo, icon: Icons.bar_chart),
        Padding(
          padding: _gutter,
          child: HomeCard(
            padding: const EdgeInsets.fromLTRB(4, 12, 8, 4),
            child: SplitPaceChart(
              bars: bars,
              avgPaceSecPerKm: run.session.avgPaceSecPerKm!,
              ghost: elevation,
              overlay: pace,
              labelY: units.pace,
              tooltip: (bar) =>
                  '${l.kmSo('${bar.index}')} · ${units.pace(bar.paceSecPerKm)}',
              onCursor: onCursor,
            ),
          ),
        ),
        _MoreLink(label: l.xemChiTietVeNhipDo, onTap: onDetail),
      ],
    );
  }
}

/// "Chặng": the split table, with a bar per row for how fast it was.
class _SplitTable extends StatelessWidget {
  const _SplitTable({required this.run, required this.units});

  final RunDetail run;
  final Units units;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final language = Localizations.localeOf(context).languageCode;
    final rows = run.splits.where((s) => s.avgPaceSecPerKm != null).toList();
    if (rows.isEmpty) return const SizedBox.shrink();

    final paces = rows.map((s) => s.avgPaceSecPerKm!).toList();
    final fastest = paces.reduce((a, b) => a < b ? a : b);
    final slowest = paces.reduce((a, b) => a > b ? a : b);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Heading(l.chang),
        Padding(
          padding: _gutter,
          child: HomeCard(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              children: [
                Row(
                  children: [
                    SizedBox(width: 40, child: Text('Km', style: _th)),
                    SizedBox(width: 56, child: Text(l.nhipDo, style: _th)),
                    const Expanded(child: SizedBox.shrink()),
                    SizedBox(
                      width: 52,
                      child: Text(
                        l.doCaoTieuDe,
                        textAlign: TextAlign.right,
                        style: _th,
                      ),
                    ),
                  ],
                ),
                const Divider(height: 12),
                // The leftover metres past the last whole kilometre are a
                // split like any other now, sent by the backend with their real
                // length. They are labelled with that length rather than a
                // split number, so the row is not read as a whole kilometre run
                // uncommonly fast.
                for (final split in rows)
                  _row(
                    context,
                    label: split.splitDistanceM >= 1000
                        ? '${split.splitIndex}'
                        : NumberFormat(
                            '0.0',
                            language,
                          ).format(split.splitDistanceM / 1000),
                    pace: split.avgPaceSecPerKm!,
                    elevation: split.elevationGainM,
                    fastest: fastest,
                    slowest: slowest,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static const _th = TextStyle(fontSize: 11, color: RetroTokens.inkSoft);

  Widget _row(
    BuildContext context, {
    required String label,
    required double pace,
    required double? elevation,
    required double fastest,
    required double slowest,
  }) {
    // Longest bar for the fastest split, shortest for the slowest, so the
    // column reads as a shape rather than as eleven identical lines.
    final span = slowest - fastest;
    final fraction = span <= 0 ? 1.0 : 1 - ((pace - fastest) / span) * 0.75;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            child: Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              units.pace(pace).replaceAll('/km', '').replaceAll('/mi', ''),
              style: const TextStyle(
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: fraction.clamp(0.15, 1.0),
                  child: Container(
                    height: 8,
                    decoration: BoxDecoration(
                      color: RetroTokens.accent.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(
                        RetroTokens.radiusPill,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            width: 52,
            child: Text(
              elevation == null
                  ? '—'
                  : '${elevation > 0 ? '+' : ''}${elevation.round()}',
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: RetroTokens.inkSoft,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Nhịp độ": the detailed pace chart, its own insight, and the five readings
/// that go with it.
class _PaceSection extends StatelessWidget {
  const _PaceSection({
    super.key,
    required this.sessionId,
    required this.run,
    required this.units,
    required this.track,
    required this.elevation,
    required this.onCursor,
  });

  final String sessionId;
  final RunDetail run;
  final Units units;
  final List<TrackPoint>? track;
  final List<ChartPoint> elevation;
  final ValueChanged<double?> onCursor;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final s = run.session;
    final raw = _paceSeries(track);
    final series = smoothSeries(raw);
    // The fastest continuous kilometre, not the fastest row of the split table
    // — see `fastestKilometreSeconds`. It falls back to the table when the run
    // never covered a kilometre.
    final fastestKm = fastestKilometreSeconds(run);
    final fastestSplit =
        fastestKm ??
        run.splits
            .map((sp) => sp.avgPaceSecPerKm)
            .whereType<double>()
            .fold<double?>(
              null,
              (best, v) => best == null || v < best ? v : best,
            );

    // Elapsed pace: the whole clock over the distance, including the stops.
    final elapsedPace = (s.durationSeconds != null && (s.distanceM ?? 0) > 0)
        ? (s.durationSeconds! / s.distanceM!) * 1000
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Heading(l.nhipDo, explain: l.giaiThichNhipDo),
        if (series.length > 1)
          Padding(
            padding: _gutter,
            child: HomeCard(
              padding: const EdgeInsets.fromLTRB(4, 12, 8, 4),
              child: RunAreaChart(
                series: series,
                raw: raw,
                ghost: elevation,
                valueStep: 60,
                invertY: true,
                // A band wide enough to hold a walk without being given to it:
                // the stretches spent standing still pin to the bottom edge
                // instead of stretching the axis until the running is a line.
                minY: paceBand(series).lo,
                maxY: paceBand(series).hi,
                labelY: (v) => units.pace(v).replaceAll(RegExp(r'/\w+'), ''),
                unitY: units.isImperial ? '/mi' : '/km',
                tooltip: (d, v) => '${units.distance(d)} · ${units.pace(v)}',
                onCursor: onCursor,
              ),
            ),
          )
        else
          const Padding(padding: _gutter, child: _ChartSkeleton()),
        _InsightCard(sessionId: sessionId, kind: 'pace'),
        Padding(
          padding: _gutter,
          child: HomeCard(
            child: Column(
              children: [
                _Reading(l.nhipDoTb, units.pace(s.avgPaceSecPerKm)),
                _Reading(
                  l.thoiGianDiChuyen,
                  Units.clock(s.movingSeconds ?? s.durationSeconds),
                ),
                _Reading(l.nhipDoTbTheoThoiGianThucTe, units.pace(elapsedPace)),
                _Reading(l.thoiGianThucTe, Units.clock(s.durationSeconds)),
                if ((s.stoppedSeconds ?? 0) > 0)
                  _Reading(l.thoiGianDung, Units.clock(s.stoppedSeconds)),
                _Reading(l.changNhanhNhat, units.pace(fastestSplit)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// "Nhịp độ điều chỉnh theo độ dốc": the same run with the hills taken out.
class _GapSection extends StatelessWidget {
  const _GapSection({
    required this.run,
    required this.units,
    required this.track,
    required this.elevation,
    required this.onCursor,
  });

  final RunDetail run;
  final Units units;
  final List<TrackPoint> track;
  final List<ChartPoint> elevation;
  final ValueChanged<double?> onCursor;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final raw = _gapSeries(track);
    final series = smoothSeries(raw);
    if (series.length < 2) return const SizedBox.shrink();
    // Wider at the fast end than the plain pace chart: taking a climb out of a
    // pace is what makes the fastest stretches of the run fast, and those are
    // the ones the chart exists to show.
    final band = paceBand(series, lowPercentile: 0.02, minSpan: 240);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Heading(l.nhipDoDieuChinhTheoDoDoc, icon: Icons.terrain),
        Padding(
          padding: _gutter,
          child: HomeCard(
            padding: const EdgeInsets.fromLTRB(4, 12, 8, 4),
            child: Column(
              children: [
                RunAreaChart(
                  series: series,
                  raw: raw,
                  ghost: elevation,
                  valueStep: 60,
                  invertY: true,
                  minY: band.lo,
                  maxY: band.hi,
                  color: RetroTokens.info,
                  labelY: (v) => units.pace(v).replaceAll(RegExp(r'/\w+'), ''),
                  unitY: units.isImperial ? '/mi' : '/km',
                  tooltip: (d, v) => '${units.distance(d)} · ${units.pace(v)}',
                  onCursor: onCursor,
                ),
                const SizedBox(height: 8),
                _Reading(l.gapTb, units.pace(run.session.gapSecPerKm)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// "Vùng nhịp độ": how the run split across the six bands of effort.
class _PaceZones extends StatelessWidget {
  const _PaceZones({
    required this.sessionId,
    required this.run,
    required this.units,
    required this.onAll,
  });

  final String sessionId;
  final RunDetail run;
  final Units units;
  final VoidCallback onAll;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final ranges = {for (final r in run.paceZoneRanges) r.zoneNumber: r};
    final zones = run.paceZones.toList()
      ..sort((a, b) => b.zoneNumber.compareTo(a.zoneNumber));
    final peak = zones
        .map((z) => z.percentOfSession ?? 0)
        .fold<double>(1, (a, b) => a > b ? a : b);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Heading(l.vungNhipDo, icon: Icons.speed),
        if (run.paceZoneBasisSeconds != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Text(
              l.duaTrenDuDoan5Km(Units.clock(run.paceZoneBasisSeconds)),
              style: const TextStyle(fontSize: 12, color: RetroTokens.inkSoft),
            ),
          ),
        Padding(
          padding: _gutter,
          child: HomeCard(
            child: Column(
              children: [
                for (final zone in zones)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 26,
                          child: Text(
                            'Z${zone.zoneNumber}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 5,
                          child: Row(
                            children: [
                              Flexible(
                                child: FractionallySizedBox(
                                  alignment: Alignment.centerLeft,
                                  widthFactor:
                                      ((zone.percentOfSession ?? 0) / peak)
                                          .clamp(0.02, 1.0),
                                  child: Container(
                                    height: 12,
                                    decoration: BoxDecoration(
                                      color: _zoneColor(zone.zoneNumber),
                                      borderRadius: BorderRadius.circular(
                                        RetroTokens.radiusPill,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '${(zone.percentOfSession ?? 0).round()}%',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 4,
                          child: Text(
                            _rangeLabel(ranges[zone.zoneNumber]),
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                              fontSize: 12,
                              color: RetroTokens.inkSoft,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        _InsightCard(sessionId: sessionId, kind: 'zones'),
        _MoreLink(label: l.xemTongThoiGianTheoVungNhipDo, onTap: onAll),
      ],
    );
  }

  /// Zone 6 has no floor and zone 1 no ceiling, so they read as "< 6:04" and
  /// "> 8:56" rather than as a band with a blank end.
  String _rangeLabel(PaceZoneRange? range) {
    if (range == null) return '—';
    String bare(double? v) => units.pace(v).replaceAll(RegExp(r'\s*/\w+'), '');
    if (range.minSecPerKm == null) return '< ${bare(range.maxSecPerKm)}';
    if (range.maxSecPerKm == null) return '> ${bare(range.minSecPerKm)}';
    return '${bare(range.minSecPerKm)}-${bare(range.maxSecPerKm)}';
  }

  Color _zoneColor(int zone) => switch (zone) {
    6 => RetroTokens.accent,
    5 => RetroTokens.zone5,
    4 => RetroTokens.zone4,
    3 => RetroTokens.zone3,
    2 => RetroTokens.zone2,
    _ => RetroTokens.zone1,
  };
}

/// Heart-rate zones, when the recording carried a heart rate.
class _HeartRateZones extends StatelessWidget {
  const _HeartRateZones({required this.zones});

  final List<ZoneSummary> zones;

  @override
  Widget build(BuildContext context) {
    final peak = zones
        .map((z) => z.secondsInZone)
        .fold<int>(1, (a, b) => a > b ? a : b);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Heading(AppL10n.of(context).vungNhipTim, icon: Icons.favorite_outline),
        Padding(
          padding: _gutter,
          child: HomeCard(
            child: Column(
              children: [
                for (final zone in zones.reversed)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 26,
                          child: Text(
                            'Z${zone.zoneNumber}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        Expanded(
                          child: FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: (zone.secondsInZone / peak).clamp(
                              0.02,
                              1.0,
                            ),
                            child: Container(
                              height: 12,
                              decoration: BoxDecoration(
                                color:
                                    RetroTokens.zoneColors[(zone.zoneNumber - 1)
                                        .clamp(
                                          0,
                                          RetroTokens.zoneColors.length - 1,
                                        )],
                                borderRadius: BorderRadius.circular(
                                  RetroTokens.radiusPill,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 64,
                          child: Text(
                            Units.clock(zone.secondsInZone),
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                              fontSize: 12,
                              color: RetroTokens.inkSoft,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
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
    );
  }
}

/// What the heart-rate section says when the run carried no heart rate.
class _NoHeartRate extends StatelessWidget {
  const _NoHeartRate({required this.onHelp});

  final VoidCallback onHelp;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Heading(
          l.thongTinChiTietVeNhipTim,
          icon: Icons.monitor_heart_outlined,
        ),
        Padding(
          padding: _gutter,
          child: HomeCard(
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.favorite,
                      color: RetroTokens.inkFaint,
                      size: 22,
                    ),
                    for (var i = 0; i < 3; i++) _dot(),
                    const Icon(
                      Icons.close,
                      color: RetroTokens.inkFaint,
                      size: 16,
                    ),
                    for (var i = 0; i < 3; i++) _dot(),
                    const Icon(
                      Icons.monitor_heart,
                      color: RetroTokens.inkFaint,
                      size: 22,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  l.ketNoiMayDoNhipTim,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    color: RetroTokens.inkSoft,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 4),
                TextButton(
                  onPressed: onHelp,
                  child: Text(
                    l.cachThemDuLieuNhipTim,
                    style: const TextStyle(
                      color: RetroTokens.accent,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _dot() => Container(
    width: 3,
    height: 3,
    margin: const EdgeInsets.symmetric(horizontal: 3),
    decoration: const BoxDecoration(
      color: RetroTokens.inkFaint,
      shape: BoxShape.circle,
    ),
  );
}

/// "Độ cao": the profile on its own, with the two numbers that summarise it.
class _ElevationSection extends StatelessWidget {
  const _ElevationSection({
    required this.run,
    required this.elevation,
    required this.onCursor,
  });

  final RunDetail run;
  final List<ChartPoint> elevation;
  final ValueChanged<double?> onCursor;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final s = run.session;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Heading(l.doCaoTieuDe, explain: l.giaiThichDoCao),
        Padding(
          padding: _gutter,
          child: HomeCard(
            padding: const EdgeInsets.fromLTRB(4, 12, 8, 4),
            child: Column(
              children: [
                RunAreaChart(
                  series: elevation,
                  valueStep: 5,
                  color: RetroTokens.zone3,
                  labelY: (v) => '${v.round()}',
                  unitY: 'm',
                  tooltip: (d, v) =>
                      '${(d / 1000).toStringAsFixed(1)} km · ${v.round()} m',
                  onCursor: onCursor,
                ),
                const SizedBox(height: 8),
                _Reading(
                  l.doCaoTang,
                  s.elevationGainM == null
                      ? '—'
                      : '${s.elevationGainM!.round()} m',
                ),
                _Reading(
                  l.doCaoToiDa,
                  s.elevationMaxM == null
                      ? '—'
                      : '${s.elevationMaxM!.round()} m',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// A label on the left, a figure on the right — the shape every readings list
/// on this screen uses.
class _Reading extends StatelessWidget {
  const _Reading(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontSize: 13, color: RetroTokens.inkSoft),
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    ),
  );
}

class _ChartSkeleton extends StatelessWidget {
  const _ChartSkeleton();

  @override
  Widget build(BuildContext context) => Container(
    height: 180,
    decoration: BoxDecoration(
      color: RetroTokens.paperSunk,
      borderRadius: BorderRadius.circular(RetroTokens.radiusLg),
    ),
  );
}
