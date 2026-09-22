import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';

/// One sample of a charted series: a value at a cumulative distance in metres.
class ChartPoint {
  const ChartPoint(this.d, this.v);
  final double d;
  final double v;
}

/// The grey elevation profile every run chart carries behind its own series.
/// Drawn on its own scale — it is there for shape, not for reading heights off.
const _ghostColor = Color(0x22000000);

const _axisText = TextStyle(fontSize: 10, color: RetroTokens.inkFaint);
const _gridColor = Color(0x1A000000);

/// Room for the y-axis labels and the x-axis labels, inside the chart box.
const _padLeft = 42.0;
const _padBottom = 18.0;
const _padTop = 8.0;
const _padRight = 8.0;

/// A value axis rounded out to whole [step]s, so the labels are readable
/// numbers (whole minutes of pace, five metres of height) rather than whatever
/// the data happened to touch.
({double lo, double hi, List<double> ticks}) axisFor(
  Iterable<double> values,
  double step, {
  double? forceLo,
  double? forceHi,
}) {
  final list = values.where((v) => v.isFinite).toList();
  if (list.isEmpty) return (lo: 0, hi: step, ticks: [0, step]);
  var lo = forceLo ?? (list.reduce(math.min) / step).floorToDouble() * step;
  var hi = forceHi ?? (list.reduce(math.max) / step).ceilToDouble() * step;
  if (hi <= lo) hi = lo + step;
  // Six labels is the most that fits without the axis becoming a ladder.
  var stride = step;
  while ((hi - lo) / stride > 6) {
    stride *= 2;
  }
  final ticks = <double>[];
  for (var v = lo; v <= hi + 0.001; v += stride) {
    ticks.add(v);
  }
  return (lo: lo, hi: hi, ticks: ticks);
}

/// Pace and elevation read in opposite directions: for pace a SMALLER number is
/// better and belongs at the top, so its axis is flipped.
double _fraction(double v, double lo, double hi, bool invert) {
  if (hi <= lo) return 0.5;
  final f = ((v - lo) / (hi - lo)).clamp(0.0, 1.0);
  return invert ? f : 1 - f;
}

/// Kilometre marks along the bottom: every 2 km up to the distance covered,
/// or every kilometre on a run short enough that every 2 km would give one mark.
List<double> distanceTicks(double totalM) {
  final stepKm = totalM <= 6000 ? 1 : (totalM <= 24000 ? 2 : 5);
  final out = <double>[];
  for (var km = stepKm; km * 1000 <= totalM + 1; km += stepKm) {
    out.add(km * 1000);
  }
  return out;
}

/* ------------------------------------------------------------------ */
/* Area chart: pace, grade adjusted pace, elevation                    */
/* ------------------------------------------------------------------ */

/// A filled series against distance, with the elevation profile behind it and a
/// finger-following cursor that reports back where it is.
///
/// The cursor is what ties the chart to the map: the screen turns the distance
/// this reports into a marker on the route, and hides it again on release.
class RunAreaChart extends StatefulWidget {
  const RunAreaChart({
    super.key,
    required this.series,
    required this.valueStep,
    required this.labelY,
    required this.unitY,
    required this.tooltip,
    required this.onCursor,
    this.ghost = const [],
    this.invertY = false,
    this.height = 180,
    this.color = RetroTokens.accent,
  });

  final List<ChartPoint> series;

  /// Elevation, drawn behind on its own scale. Empty on the elevation chart
  /// itself, which would otherwise draw its own series twice.
  final List<ChartPoint> ghost;

  /// Rounding for the value axis: 60 s for pace, 5 m for height.
  final double valueStep;
  final bool invertY;
  final String Function(double value) labelY;
  final String unitY;
  final String Function(double distanceM, double value) tooltip;

  /// Distance under the finger, or null when nothing is being touched.
  final ValueChanged<double?> onCursor;
  final double height;
  final Color color;

  @override
  State<RunAreaChart> createState() => _RunAreaChartState();
}

class _RunAreaChartState extends State<RunAreaChart> {
  double? _cursorD;

  double get _totalM => widget.series.isEmpty ? 0 : widget.series.last.d;

  void _setCursor(Offset local, Size size) {
    final plotWidth = size.width - _padLeft - _padRight;
    if (plotWidth <= 0 || _totalM <= 0) return;
    final f = ((local.dx - _padLeft) / plotWidth).clamp(0.0, 1.0);
    setState(() => _cursorD = f * _totalM);
    widget.onCursor(_cursorD);
  }

  void _clear() {
    if (_cursorD == null) return;
    setState(() => _cursorD = null);
    widget.onCursor(null);
  }

  /// The charted value at [d], interpolated between samples.
  double? _valueAt(double d) {
    final s = widget.series;
    if (s.isEmpty) return null;
    var lo = 0;
    var hi = s.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (s[mid].d <= d) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    if (lo >= s.length - 1) return s.last.v;
    final a = s[lo];
    final b = s[lo + 1];
    if (b.d <= a.d) return a.v;
    final f = ((d - a.d) / (b.d - a.d)).clamp(0.0, 1.0);
    return a.v + (b.v - a.v) * f;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.series.length < 2) return const SizedBox.shrink();
    final axis = axisFor(widget.series.map((p) => p.v), widget.valueStep);
    final cursorValue = _cursorD == null ? null : _valueAt(_cursorD!);

    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, widget.height);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (e) => _setCursor(e.localPosition, size),
            onTapUp: (_) => _clear(),
            onTapCancel: _clear,
            onHorizontalDragStart: (e) => _setCursor(e.localPosition, size),
            onHorizontalDragUpdate: (e) => _setCursor(e.localPosition, size),
            onHorizontalDragEnd: (_) => _clear(),
            onHorizontalDragCancel: _clear,
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _AreaPainter(
                      series: widget.series,
                      ghost: widget.ghost,
                      lo: axis.lo,
                      hi: axis.hi,
                      ticks: axis.ticks,
                      invert: widget.invertY,
                      labelY: widget.labelY,
                      unitY: widget.unitY,
                      color: widget.color,
                      cursorD: _cursorD,
                      cursorV: cursorValue,
                    ),
                  ),
                ),
                if (_cursorD != null && cursorValue != null)
                  _Tooltip(
                    text: widget.tooltip(_cursorD!, cursorValue),
                    fraction: _totalM <= 0 ? 0 : _cursorD! / _totalM,
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The readout that follows the finger. It is a widget rather than something
/// the painter draws so it can use the app's text styles, and it slides along
/// the plot instead of running off the edge at either end.
class _Tooltip extends StatelessWidget {
  const _Tooltip({required this.text, required this.fraction});

  final String text;
  final double fraction;

  @override
  Widget build(BuildContext context) => Positioned(
    left: _padLeft,
    right: _padRight,
    top: 0,
    child: Align(
      alignment: Alignment(fraction.clamp(0.0, 1.0) * 2 - 1, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: RetroTokens.ink,
          borderRadius: BorderRadius.circular(RetroTokens.radius),
        ),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ),
    ),
  );
}

class _AreaPainter extends CustomPainter {
  _AreaPainter({
    required this.series,
    required this.ghost,
    required this.lo,
    required this.hi,
    required this.ticks,
    required this.invert,
    required this.labelY,
    required this.unitY,
    required this.color,
    required this.cursorD,
    required this.cursorV,
  });

  final List<ChartPoint> series;
  final List<ChartPoint> ghost;
  final double lo;
  final double hi;
  final List<double> ticks;
  final bool invert;
  final String Function(double) labelY;
  final String unitY;
  final Color color;
  final double? cursorD;
  final double? cursorV;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(
      _padLeft,
      _padTop,
      size.width - _padRight,
      size.height - _padBottom,
    );
    if (plot.width <= 0 || plot.height <= 0 || series.length < 2) return;
    final totalM = series.last.d;
    if (totalM <= 0) return;

    final grid = Paint()
      ..color = _gridColor
      ..strokeWidth = 1;

    // Horizontal grid and the value labels.
    for (final tick in ticks) {
      final y = plot.top + plot.height * (1 - _fraction(tick, lo, hi, invert));
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      _text(canvas, labelY(tick), Offset(_padLeft - 6, y), alignRight: true);
    }
    _text(
      canvas,
      unitY,
      Offset(_padLeft - 6, size.height - _padBottom + 2),
      alignRight: true,
      top: true,
    );

    // Vertical grid at each kilometre mark.
    for (final tick in distanceTicks(totalM)) {
      final x = plot.left + plot.width * (tick / totalM);
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), grid);
      _text(
        canvas,
        '${(tick / 1000).round()}',
        Offset(x, plot.bottom + 2),
        center: true,
        top: true,
      );
    }

    // The elevation profile, on its own scale, behind everything.
    if (ghost.length > 1) {
      final eles = ghost.map((p) => p.v);
      final gLo = eles.reduce(math.min);
      final gHi = eles.reduce(math.max);
      final path = Path()..moveTo(plot.left, plot.bottom);
      for (final p in ghost) {
        final x = plot.left + plot.width * (p.d / totalM).clamp(0.0, 1.0);
        // Squashed into the bottom two thirds so it stays scenery.
        final y =
            plot.bottom - plot.height * 0.66 * _fraction(p.v, gLo, gHi, true);
        path.lineTo(x, y);
      }
      path
        ..lineTo(plot.right, plot.bottom)
        ..close();
      canvas.drawPath(path, Paint()..color = _ghostColor);
    }

    // The series itself: filled area under a solid line.
    final line = Path();
    for (var i = 0; i < series.length; i++) {
      final p = series[i];
      final x = plot.left + plot.width * (p.d / totalM).clamp(0.0, 1.0);
      final y = plot.top + plot.height * (1 - _fraction(p.v, lo, hi, invert));
      if (i == 0) {
        line.moveTo(x, y);
      } else {
        line.lineTo(x, y);
      }
    }
    final area = Path.from(line)
      ..lineTo(plot.right, plot.bottom)
      ..lineTo(plot.left, plot.bottom)
      ..close();
    canvas.drawPath(area, Paint()..color = color.withValues(alpha: 0.22));
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // The cursor, last, so it sits over the line it is reading.
    if (cursorD != null && cursorV != null) {
      final x = plot.left + plot.width * (cursorD! / totalM).clamp(0.0, 1.0);
      final y =
          plot.top + plot.height * (1 - _fraction(cursorV!, lo, hi, invert));
      canvas.drawLine(
        Offset(x, plot.top),
        Offset(x, plot.bottom),
        Paint()
          ..color = RetroTokens.ink
          ..strokeWidth = 1,
      );
      canvas.drawCircle(Offset(x, y), 4, Paint()..color = RetroTokens.ink);
      canvas.drawCircle(
        Offset(x, y),
        2,
        Paint()..color = RetroTokens.paperRaised,
      );
    }
  }

  void _text(
    Canvas canvas,
    String value,
    Offset at, {
    bool alignRight = false,
    bool center = false,
    bool top = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: value, style: _axisText),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = alignRight
        ? at.dx - painter.width
        : center
        ? at.dx - painter.width / 2
        : at.dx;
    final dy = top ? at.dy : at.dy - painter.height / 2;
    painter.paint(canvas, Offset(dx, dy));
  }

  @override
  bool shouldRepaint(_AreaPainter old) =>
      old.series != series ||
      old.cursorD != cursorD ||
      old.lo != lo ||
      old.hi != hi;
}

/* ------------------------------------------------------------------ */
/* Bar chart: one bar per kilometre                                    */
/* ------------------------------------------------------------------ */

class SplitBar {
  const SplitBar({
    required this.index,
    required this.distanceM,
    required this.paceSecPerKm,
  });

  final int index;
  final double distanceM;
  final double paceSecPerKm;
}

/// Pace per kilometre as bars: each bar as wide as its split is long (so the
/// leftover 600 m at the end is visibly a part-kilometre) and as tall as it was
/// fast, with the average marked by a dashed rule and the elevation behind.
class SplitPaceChart extends StatefulWidget {
  const SplitPaceChart({
    super.key,
    required this.bars,
    required this.avgPaceSecPerKm,
    required this.labelY,
    required this.tooltip,
    required this.onCursor,
    this.ghost = const [],
    this.height = 190,
  });

  final List<SplitBar> bars;
  final double avgPaceSecPerKm;
  final List<ChartPoint> ghost;
  final String Function(double pace) labelY;
  final String Function(SplitBar bar) tooltip;

  /// The split under the finger, or null on release.
  final ValueChanged<SplitBar?> onCursor;
  final double height;

  @override
  State<SplitPaceChart> createState() => _SplitPaceChartState();
}

class _SplitPaceChartState extends State<SplitPaceChart> {
  int? _cursor;

  double get _totalM =>
      widget.bars.fold<double>(0, (sum, b) => sum + b.distanceM);

  void _setCursor(Offset local, Size size) {
    final plotWidth = size.width - _padLeft - _padRight;
    if (plotWidth <= 0 || _totalM <= 0) return;
    final d = ((local.dx - _padLeft) / plotWidth).clamp(0.0, 1.0) * _totalM;
    var run = 0.0;
    for (var i = 0; i < widget.bars.length; i++) {
      run += widget.bars[i].distanceM;
      if (d <= run || i == widget.bars.length - 1) {
        if (_cursor != i) {
          setState(() => _cursor = i);
          widget.onCursor(widget.bars[i]);
        }
        return;
      }
    }
  }

  void _clear() {
    if (_cursor == null) return;
    setState(() => _cursor = null);
    widget.onCursor(null);
  }

  /// The band the bars are drawn against. The fastest split sets the top; the
  /// bottom follows the bulk of the run rather than its slowest moment, so one
  /// walked kilometre flattens the other ten into a strip. Splits below the
  /// band bottom out at a stub that is still visibly there.
  ({double lo, double hi}) get _band {
    final paces = widget.bars.map((b) => b.paceSecPerKm).toList()..sort();
    final fastest = paces.first;
    final upper = paces[((paces.length - 1) * 0.75).round()];
    final lo = (fastest / 15).floorToDouble() * 15;
    final hi = math.max(
      (math.max(upper, widget.avgPaceSecPerKm) / 15).ceilToDouble() * 15,
      lo + 45,
    );
    return (lo: lo, hi: hi);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.bars.isEmpty) return const SizedBox.shrink();
    final band = _band;

    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, widget.height);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (e) => _setCursor(e.localPosition, size),
            onTapUp: (_) => _clear(),
            onTapCancel: _clear,
            onHorizontalDragStart: (e) => _setCursor(e.localPosition, size),
            onHorizontalDragUpdate: (e) => _setCursor(e.localPosition, size),
            onHorizontalDragEnd: (_) => _clear(),
            onHorizontalDragCancel: _clear,
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _BarPainter(
                      bars: widget.bars,
                      ghost: widget.ghost,
                      lo: band.lo,
                      hi: band.hi,
                      avg: widget.avgPaceSecPerKm,
                      labelY: widget.labelY,
                      cursor: _cursor,
                    ),
                  ),
                ),
                if (_cursor != null)
                  _Tooltip(
                    text: widget.tooltip(widget.bars[_cursor!]),
                    fraction: widget.bars.length <= 1
                        ? 0.5
                        : _cursor! / (widget.bars.length - 1),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter({
    required this.bars,
    required this.ghost,
    required this.lo,
    required this.hi,
    required this.avg,
    required this.labelY,
    required this.cursor,
  });

  final List<SplitBar> bars;
  final List<ChartPoint> ghost;
  final double lo;
  final double hi;
  final double avg;
  final String Function(double) labelY;
  final int? cursor;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(
      _padLeft,
      _padTop,
      size.width - _padRight,
      size.height - _padBottom,
    );
    final totalM = bars.fold<double>(0, (sum, b) => sum + b.distanceM);
    if (plot.width <= 0 || plot.height <= 0 || totalM <= 0) return;

    final grid = Paint()
      ..color = _gridColor
      ..strokeWidth = 1;
    for (var tick = lo; tick <= hi + 0.001; tick += (hi - lo) / 3) {
      final y = plot.top + plot.height * _fraction(tick, lo, hi, false);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      _label(canvas, labelY(tick), Offset(_padLeft - 6, y));
    }

    if (ghost.length > 1) {
      final eles = ghost.map((p) => p.v);
      final gLo = eles.reduce(math.min);
      final gHi = eles.reduce(math.max);
      final path = Path()..moveTo(plot.left, plot.bottom);
      for (final p in ghost) {
        final x = plot.left + plot.width * (p.d / totalM).clamp(0.0, 1.0);
        final y =
            plot.bottom - plot.height * 0.55 * _fraction(p.v, gLo, gHi, true);
        path.lineTo(x, y);
      }
      path
        ..lineTo(plot.right, plot.bottom)
        ..close();
      canvas.drawPath(path, Paint()..color = _ghostColor);
    }

    // The bars. Height is how fast, so a pace at the top of the band is a full
    // bar; anything past the bottom keeps a stub rather than vanishing.
    var run = 0.0;
    for (var i = 0; i < bars.length; i++) {
      final bar = bars[i];
      final x0 = plot.left + plot.width * (run / totalM);
      run += bar.distanceM;
      final x1 = plot.left + plot.width * (run / totalM);
      final f = 1 - _fraction(bar.paceSecPerKm, lo, hi, false);
      final height = math.max(plot.height * f, 4.0);
      final rect = Rect.fromLTRB(
        x0 + 1,
        plot.bottom - height,
        math.max(x1 - 1, x0 + 2),
        plot.bottom,
      );
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          rect,
          topLeft: const Radius.circular(3),
          topRight: const Radius.circular(3),
        ),
        Paint()
          ..color = i == cursor
              ? RetroTokens.ink
              : RetroTokens.accent.withValues(alpha: 0.85),
      );
    }

    // The average, as a dashed rule across the whole plot.
    final avgY = plot.top + plot.height * _fraction(avg, lo, hi, false);
    final dash = Paint()
      ..color = RetroTokens.inkSoft
      ..strokeWidth = 1;
    for (var x = plot.left; x < plot.right; x += 8) {
      canvas.drawLine(
        Offset(x, avgY),
        Offset(math.min(x + 4, plot.right), avgY),
        dash,
      );
    }
  }

  void _label(Canvas canvas, String value, Offset at) {
    final painter = TextPainter(
      text: TextSpan(text: value, style: _axisText),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      Offset(at.dx - painter.width, at.dy - painter.height / 2),
    );
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.bars != bars || old.cursor != cursor || old.lo != lo || old.hi != hi;
}
