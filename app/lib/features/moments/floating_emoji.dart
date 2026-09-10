import 'dart:math';

import 'package:flutter/material.dart';

/// How many copies rise from one tap, and how long the slowest one lives.
const _count = 6;
const _duration = Duration(milliseconds: 1400);

/// Sends a small flock of [emoji] drifting up from [origin].
///
/// The reaction itself is a round trip to the server and a row in a
/// conversation the user is not looking at, so without this a tap has no
/// visible answer at all. Drawn in the overlay rather than in the composer:
/// the emoji have to escape the row they came from.
void floatEmoji(BuildContext origin, String emoji) {
  final overlay = Overlay.maybeOf(origin);
  final box = origin.findRenderObject();
  if (overlay == null || box is! RenderBox || !box.hasSize) return;

  final start = box.localToGlobal(box.size.center(Offset.zero),
      ancestor: overlay.context.findRenderObject());

  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _FloatingEmoji(
      emoji: emoji,
      origin: start,
      onDone: () => entry.remove(),
    ),
  );
  overlay.insert(entry);
}

class _FloatingEmoji extends StatefulWidget {
  const _FloatingEmoji({
    required this.emoji,
    required this.origin,
    required this.onDone,
  });

  final String emoji;
  final Offset origin;
  final VoidCallback onDone;

  @override
  State<_FloatingEmoji> createState() => _FloatingEmojiState();
}

class _FloatingEmojiState extends State<_FloatingEmoji>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _duration,
  );

  /// Per-copy variation, drawn once: identical arcs read as one fat emoji
  /// rather than as a handful of them.
  late final List<_Drift> _drifts;

  @override
  void initState() {
    super.initState();
    final random = Random();
    _drifts = List.generate(
      _count,
      (i) => _Drift(
        // Staggered so they leave in a trickle, not a block.
        delay: i / (_count * 1.6),
        dx: (random.nextDouble() - 0.5) * 90,
        rise: 120 + random.nextDouble() * 90,
        scale: 0.7 + random.nextDouble() * 0.6,
        tilt: (random.nextDouble() - 0.5) * 0.6,
      ),
    );

    _controller.forward().whenComplete(widget.onDone);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (_, __) => Stack(
            children: [
              for (final drift in _drifts) _copy(drift),
            ],
          ),
        ),
      );

  Widget _copy(_Drift drift) {
    // Each copy runs its own clock inside the shared one.
    final t = ((_controller.value - drift.delay) / (1 - drift.delay))
        .clamp(0.0, 1.0);
    if (t == 0) return const SizedBox.shrink();

    // Out fast, in slow: the fade happens over the last third, so the rise is
    // still readable while it disappears.
    final opacity = t < 0.7 ? 1.0 : (1 - (t - 0.7) / 0.3);
    final eased = Curves.easeOutCubic.transform(t);

    return Positioned(
      left: widget.origin.dx - 12 + drift.dx * eased,
      top: widget.origin.dy - 12 - drift.rise * eased,
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Transform.rotate(
          angle: drift.tilt * eased,
          child: Transform.scale(
            scale: drift.scale,
            child: Text(widget.emoji, style: const TextStyle(fontSize: 24)),
          ),
        ),
      ),
    );
  }
}

class _Drift {
  const _Drift({
    required this.delay,
    required this.dx,
    required this.rise,
    required this.scale,
    required this.tilt,
  });

  final double delay;
  final double dx;
  final double rise;
  final double scale;
  final double tilt;
}
