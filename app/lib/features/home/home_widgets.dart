import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import '../../core/l10n/gen/app_localizations.dart';

/// Rounded card, the app's shared surface. The radius lives in one widget so
/// every screen rounds identically instead of being retyped per card.
class HomeCard extends StatelessWidget {
  const HomeCard({
    super.key,
    required this.child,
    this.color = RetroTokens.paperRaised,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final Color color;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(RetroTokens.radiusLg),
      border: Border.all(color: RetroTokens.ink, width: RetroTokens.border),
      boxShadow: const [
        BoxShadow(color: RetroTokens.ink, offset: Offset(3, 3)),
      ],
    ),
    child: child,
  );
}

/// The mascot. There is no image in assets/images yet, and an emoji is not an
/// option: the web build has no Noto emoji font, so it renders as a tofu box.
/// A glyph on a soft disc stands in — swap it for an Image.asset once the art
/// exists and nothing else has to change.
class Mascot extends StatelessWidget {
  const Mascot({super.key, this.size = 60});

  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: const BoxDecoration(
      color: RetroTokens.paperSunk,
      shape: BoxShape.circle,
    ),
    child: Icon(Icons.pets, size: size * 0.45, color: RetroTokens.inkSoft),
  );
}

/// One day in the week strip: label above, number in a circle. The selected day
/// gets a solid ring, every other day a faint dotted one.
class DayPip extends StatelessWidget {
  const DayPip({
    super.key,
    required this.label,
    required this.day,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final int day;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = enabled ? RetroTokens.ink : RetroTokens.inkFaint;
    final pip = GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: selected ? RetroTokens.ink : RetroTokens.inkFaint,
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: 34,
            height: 34,
            child: CustomPaint(
              painter: _RingPainter(
                color: selected ? RetroTokens.ink : RetroTokens.inkFaint,
                dashed: !selected,
                width: selected ? 2 : 1,
              ),
              child: Center(
                child: Text(
                  '$day',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? RetroTokens.ink : ink,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    // Future days fade out as a whole — label, ring and number — so they
    // read as "not yet" at a glance instead of as a slightly lighter grey.
    return enabled ? pip : Opacity(opacity: 0.3, child: pip);
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.color,
    required this.dashed,
    required this.width,
  });

  final Color color;
  final bool dashed;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round;
    final radius = (math.min(size.width, size.height) - width) / 2;
    final center = Offset(size.width / 2, size.height / 2);

    if (!dashed) {
      canvas.drawCircle(center, radius, paint);
      return;
    }
    // Flutter has no dashed border, so the ring is drawn as arcs: 20 gaps is
    // dense enough to read as a dotted outline at 34dp.
    const segments = 20;
    const sweep = math.pi * 2 / segments;
    final rect = Rect.fromCircle(center: center, radius: radius);
    for (var i = 0; i < segments; i++) {
      canvas.drawArc(rect, i * sweep, sweep * 0.5, false, paint);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.color != color || old.dashed != dashed || old.width != width;
}

/// A macro column inside the overview carousel: label, bar, "eaten/target".
class MacroBar extends StatelessWidget {
  const MacroBar({
    super.key,
    required this.label,
    required this.value,
    required this.target,
    required this.unit,
    required this.color,
  });

  final String label;
  final double value;
  final double target;
  final String unit;
  final Color color;

  static String _fmt(double v) => v >= 100 || v == v.roundToDouble()
      ? v.round().toString()
      : v.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final ratio = target <= 0 ? 0.0 : (value / target).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11, color: RetroTokens.inkSoft),
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(RetroTokens.radiusPill),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 6,
            backgroundColor: RetroTokens.paperSunk,
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            '${_fmt(value)}/${_fmt(target)} $unit',
            maxLines: 1,
            softWrap: false,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: RetroTokens.ink,
            ),
          ),
        ),
      ],
    );
  }
}

class PageDots extends StatelessWidget {
  const PageDots({super.key, required this.count, required this.index});

  final int count;
  final int index;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      for (var i = 0; i < count; i++)
        AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: i == index ? 16 : 6,
          height: 6,
          decoration: BoxDecoration(
            color: i == index
                ? RetroTokens.ink
                : RetroTokens.inkFaint.withAlpha(102),
            borderRadius: BorderRadius.circular(RetroTokens.radiusPill),
          ),
        ),
    ],
  );
}

/// The big round action button that every card and the nav bar share.
class AddButton extends StatelessWidget {
  const AddButton({
    super.key,
    required this.onTap,
    this.size = 44,
    this.color = RetroTokens.action,
    this.iconColor = Colors.white,
    this.icon = Icons.add,
  });

  final VoidCallback onTap;
  final double size;
  final Color color;
  final Color iconColor;

  /// The glyph inside the disc. The nav bar overrides it with a stacked-lines
  /// icon; every other caller keeps the default "+".
  final IconData icon;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: AppL10n.of(context).them,
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: RetroTokens.ink, width: RetroTokens.border),
          boxShadow: const [
            BoxShadow(color: RetroTokens.ink, offset: Offset(2, 2)),
          ],
        ),
        child: Icon(icon, color: iconColor, size: size * 0.55),
      ),
    ),
  );
}

/// "Ghi lại bữa đầu tiên!" plus a hand-drawn arrow curving up to the "+".
/// The arrow is painted rather than an asset so it inherits the ink colour and
/// survives any card width.
class EmptyHint extends StatelessWidget {
  const EmptyHint({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 76,
    child: Stack(
      children: [
        Positioned(
          left: 4,
          bottom: 8,
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: RetroTokens.inkFaint,
            ),
          ),
        ),
        Positioned.fill(child: CustomPaint(painter: _HandArrowPainter())),
      ],
    ),
  );
}

class _HandArrowPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = RetroTokens.inkFaint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Starts just right of the hint text, sweeps up toward the "+" that sits at
    // the card's top-right corner.
    final start = Offset(size.width * 0.55, size.height - 22);
    final end = Offset(size.width - 6, 2);
    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..cubicTo(
        size.width * 0.68,
        size.height - 26,
        size.width * 0.72,
        size.height * 0.25,
        end.dx,
        end.dy,
      );
    canvas.drawPath(path, paint);

    // Arrowhead: two short strokes off the tip, angled back down the curve.
    const head = 10.0;
    final dir = math.atan2(
      end.dy - size.height * 0.25,
      end.dx - size.width * 0.72,
    );
    for (final spread in [0.5, -0.9]) {
      final a = dir + math.pi + spread;
      canvas.drawLine(
        end,
        Offset(end.dx + math.cos(a) * head, end.dy + math.sin(a) * head),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}
