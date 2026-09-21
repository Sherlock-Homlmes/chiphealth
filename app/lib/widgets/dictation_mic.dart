import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:record/record.dart';

import '../core/theme/tokens.dart';

/// The mic that lives inside a text field, at its trailing edge.
///
/// One tap starts listening, the next stops and hands the clip over — the same
/// gesture in the assistant and in "ghi bữa ăn", so neither screen has its own
/// idea of how dictation works. While it listens it becomes a set of bars that
/// move with the voice, which is the only honest way to show that something is
/// being heard.
class DictationMicButton extends StatelessWidget {
  const DictationMicButton({
    super.key,
    required this.recording,
    required this.transcribing,
    required this.onTap,
    this.amplitudes,
    this.tooltip,
  });

  final bool recording;
  final bool transcribing;
  final VoidCallback? onTap;

  /// Live input level while recording; null falls back to a steady pulse.
  final Stream<Amplitude>? amplitudes;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    if (transcribing) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox(
          height: 18,
          width: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    final button = InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: SizedBox(
          height: 24,
          width: 24,
          child: recording
              ? VoiceBars(amplitudes: amplitudes)
              : const Icon(Icons.mic, size: 22, color: RetroTokens.inkSoft),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// Three bars that rise and fall with what the mic is hearing.
class VoiceBars extends StatefulWidget {
  const VoiceBars({super.key, this.amplitudes});

  final Stream<Amplitude>? amplitudes;

  @override
  State<VoiceBars> createState() => _VoiceBarsState();
}

class _VoiceBarsState extends State<VoiceBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();
  StreamSubscription<Amplitude>? _sub;

  /// 0..1. Starts mid-height so the bars never look frozen before the first
  /// reading arrives.
  double _level = 0.35;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(VoiceBars old) {
    super.didUpdateWidget(old);
    if (old.amplitudes != widget.amplitudes) {
      _sub?.cancel();
      _listen();
    }
  }

  void _listen() {
    _sub = widget.amplitudes?.listen((a) {
      // dBFS: 0 is as loud as the mic goes, and a quiet room sits below -45.
      final level = ((a.current + 45) / 45).clamp(0.0, 1.0);
      if (!mounted) return;
      // Eased towards the reading rather than snapped to it: raw amplitude
      // twitches enough to look like noise rather than a voice.
      setState(() => _level = _level * 0.45 + level * 0.55);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _pulse,
    builder: (context, _) => Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(width: 3),
          _Bar(height: _heightFor(i)),
        ],
      ],
    ),
  );

  /// The middle bar leads and the outer two trail it, so the three read as one
  /// voice rather than three meters.
  double _heightFor(int index) {
    final phase = _pulse.value * 2 * math.pi + index * 1.1;
    final wobble = 0.5 + 0.5 * math.sin(phase);
    final weight = index == 1 ? 1.0 : 0.72;
    return (5 + 17 * _level * weight * (0.55 + 0.45 * wobble)).clamp(4.0, 22.0);
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) => Container(
    width: 3,
    height: height,
    decoration: BoxDecoration(
      color: RetroTokens.accent,
      borderRadius: BorderRadius.circular(2),
    ),
  );
}
