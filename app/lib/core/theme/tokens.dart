import 'package:flutter/material.dart';

/// Retro design tokens: warm paper, muted-but-saturated ink, hard offset shadows.
/// Everything else in the app derives from these — no ad-hoc colours in widgets.
class RetroTokens {
  const RetroTokens._();

  // Surfaces
  static const paper = Color(0xFFF7F3EA);
  static const paperRaised = Color(0xFFFFFDF7);
  static const paperSunk = Color(0xFFEDE7D9);

  // Ink
  static const ink = Color(0xFF1B1917);
  static const inkSoft = Color(0xFF57514A);
  static const inkFaint = Color(0xFF8B8378);

  // Accents
  static const accent = Color(0xFFC8452B);
  static const accentSoft = Color(0xFFF6DDD6);
  static const ok = Color(0xFF2F6B46);
  static const okSoft = Color(0xFFDCEBE1);
  static const warn = Color(0xFF9A6408);
  static const warnSoft = Color(0xFFF6E9CD);
  static const info = Color(0xFF2B4B8C);
  static const infoSoft = Color(0xFFDBE3F4);

  // Domain colours, used consistently across every chart and badge.
  static const zone1 = Color(0xFF8B8378);
  static const zone2 = Color(0xFF2B4B8C);
  static const zone3 = Color(0xFF2F6B46);
  static const zone4 = Color(0xFF9A6408);
  static const zone5 = Color(0xFFC8452B);

  // Sleep stages: pine, denim, burnt orange, brick — the same four inks the
  // rest of the app is printed in, at the same muted saturation, so a night
  // reads as this app and not as a fitness tracker's neon.
  //
  // Ordered dark to light down the night's quality: deep is the darkest and
  // heaviest, awake the hot one. Awake stays off the exact accent red, which
  // means "hủy bỏ" everywhere else, and off the orange next to it in the bar.
  static const sleepAwake = Color(0xFFB84A32);
  static const sleepLight = Color(0xFFDD9145);
  static const sleepDeep = Color(0xFF2F6B4E);
  static const sleepRem = Color(0xFF3F6FA8);

  // Macro colours. One set for the whole app so a bar, a dot and a number that
  // mean "đạm" are never three different colours.
  static const carbs = Color(0xFFE0A33C);
  static const protein = Color(0xFFE2596E);
  static const fat = Color(0xFF4FA97A);

  // Second macro page. Sugar and sodium are limits rather than goals, so they
  // borrow the warning hues; fibre is a goal, so it stays green-ish.
  static const sugar = Color(0xFFD98BB5);
  static const sodium = Color(0xFF7FA1D8);
  static const fiber = Color(0xFF9BBE5A);

  // Water is the only non-food intake we draw, and it never shares a colour
  // with a macro.
  static const water = Color(0xFF4C9BD6);

  /// The single "add something" green. Only the floating action affordances
  /// use it, so a green circle always means "ghi thêm".
  static const action = Color(0xFF3E9B63);

  // Panels. The meal detail screen stacks its cards on these: paper, one shade
  // lighter than the page, so a readout still reads as part of the same app.
  static const panel = Color(0xFFFFFDF7);
  static const panelRaised = Color(0xFFEDE7D9);
  static const onPanel = ink;
  static const onPanelSoft = inkSoft;

  /// Hairlines and fills inside a panel: ink at low opacity, so they follow the
  /// panel colour instead of being a second, unrelated grey.
  static const panelLine = Color(0x1F1B1917);
  static const panelFill = Color(0x141B1917);

  // Geometry — big soft radii and thick borders, the same look the home
  // screen's cards set.
  static const radius = 4.0;
  static const border = 2.0;
  static const space = 4.0;

  // The soft card radius every screen shares with the home stack, plus the
  // pill used by bars and dots.
  static const radiusLg = 24.0;
  static const radiusPill = 999.0;

  static const shadow = BoxShadow(color: ink, offset: Offset(3, 3));
  static const shadowSm = BoxShadow(color: ink, offset: Offset(2, 2));

  static const zoneColors = [zone1, zone2, zone3, zone4, zone5];
}

/// The signature surface: thick border, hard (never blurred) offset shadow.
class RetroBox extends StatelessWidget {
  const RetroBox({
    super.key,
    required this.child,
    this.color = RetroTokens.paperRaised,
    this.padding = const EdgeInsets.all(12),
    this.shadow = true,
    this.borderColor = RetroTokens.ink,
    this.borderWidth = RetroTokens.border,
    this.onTap,
  });

  final Widget child;
  final Color color;
  final EdgeInsets padding;
  final bool shadow;

  /// The full-thickness ink border by default; a hairline (RetroTokens.panelLine)
  /// when the box sits nested inside another card, so the two borders read as
  /// surface and content rather than as a doubled frame.
  final Color borderColor;
  final double borderWidth;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final box = Container(
      padding: padding,
      // The big radius only shows if the children obey it too: a photo in a
      // zero-padding box would otherwise paint past the rounded corners.
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: color,
        border: Border.all(color: borderColor, width: borderWidth),
        borderRadius: BorderRadius.circular(RetroTokens.radiusLg),
        boxShadow: shadow ? const [RetroTokens.shadow] : null,
      ),
      child: child,
    );
    if (onTap == null) return box;
    return GestureDetector(onTap: onTap, child: box);
  }
}
