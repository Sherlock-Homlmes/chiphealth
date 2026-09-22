import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import '../../core/l10n/gen/app_localizations.dart';

/// The reply arrives in one response, so the wait is shown as staged work
/// instead of a spinner: the labels tell the user what the coach is looking at,
/// which is also what it actually does (it reads their data, then answers).
class CoachThinkingIndicator extends StatefulWidget {
  const CoachThinkingIndicator({super.key});

  /// How many lines the indicator walks through; the lines themselves are
  /// localized, so the count is kept separately for the timer that advances
  /// them without a context.
  static const stageCount = 4;

  static List<String> stages(BuildContext context) => [
    AppL10n.of(context).dangDocDuLieuCuaBan,
    AppL10n.of(context).xemLaiBuaAnVaBuoi,
    AppL10n.of(context).doiChieuMucTieuVaBenh,
    AppL10n.of(context).dangSoanCauTraLoi,
  ];

  @override
  State<CoachThinkingIndicator> createState() => _CoachThinkingIndicatorState();
}

class _CoachThinkingIndicatorState extends State<CoachThinkingIndicator> {
  int _stage = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 1400), (_) {
      if (!mounted) return;
      // Hold on the last stage rather than looping: a loop reads as "stuck".
      setState(
        () => _stage = (_stage + 1).clamp(
          0,
          CoachThinkingIndicator.stageCount - 1,
        ),
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: RetroTokens.paperRaised,
          border: Border.all(color: RetroTokens.ink, width: RetroTokens.border),
          boxShadow: const [RetroTokens.shadowSm],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _BlinkingDots(),
            const SizedBox(width: 10),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Text(
                CoachThinkingIndicator.stages(context)[_stage],
                key: ValueKey(_stage),
                style: const TextStyle(
                  color: RetroTokens.inkSoft,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BlinkingDots extends StatefulWidget {
  const _BlinkingDots();

  @override
  State<_BlinkingDots> createState() => _BlinkingDotsState();
}

class _BlinkingDotsState extends State<_BlinkingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final active = (_controller.value * 3).floor() % 3;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++)
              Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.only(right: 3),
                color: i == active ? RetroTokens.accent : RetroTokens.paperSunk,
              ),
          ],
        );
      },
    );
  }
}
