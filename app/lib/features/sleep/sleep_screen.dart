import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/units.dart';
import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/retro_widgets.dart';
import 'night_recorder_screen.dart';

final sleepSessionsProvider = FutureProvider<List<SleepSession>>(
    (ref) => ref.watch(sleepRepositoryProvider).sessions());

class SleepScreen extends ConsumerWidget {
  const SleepScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final debt = ref.watch(sleepDebtProvider);
    final sessions = ref.watch(sleepSessionsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Giấc ngủ')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const NightRecorderScreen()),
        ),
        backgroundColor: RetroTokens.accent,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.bedtime),
        label: const Text('Ghi đêm nay'),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(sleepDebtProvider);
          ref.invalidate(sleepSessionsProvider);
        },
        child: PhoneFrame(
          child: ListView(
            children: [
              const SectionTitle('Nợ ngủ'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: asyncBody(
                  debt,
                  onRetry: () => ref.invalidate(sleepDebtProvider),
                  data: (d) => RetroBox(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text('${d.debtHours.toStringAsFixed(1)}h',
                                style: Theme.of(context).textTheme.titleLarge),
                            const SizedBox(width: 8),
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text('trong ${d.windowDays} ngày gần nhất',
                                  style: const TextStyle(
                                      color: RetroTokens.inkSoft)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        _DebtBars(
                            days: d.byDay, targetSeconds: d.targetSeconds),
                        const SizedBox(height: 8),
                        Text(
                          'Mục tiêu ${Units.hoursMinutes(d.targetSeconds)}/đêm. '
                          'Đêm không ghi nhận không tính vào nợ.',
                          style: const TextStyle(
                              fontSize: 12, color: RetroTokens.inkFaint),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SectionTitle('Các đêm gần đây'),
              asyncBody(
                sessions,
                emptyWhen: (list) => list.isEmpty,
                emptyText: 'Chưa có đêm nào được ghi.',
                data: (list) => Column(
                  children: [
                    for (final night in list)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: RetroBox(
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => _NightDetail(sessionId: night.id),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(night.localDate,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w700)),
                                  ),
                                  Text(
                                      Units.hoursMinutes(
                                          night.totalSleepSeconds),
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w700)),
                                ],
                              ),
                              const SizedBox(height: 6),
                              _StageBar(night: night),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 6,
                                children: [
                                  if (night.sleepScore != null)
                                    RetroChip('điểm ${night.sleepScore}'),
                                  RetroChip(
                                    night.source == 'health_sync'
                                        ? 'thiết bị đeo'
                                        : 'mic điện thoại',
                                    tone: night.stagesAreEstimated
                                        ? RetroTokens.warn
                                        : RetroTokens.ok,
                                  ),
                                  if (night.events.isNotEmpty)
                                    RetroChip(
                                        '${night.events.length} sự kiện âm thanh'),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 96),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One bar per night against the target line: shortfall red, surplus green.
///
/// The bars are drawn on a sunk paper strip with the target marked across it —
/// a bare row of coloured blocks left "nợ ngủ" as a number with an unrelated
/// picture under it, since nothing on the chart said where enough sleep was.
class _DebtBars extends StatelessWidget {
  const _DebtBars({required this.days, required this.targetSeconds});

  final List<SleepDebtDay> days;
  final int targetSeconds;

  /// Height of the target line inside the plot. Leaving room above it is the
  /// point: a night that beats the target has to have somewhere to grow.
  static const _plot = 56.0;
  static const _targetY = 38.0;

  static String _weekday(String localDate) {
    final date = DateTime.tryParse(localDate);
    if (date == null) return '';
    return const ['T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'CN'][date.weekday - 1];
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          height: _plot,
          decoration: BoxDecoration(
            color: RetroTokens.paperSunk,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                bottom: _targetY,
                child: const _TargetLine(),
              ),
              // The same 2px on the outside as between two bars: without it the
              // row sits 2px from the strip's edge and 4px from its neighbour,
              // which reads as the whole chart being nudged off-centre.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final day in days)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child:
                              _DebtBar(day: day, targetSeconds: targetSeconds),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Row(
            children: [
              for (final day in days)
                Expanded(
                  child: Text(
                    _weekday(day.localDate),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    style: const TextStyle(
                        fontSize: 9, color: RetroTokens.inkFaint, height: 1),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A dotted rule rather than a solid one: it has to read as a reference, not as
/// another bar lying on its side.
///
/// Painted rather than a row of fixed 3px dashes: that row could only fit whole
/// dashes, so it stopped short of the right-hand edge by up to a dash and left
/// the rule visibly off-centre against the strip.
class _TargetLine extends StatelessWidget {
  const _TargetLine();

  @override
  Widget build(BuildContext context) =>
      const SizedBox(height: 1, child: CustomPaint(painter: _DashPainter()));
}

class _DashPainter extends CustomPainter {
  const _DashPainter();

  @override
  void paint(Canvas canvas, Size size) {
    // Dash and gap are derived from the width so the last dash lands exactly on
    // the right edge, whatever the card is wide.
    final count = (size.width / 7).round().clamp(1, 200);
    final step = size.width / count;
    final dash = step * 0.55;
    final paint = Paint()
      ..color = RetroTokens.inkFaint
      ..strokeWidth = 1;
    for (var i = 0; i < count; i++) {
      final x = i * step;
      canvas.drawLine(Offset(x, 0.5), Offset(x + dash, 0.5), paint);
    }
  }

  @override
  bool shouldRepaint(_DashPainter oldDelegate) => false;
}

class _DebtBar extends StatelessWidget {
  const _DebtBar({required this.day, required this.targetSeconds});

  final SleepDebtDay day;
  final int targetSeconds;

  @override
  Widget build(BuildContext context) {
    // An un-recorded night is a gap in the chart, not a zero-hour night: it
    // gets a stub the same colour as the strip so the day still holds its slot.
    if (!day.hasData) {
      return const Align(
        alignment: Alignment.bottomCenter,
        child: _BarBody(height: 4, color: RetroTokens.panelFill),
      );
    }

    final ratio =
        targetSeconds <= 0 ? 0.0 : day.actualSleepSeconds / targetSeconds;
    final short = day.dailyDiffSeconds < 0;
    return Tooltip(
      message:
          '${day.localDate} · ${Units.hoursMinutes(day.actualSleepSeconds)}',
      child: Align(
        alignment: Alignment.bottomCenter,
        child: _BarBody(
          height: (ratio * _DebtBars._targetY).clamp(6.0, _DebtBars._plot),
          color: short ? RetroTokens.accent : RetroTokens.ok,
        ),
      ),
    );
  }
}

class _BarBody extends StatelessWidget {
  const _BarBody({required this.height, required this.color});

  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
      ),
    );
  }
}

/// Awake / light / deep / REM proportions — same colours as the hypnogram.
///
/// A bordered pill split by hairlines, with a legend under it: four flush
/// colour blocks 10px tall read as one muddy band and named none of the stages,
/// which is the only thing the row is there to say.
class _StageBar extends StatelessWidget {
  const _StageBar({required this.night});

  final SleepSession night;

  @override
  Widget build(BuildContext context) {
    final parts = <_Stage>[
      _Stage('Sâu', night.deepSeconds, RetroTokens.sleepDeep),
      _Stage('REM', night.remSeconds, RetroTokens.sleepRem),
      _Stage('Nông', night.lightSeconds, RetroTokens.sleepLight),
      _Stage('Thức', night.awakeSeconds, RetroTokens.sleepAwake),
    ].where((s) => s.seconds > 0).toList();

    if (parts.isEmpty) {
      return const Text('Không có dữ liệu giai đoạn',
          style: TextStyle(fontSize: 12, color: RetroTokens.inkFaint));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 14,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: RetroTokens.paperSunk,
            border: Border.all(color: RetroTokens.ink, width: 1.5),
            borderRadius: BorderRadius.circular(RetroTokens.radiusPill),
          ),
          // stretch, not the default centre: a childless ColoredBox takes
          // constraints.smallest, so under a loose cross axis every segment
          // lays out 0px tall and the pill renders empty.
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final part in parts) ...[
                // A hairline between neighbours: deep and REM are close enough
                // in value that they otherwise bleed into each other.
                if (part != parts.first)
                  const SizedBox(
                      width: 1.5, child: ColoredBox(color: RetroTokens.ink)),
                Expanded(
                  flex: part.seconds,
                  child: ColoredBox(color: part.color),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 6),
        // Even columns rather than a Wrap: with four labels of different
        // lengths the Wrap broke 3 + 1 and the stray fourth read as a mistake.
        Row(
          children: [
            for (final part in parts) ...[
              if (part != parts.first) const SizedBox(width: 6),
              Expanded(child: _StageLegend(stage: part)),
            ],
          ],
        ),
      ],
    );
  }
}

class _Stage {
  const _Stage(this.label, this.seconds, this.color);

  final String label;
  final int seconds;
  final Color color;
}

class _StageLegend extends StatelessWidget {
  const _StageLegend({required this.stage});

  final _Stage stage;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: stage.color,
            border: Border.all(color: RetroTokens.ink, width: 1),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            '${stage.label} ${Units.hoursMinutes(stage.seconds)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            style: const TextStyle(fontSize: 10, color: RetroTokens.inkSoft),
          ),
        ),
      ],
    );
  }
}

class _NightDetail extends ConsumerWidget {
  const _NightDetail({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final night = ref.watch(sleepSessionProvider(sessionId));

    return Scaffold(
      appBar: AppBar(title: const Text('Đêm')),
      body: PhoneFrame(
        child: asyncBody(
          night,
          data: (n) => ListView(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: RetroBox(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(Units.hoursMinutes(n.totalSleepSeconds),
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 8),
                      _Hypnogram(stages: n.stages),
                    ],
                  ),
                ),
              ),
              const SectionTitle('Ngáy / nói mớ'),
              if (n.events.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                      child: Text('Không ghi nhận sự kiện nào.',
                          style: TextStyle(color: RetroTokens.inkFaint))),
                ),
              for (final event in n.events)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: RetroBox(
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  '${_eventLabel(event.eventType)} · '
                                  '${Units.timeOfDay(event.occurredAt)}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                              if (event.transcript != null)
                                Text('“${event.transcript}”',
                                    style: const TextStyle(
                                        fontSize: 12,
                                        color: RetroTokens.inkSoft)),
                              if (event.stageAtEvent != null)
                                Text('trong giai đoạn ${event.stageAtEvent}',
                                    style: const TextStyle(
                                        fontSize: 11,
                                        color: RetroTokens.inkFaint)),
                            ],
                          ),
                        ),
                        if (event.audioAssetId != null)
                          IconButton(
                            icon: const Icon(Icons.play_arrow),
                            // Clips are kept indefinitely; playback wiring is in the README.
                            onPressed: () =>
                                ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text(
                                      'Phát clip — cần just_audio wiring')),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}

String _eventLabel(String type) => switch (type) {
      'snore' => 'Ngáy',
      'sleep_talk' => 'Nói mớ',
      'cough' => 'Ho',
      'movement' => 'Cựa quậy',
      'apnea_suspect' => 'Nghi ngưng thở',
      _ => 'Khác',
    };

/// Full-night stage timeline in the four standard stages.
class _Hypnogram extends StatelessWidget {
  const _Hypnogram({required this.stages});

  final List<SleepStageSegment> stages;

  static const _order = ['awake', 'rem', 'light', 'deep'];

  /// The axis is labelled the way the legend on the previous screen is: the
  /// list card says "Nông", so the chart it opens cannot say "light".
  static const _labels = {
    'awake': 'Thức',
    'rem': 'REM',
    'light': 'Nông',
    'deep': 'Sâu',
  };

  @override
  Widget build(BuildContext context) {
    if (stages.isEmpty) {
      return const Text('Không có dữ liệu giai đoạn',
          style: TextStyle(color: RetroTokens.inkFaint));
    }
    return SizedBox(
      height: 96,
      child: Column(
        children: [
          for (final stage in _order)
            Expanded(
              child: Row(
                children: [
                  SizedBox(
                    width: 44,
                    child: Text(_labels[stage] ?? stage,
                        style: Theme.of(context).textTheme.labelSmall),
                  ),
                  Expanded(
                    child: Row(
                      children: [
                        for (final segment in stages)
                          Expanded(
                            flex: segment.seconds.clamp(1, 1 << 30),
                            child: Container(
                              color: segment.stage == stage
                                  ? _colorFor(stage)
                                  : Colors.transparent,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static Color _colorFor(String stage) => switch (stage) {
        'awake' => RetroTokens.sleepAwake,
        'light' => RetroTokens.sleepLight,
        'deep' => RetroTokens.sleepDeep,
        _ => RetroTokens.sleepRem,
      };
}
