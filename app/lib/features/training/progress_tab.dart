import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../core/format/units.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/retro_widgets.dart';
import '../home/home_widgets.dart';
import 'activity_format.dart';

/// The "Tiến trình" tab of the activity screen: where the training is going,
/// as opposed to the feed next door, which is what happened.
///
/// Two calls fill it. [trainingProgressProvider] answers eight of the nine
/// cards from one scan of the sessions; [trainingWeeksProvider] answers the
/// twelve-week chart alone, because the sport chips are the only control on
/// the page and the chart is the only thing they move. Every card renders its
/// own loading and error state, so one slow or broken card never blanks the
/// page.
class TrainingProgressTab extends ConsumerWidget {
  const TrainingProgressTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(trainingProgressProvider);

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(trainingProgressProvider);
        ref.invalidate(trainingWeeksProvider);
      },
      child: PhoneFrame(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            _FocusCard(progress: progress),
            const SizedBox(height: 12),
            const _MainProgressCard(),
            const SizedBox(height: 12),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _StreakCard(progress: progress)),
                  const SizedBox(width: 12),
                  Expanded(child: _LogCard(progress: progress)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _SuggestionCard(progress: progress),
            const SizedBox(height: 12),
            _PredictionCard(progress: progress),
            const SizedBox(height: 12),
            _ZonesCard(progress: progress),
            const SizedBox(height: 12),
            _RecordsCard(progress: progress),
            const SizedBox(height: 12),
            _MonthlyCard(progress: progress),
          ],
        ),
      ),
    );
  }
}

/* -------------------------------------------------------------------------- */
/* Formatting                                                                  */
/* -------------------------------------------------------------------------- */

/// "1giờ 22phút" / "23phút 14giây" — the shape the cards are read in, which is
/// not the "1h 22m" the feed uses.
String _duration(BuildContext context, int seconds) {
  final l = AppL10n.of(context);
  if (seconds >= 3600) {
    return l.durationHourMinute(seconds ~/ 3600, (seconds % 3600) ~/ 60);
  }
  if (seconds >= 60) {
    final rest = seconds % 60;
    return rest == 0
        ? l.durationMinuteOnly(seconds ~/ 60)
        : l.durationMinuteSecond(seconds ~/ 60, rest);
  }
  return Units.duration(seconds);
}

/// A race time: "35:15", or "1:20:14" once it passes the hour.
String _clock(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

String _language(BuildContext context) =>
    Localizations.localeOf(context).languageCode;

/// "10 km" / "2 dặm" for a record's distance — whole units, no trailing zeros.
String _roundDistance(Units units, double meters) {
  if (units.isImperial) {
    final miles = meters / 1609.344;
    final text = miles >= 10 || miles == miles.roundToDouble()
        ? miles.round().toString()
        : miles.toStringAsFixed(1);
    return '$text mi';
  }
  final km = meters / 1000;
  final text = km == km.roundToDouble()
      ? km.round().toString()
      : km.toStringAsFixed(km >= 10 ? 1 : 2);
  return '$text km';
}

/* -------------------------------------------------------------------------- */
/* Card chrome                                                                 */
/* -------------------------------------------------------------------------- */

/// Every card on the tab: icon, bold title, an optional period on the right,
/// and a ">" when the whole card opens something.
class _ProgressCard extends StatelessWidget {
  const _ProgressCard({
    required this.icon,
    required this.title,
    required this.child,
    this.scope,
    this.onOpen,
  });

  final IconData icon;
  final String title;
  final Widget child;

  /// "Tuần này", "Trong 1 tháng qua" — the period the card covers.
  final String? scope;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final card = HomeCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: RetroTokens.inkSoft),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (scope != null)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Text(
                    scope!,
                    style: const TextStyle(
                      fontSize: 12,
                      color: RetroTokens.inkFaint,
                    ),
                  ),
                ),
              if (onOpen != null)
                const Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: RetroTokens.inkFaint,
                ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
    if (onOpen == null) return card;
    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(RetroTokens.radiusLg),
      child: card,
    );
  }
}

/// Grey blocks while a card's data is in flight — the card keeps its size
/// instead of the page jumping when the numbers land.
class _Skeleton extends StatelessWidget {
  const _Skeleton({this.height = 72});

  final double height;

  @override
  Widget build(BuildContext context) => Container(
    height: height,
    decoration: BoxDecoration(
      color: RetroTokens.paperSunk,
      borderRadius: BorderRadius.circular(6),
    ),
  );
}

/// One card failed; the rest of the page is fine, so the retry lives here.
class _CardError extends StatelessWidget {
  const _CardError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const Icon(Icons.error_outline, size: 18, color: RetroTokens.accent),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          AppL10n.of(context).chuaCoDuLieu,
          style: const TextStyle(fontSize: 12, color: RetroTokens.inkSoft),
        ),
      ),
      TextButton(onPressed: onRetry, child: Text(AppL10n.of(context).thuLai)),
    ],
  );
}

/// The body of a card, once its data is in. Loading and failure are drawn the
/// same way on every card so a broken one is recognisable at a glance.
Widget _cardBody<T>(
  AsyncValue<T> value, {
  required Widget Function(T data) data,
  required VoidCallback onRetry,
  double skeletonHeight = 72,
}) => value.when(
  loading: () => _Skeleton(height: skeletonHeight),
  error: (_, __) => _CardError(onRetry: onRetry),
  data: data,
);

/// A big number with its caption above it, the layout every figure on the tab
/// shares.
class _Figure extends StatelessWidget {
  const _Figure({
    required this.label,
    required this.value,
    this.fontSize = _figureMaxFontSize,
  });

  final String label;
  final String value;

  /// Set by [_FigureRow] so every figure in a row is the same size. On its own
  /// a figure takes the full size and shrinks to fit if it has to.
  final double fontSize;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        label,
        style: const TextStyle(fontSize: 11, color: RetroTokens.inkSoft),
        overflow: TextOverflow.ellipsis,
      ),
      const SizedBox(height: 2),
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(
          value,
          maxLines: 1,
          softWrap: false,
          style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w800),
        ),
      ),
    ],
  );
}

const _figureMaxFontSize = 20.0;
const _figureMinFontSize = 13.0;

/// Three figures across a card, all at the same size.
///
/// Each figure used to shrink itself to fit its own column, which on a phone
/// meant "12,34 km" and "412 m" stayed at full size while a week holding
/// "10giờ 55phút" — twelve characters, because Vietnamese spends four on what
/// English spends one — was scaled to about two thirds and read as the runt of
/// the row. Three columns pressed together with no gutter made it worse.
///
/// So the row picks ONE size: the largest at which every value still fits its
/// column, measured rather than guessed, with a floor under how small it will
/// go (past that the [FittedBox] inside each figure takes over, which at least
/// keeps the number on screen). Equal size is the point — the eye reads the
/// three as one row of facts, and nothing looks demoted.
class _FigureRow extends StatelessWidget {
  const _FigureRow({required this.figures});

  /// Label and value, in the order they are shown.
  final List<({String label, String value})> figures;

  static const _gutter = 10.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columnWidth =
          (constraints.maxWidth - _gutter * (figures.length - 1)) /
          figures.length;
      final scale = MediaQuery.textScalerOf(context);
      var size = _figureMaxFontSize;
      while (size > _figureMinFontSize) {
        final fits = figures.every(
          (f) => _widthOf(f.value, size, scale) <= columnWidth,
        );
        if (fits) break;
        size -= 1;
      }

      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < figures.length; i++) ...[
            if (i > 0) const SizedBox(width: _gutter),
            Expanded(
              child: _Figure(
                label: figures[i].label,
                value: figures[i].value,
                fontSize: size,
              ),
            ),
          ],
        ],
      );
    },
  );

  static double _widthOf(String value, double size, TextScaler scale) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(fontSize: size, fontWeight: FontWeight.w800),
      ),
      textDirection: TextDirection.ltr,
      textScaler: scale,
    )..layout();
    return painter.width;
  }
}

/// The "▼ 2:50" / "▲ 19%" badge next to a headline figure.
class _DeltaBadge extends StatelessWidget {
  const _DeltaBadge({
    required this.text,
    required this.down,
    required this.tone,
  });

  final String text;
  final bool down;
  final Color tone;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: tone.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          down ? Icons.arrow_downward : Icons.arrow_upward,
          size: 12,
          color: tone,
        ),
        const SizedBox(width: 2),
        Text(
          text,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: tone,
          ),
        ),
      ],
    ),
  );
}

/* -------------------------------------------------------------------------- */
/* The detail screen behind every ">"                                          */
/* -------------------------------------------------------------------------- */

/// What a card means and how its number was reached. A card that can be
/// misread — a prediction, a zone share, a streak — is worth one screen that
/// says where the figure came from, which is more use than a placeholder.
class _ExplainScreen extends StatelessWidget {
  const _ExplainScreen({
    required this.title,
    required this.explanation,
    this.rows = const [],
    this.child,
  });

  final String title;
  final String explanation;

  /// Label / value pairs, shown above the explanation.
  final List<(String, String)> rows;
  final Widget? child;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: PhoneFrame(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          if (child != null) ...[child!, const SizedBox(height: 16)],
          if (rows.isNotEmpty) ...[
            HomeCard(
              child: Column(
                children: [
                  for (final (label, value) in rows)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              label,
                              style: const TextStyle(
                                fontSize: 13,
                                color: RetroTokens.inkSoft,
                              ),
                            ),
                          ),
                          Text(
                            value,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
          SectionTitle(AppL10n.of(context).cachTinh),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              explanation,
              style: const TextStyle(
                fontSize: 13,
                height: 1.5,
                color: RetroTokens.inkSoft,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

void _explain(
  BuildContext context, {
  required String title,
  required String explanation,
  List<(String, String)> rows = const [],
  Widget? child,
}) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _ExplainScreen(
        title: title,
        explanation: explanation,
        rows: rows,
        child: child,
      ),
    ),
  );
}

/* -------------------------------------------------------------------------- */
/* 1. Trọng tâm của bạn                                                        */
/* -------------------------------------------------------------------------- */

const _focusCodes = [
  'improve_fitness',
  'event_training',
  'stay_active',
  'recovery',
];

({String label, String note}) _focusText(BuildContext context, String code) {
  final l = AppL10n.of(context);
  return switch (code) {
    'improve_fitness' => (
      label: l.focusImproveFitness,
      note: l.focusImproveFitnessNote,
    ),
    'event_training' => (
      label: l.focusEventTraining,
      note: l.focusEventTrainingNote,
    ),
    'recovery' => (label: l.focusRecovery, note: l.focusRecoveryNote),
    _ => (label: l.focusStayActive, note: l.focusStayActiveNote),
  };
}

/// What the athlete is training for right now. It is not a goal — no target,
/// no deadline — but it is the line the coach reads before it answers, so it
/// is stored on the profile rather than kept on the device.
class _FocusCard extends ConsumerWidget {
  const _FocusCard({required this.progress});

  final AsyncValue<TrainingProgress> progress;

  Future<void> _pick(
    BuildContext context,
    WidgetRef ref,
    String current,
  ) async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Text(
                    AppL10n.of(context).chonTrongTam,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            for (final code in _focusCodes)
              ListTile(
                leading: Icon(
                  code == current
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: code == current
                      ? RetroTokens.accent
                      : RetroTokens.inkFaint,
                ),
                title: Text(_focusText(context, code).label),
                subtitle: Text(_focusText(context, code).note),
                onTap: () => Navigator.of(sheet).pop(code),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (chosen == null || chosen == current) return;
    try {
      await ref.read(profileRepositoryProvider).patchProfile({
        'trainingFocus': chosen,
      });
      ref.invalidate(trainingProgressProvider);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  /// A one-line strip rather than a full card: the focus is a setting the user
  /// picks once and then reads at a glance, so it introduces the page instead
  /// of competing with the numbers under it. The description that used to sit
  /// here lives in the picker, next to each option, which is where it is
  /// actually being decided.
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final current = progress.valueOrNull?.focus ?? 'stay_active';
    final loading = progress.isLoading && !progress.hasValue;

    return HomeCard(
      padding: EdgeInsets.zero,
      child: InkWell(
        onTap: () => _pick(context, ref, current),
        borderRadius: BorderRadius.circular(RetroTokens.radiusLg),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Row(
            children: [
              const Icon(
                Icons.flag_outlined,
                size: 16,
                color: RetroTokens.inkSoft,
              ),
              const SizedBox(width: 6),
              Text(
                l.trongTamCuaBan,
                style: const TextStyle(
                  fontSize: 13,
                  color: RetroTokens.inkSoft,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: loading
                    ? const _Skeleton(height: 16)
                    : Text(
                        _focusText(context, current).label,
                        textAlign: TextAlign.end,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.edit_outlined,
                size: 16,
                color: RetroTokens.inkFaint,
                semanticLabel: l.chinhSuaTrongTam,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/* -------------------------------------------------------------------------- */
/* 2. Tiến trình chính                                                         */
/* -------------------------------------------------------------------------- */

/// How many sports get their own chip before the rest fold into a menu.
const _visibleSportChips = 3;

class _MainProgressCard extends ConsumerStatefulWidget {
  const _MainProgressCard();

  @override
  ConsumerState<_MainProgressCard> createState() => _MainProgressCardState();
}

class _MainProgressCardState extends ConsumerState<_MainProgressCard> {
  String _sport = 'all';

  /// Index into the twelve weeks; null follows the last one, so the card keeps
  /// showing "this week" as the weeks roll over.
  int? _selected;

  String _sportLabel(Map<String, ActivityType> types, String code) =>
      code == 'all'
      ? AppL10n.of(context).tatCaCacMonTheThao
      : types[code]?.name ?? code;

  void _selectSport(String code) => setState(() {
    _sport = code;
    // The new sport has its own twelve weeks; holding an index into the old
    // ones would leave the figures describing a week the user did not pick.
    _selected = null;
  });

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final units = Units(ref.watch(unitSystemProvider));
    final progress = ref.watch(trainingProgressProvider);
    final weeks = ref.watch(trainingWeeksProvider(_sport));
    final types = {
      for (final t
          in ref.watch(activityTypesProvider).valueOrNull ??
              const <ActivityType>[])
        t.code: t,
    };
    final sports = progress.valueOrNull?.sports ?? const <SportChip>[];

    return HomeCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sportChips(sports, types),
          const SizedBox(height: 16),
          _cardBody(
            weeks,
            skeletonHeight: 260,
            onRetry: () => ref.invalidate(trainingWeeksProvider(_sport)),
            data: (series) => _weeks(context, l, units, series),
          ),
        ],
      ),
    );
  }

  Widget _sportChips(List<SportChip> sports, Map<String, ActivityType> types) {
    final visible = sports.take(_visibleSportChips).map((s) => s.code).toList();
    final overflow = sports
        .skip(_visibleSportChips)
        .map((s) => s.code)
        .toList();
    // A sport picked from the menu takes a chip of its own, so the row always
    // shows what is selected.
    if (overflow.contains(_sport)) {
      visible.add(_sport);
      overflow.remove(_sport);
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final code in ['all', ...visible]) ...[
            _SportChip(
              label: _sportLabel(types, code),
              icon: code == 'all' ? Icons.all_inclusive : activityIcon(code),
              selected: _sport == code,
              onTap: () => _selectSport(code),
            ),
            const SizedBox(width: 8),
          ],
          if (overflow.isNotEmpty)
            PopupMenuButton<String>(
              onSelected: _selectSport,
              itemBuilder: (_) => [
                for (final code in overflow)
                  PopupMenuItem(
                    value: code,
                    child: Row(
                      children: [
                        Icon(activityIcon(code), size: 16),
                        const SizedBox(width: 8),
                        Text(_sportLabel(types, code)),
                      ],
                    ),
                  ),
              ],
              child: _SportChip(
                label: AppL10n.of(context).monKhac,
                icon: Icons.more_horiz,
                selected: false,
                onTap: null,
              ),
            ),
        ],
      ),
    );
  }

  Widget _weeks(
    BuildContext context,
    AppL10n l,
    Units units,
    WeekSeries series,
  ) {
    if (series.weeks.isEmpty) return const ChartHint();
    final index = (_selected ?? series.weeks.length - 1).clamp(
      0,
      series.weeks.length - 1,
    );
    final week = series.weeks[index];
    final isCurrent = index == series.weeks.length - 1;
    final language = _language(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isCurrent
              ? l.tuanNay
              : '${DateFormat('d', language).format(DateTime.parse(week.weekStart))}'
                    ' – '
                    '${DateFormat('d MMM', language).format(DateTime.parse(week.weekEnd))}',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        _FigureRow(
          figures: [
            (
              label: l.quangDuong,
              value: units.distanceExact(week.distanceM, language),
            ),
            (label: l.thoiGian, value: _duration(context, week.movingSeconds)),
            (
              label: l.doCaoTang,
              value: units.isImperial
                  ? '${(week.elevationGainM * 3.28084).round()} ft'
                  : '${week.elevationGainM.round()} m',
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          l.nTuanQua(series.weeks.length),
          style: const TextStyle(fontSize: 12, color: RetroTokens.inkSoft),
        ),
        const SizedBox(height: 8),
        WeeksChart(
          weeks: series.weeks,
          selected: index,
          units: units,
          onSelect: (i) => setState(() => _selected = i),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: () => _explain(
              context,
              title: l.tienTrinh,
              explanation: l.explainMainProgress,
              rows: [
                for (final w in series.weeks.reversed)
                  (
                    '${DateFormat('d/M', language).format(DateTime.parse(w.weekStart))}'
                        ' – '
                        '${DateFormat('d/M', language).format(DateTime.parse(w.weekEnd))}',
                    units.distanceExact(w.distanceM, language),
                  ),
              ],
            ),
            child: Text(l.xemThemTienTrinhCuaBan),
          ),
        ),
      ],
    );
  }
}

class _SportChip extends StatelessWidget {
  const _SportChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(20),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: selected ? RetroTokens.accentSoft : RetroTokens.paper,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: selected ? RetroTokens.accent : RetroTokens.paperSunk,
          width: selected ? 2 : 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 15,
            color: selected ? RetroTokens.accent : RetroTokens.inkSoft,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? RetroTokens.accent : RetroTokens.inkSoft,
            ),
          ),
        ],
      ),
    ),
  );
}

/// The "nothing here yet" body a chart falls back to.
class ChartHint extends StatelessWidget {
  const ChartHint({super.key, this.height = 120, this.text});

  final double height;
  final String? text;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: Center(
      child: Text(
        text ?? AppL10n.of(context).chuaCoDuLieuTrongKy,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12, color: RetroTokens.inkFaint),
      ),
    ),
  );
}

/* -------------------------------------------------------------------------- */
/* The twelve-week chart                                                       */
/* -------------------------------------------------------------------------- */

/// Distance per week: a line with a filled area under it, one hollow dot per
/// week, and a marker on the week being read. Dragging across it snaps the
/// marker to the nearest week and the three figures above update with it.
///
/// Hand-painted rather than a chart package: the axis lives on the right, the
/// bottom labels name months rather than points, and the marker is a line plus
/// a halo — three things that would each be a fight with a generic chart.
class WeeksChart extends StatelessWidget {
  const WeeksChart({
    super.key,
    required this.weeks,
    required this.selected,
    required this.units,
    required this.onSelect,
    this.height = 190,
  });

  final List<WeekBucket> weeks;
  final int selected;
  final Units units;
  final ValueChanged<int> onSelect;
  final double height;

  static const _rightAxis = 44.0;
  static const _bottomLabels = 22.0;
  static const _topPad = 10.0;
  static const _leftPad = 4.0;

  static double _step(double width, int count) =>
      count < 2 ? 0 : (width - _rightAxis - _leftPad * 2) / (count - 1);

  int _indexAt(double dx, double width) {
    final step = _step(width, weeks.length);
    if (step <= 0) return 0;
    return ((dx - _leftPad) / step).round().clamp(0, weeks.length - 1);
  }

  @override
  Widget build(BuildContext context) {
    final language = _language(context);
    final values = [
      for (final w in weeks)
        units.isImperial ? w.distanceM / 1609.344 : w.distanceM / 1000,
    ];

    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => onSelect(_indexAt(d.localPosition.dx, width)),
            onHorizontalDragStart: (d) =>
                onSelect(_indexAt(d.localPosition.dx, width)),
            onHorizontalDragUpdate: (d) =>
                onSelect(_indexAt(d.localPosition.dx, width)),
            child: CustomPaint(
              size: Size(width, height),
              painter: _WeeksPainter(
                values: values,
                weekStarts: [for (final w in weeks) w.weekStart],
                selected: selected,
                unit: units.isImperial ? 'mi' : 'km',
                monthLabel: (month) =>
                    DateFormat('MMM', language).format(month).toUpperCase(),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _WeeksPainter extends CustomPainter {
  _WeeksPainter({
    required this.values,
    required this.weekStarts,
    required this.selected,
    required this.unit,
    required this.monthLabel,
  });

  final List<double> values;
  final List<String> weekStarts;
  final int selected;
  final String unit;
  final String Function(DateTime month) monthLabel;

  /// The axis top, rounded up to something a label can read cleanly. An empty
  /// period still gets a scale so the zero line is not the only thing drawn.
  double get _max {
    final peak = values.isEmpty ? 0.0 : values.reduce(math.max);
    if (peak <= 0) return 4;
    final rounded = (peak * 1.15 / 2).ceilToDouble() * 2;
    return rounded <= 0 ? 4 : rounded;
  }

  void _text(
    Canvas canvas,
    String text,
    Offset at, {
    Color color = RetroTokens.inkFaint,
    double size = 10,
    bool rightAlign = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: size, color: color),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      Offset(rightAlign ? at.dx - painter.width : at.dx, at.dy),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final plotRight = size.width - WeeksChart._rightAxis;
    final plotBottom = size.height - WeeksChart._bottomLabels;
    final top = WeeksChart._topPad;
    final step = WeeksChart._step(size.width, values.length);
    final max = _max;

    double x(int i) => WeeksChart._leftPad + i * step;
    double y(double value) =>
        plotBottom - (value / max).clamp(0, 1) * (plotBottom - top);

    // Three gridlines, labelled on the right: 0, half, full.
    final grid = Paint()
      ..color = RetroTokens.paperSunk
      ..strokeWidth = 1;
    for (final level in [0.0, max / 2, max]) {
      final gy = y(level);
      canvas.drawLine(Offset(0, gy), Offset(plotRight, gy), grid);
      _text(
        canvas,
        level == max ? '${level.round()} $unit' : level.round().toString(),
        Offset(plotRight + 6, gy - 6),
      );
    }

    final line = Path();
    for (var i = 0; i < values.length; i++) {
      final point = Offset(x(i), y(values[i]));
      i == 0
          ? line.moveTo(point.dx, point.dy)
          : line.lineTo(point.dx, point.dy);
    }

    // The filled area is the same path closed along the zero line.
    final area = Path.from(line)
      ..lineTo(x(values.length - 1), y(0))
      ..lineTo(x(0), y(0))
      ..close();
    canvas.drawPath(
      area,
      Paint()..color = RetroTokens.accent.withValues(alpha: 0.12),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = RetroTokens.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // The marker: a line down the whole plot, then a filled dot with a halo.
    final markerX = x(selected.clamp(0, values.length - 1));
    canvas.drawLine(
      Offset(markerX, top),
      Offset(markerX, plotBottom),
      Paint()
        ..color = RetroTokens.inkFaint
        ..strokeWidth = 1,
    );

    for (var i = 0; i < values.length; i++) {
      final point = Offset(x(i), y(values[i]));
      if (i == selected) continue;
      canvas
        ..drawCircle(point, 3.5, Paint()..color = RetroTokens.paperRaised)
        ..drawCircle(
          point,
          3.5,
          Paint()
            ..color = RetroTokens.accent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
    }
    final marker = Offset(
      markerX,
      y(values[selected.clamp(0, values.length - 1)]),
    );
    canvas
      ..drawCircle(
        marker,
        8,
        Paint()..color = RetroTokens.accent.withValues(alpha: 0.25),
      )
      ..drawCircle(marker, 4.5, Paint()..color = RetroTokens.accent);

    // Bottom axis: a label where a new month starts, not one per point.
    String? previous;
    for (var i = 0; i < weekStarts.length; i++) {
      if (weekStarts[i].isEmpty) continue;
      final date = DateTime.parse(weekStarts[i]);
      final key = '${date.year}-${date.month}';
      if (key == previous) continue;
      previous = key;
      _text(canvas, monthLabel(date), Offset(x(i) - 10, plotBottom + 6));
    }
  }

  @override
  bool shouldRepaint(_WeeksPainter old) =>
      old.selected != selected ||
      old.values.length != values.length ||
      !identical(old.values, values);
}

/* -------------------------------------------------------------------------- */
/* 3. Chuỗi liên tiếp + Nhật ký tập luyện                                      */
/* -------------------------------------------------------------------------- */

class _StreakCard extends ConsumerWidget {
  const _StreakCard({required this.progress});

  final AsyncValue<TrainingProgress> progress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    return _ProgressCard(
      icon: Icons.local_fire_department_outlined,
      title: l.chuoiLienTiep,
      onOpen: () => _explain(
        context,
        title: l.chuoiLienTiep,
        explanation: l.explainStreak,
        rows: [
          (
            l.chuoiLienTiep,
            '${progress.valueOrNull?.streakWeeks ?? 0} ${l.tuan.toLowerCase()}',
          ),
        ],
      ),
      child: _cardBody(
        progress,
        skeletonHeight: 96,
        onRetry: () => ref.invalidate(trainingProgressProvider),
        data: (p) => Center(
          child: Column(
            children: [
              SizedBox(
                height: 64,
                width: 64,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    const Icon(
                      Icons.local_fire_department,
                      size: 64,
                      color: RetroTokens.accentSoft,
                    ),
                    Padding(
                      // The flame's visual centre sits below its bounding box
                      // centre; without the nudge the number rides the tip.
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        '${p.streakWeeks}',
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          color: RetroTokens.accent,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                l.tuan,
                style: const TextStyle(
                  fontSize: 12,
                  color: RetroTokens.inkSoft,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LogCard extends ConsumerWidget {
  const _LogCard({required this.progress});

  final AsyncValue<TrainingProgress> progress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    return _ProgressCard(
      icon: Icons.calendar_today_outlined,
      title: l.nhatKyTapLuyen,
      onOpen: () => _explain(
        context,
        title: l.nhatKyTapLuyen,
        explanation: l.explainLog,
        rows: [
          (
            l.tuanNay,
            _duration(
              context,
              progress.valueOrNull?.thisWeek.totalSeconds ?? 0,
            ),
          ),
          (
            l.tuanTruoc,
            _duration(
              context,
              progress.valueOrNull?.lastWeek.totalSeconds ?? 0,
            ),
          ),
        ],
      ),
      child: _cardBody(
        progress,
        skeletonHeight: 96,
        onRetry: () => ref.invalidate(trainingProgressProvider),
        data: (p) {
          // One scale for both rows, so a long day last week is visibly bigger
          // than a short one this week rather than each row scaling itself.
          final peak = [
            ...p.thisWeek.days.map((d) => d.seconds),
            ...p.lastWeek.days.map((d) => d.seconds),
            1,
          ].reduce(math.max);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _LogRow(week: p.thisWeek, label: l.tuanNay, peak: peak),
              const SizedBox(height: 12),
              _LogRow(week: p.lastWeek, label: l.tuanTruoc, peak: peak),
            ],
          );
        },
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.week, required this.label, required this.peak});

  final LogWeek week;
  final String label;
  final int peak;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        height: 20,
        child: Row(
          children: [
            for (final day in week.days)
              Expanded(
                child: Center(
                  child: Container(
                    width: _dotSize(day.seconds),
                    height: _dotSize(day.seconds),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: day.seconds > 0
                          ? RetroTokens.accent
                          : RetroTokens.paperSunk,
                    ),
                  ),
                ),
              ),
            // Days the week has not reached yet keep their space, so the two
            // rows stay aligned under each other.
            for (var i = week.days.length; i < 7; i++) const Spacer(),
          ],
        ),
      ),
      const SizedBox(height: 4),
      Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 11, color: RetroTokens.inkSoft),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            _duration(context, week.totalSeconds),
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    ],
  );

  double _dotSize(int seconds) =>
      seconds <= 0 ? 6 : 8 + 8 * (seconds / peak).clamp(0.0, 1.0);
}

/* -------------------------------------------------------------------------- */
/* 4. Buổi tập tức thì                                                         */
/* -------------------------------------------------------------------------- */

({String name, String note}) _suggestionText(
  BuildContext context,
  String code,
) {
  final l = AppL10n.of(context);
  return switch (code) {
    'recovery_run' => (
      name: l.suggestRecoveryRun,
      note: l.suggestRecoveryRunNote,
    ),
    'base_run' => (name: l.suggestBaseRun, note: l.suggestBaseRunNote),
    'tempo_run' => (name: l.suggestTempoRun, note: l.suggestTempoRunNote),
    'long_run' => (name: l.suggestLongRun, note: l.suggestLongRunNote),
    _ => (name: l.suggestFirstRun, note: l.suggestFirstRunNote),
  };
}

class _SuggestionCard extends ConsumerWidget {
  const _SuggestionCard({required this.progress});

  final AsyncValue<TrainingProgress> progress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final units = Units(ref.watch(unitSystemProvider));
    final suggestion = progress.valueOrNull?.suggestion;

    return _ProgressCard(
      icon: Icons.bolt_outlined,
      title: l.buoiTapTucThi,
      scope: l.tuanNay,
      onOpen: suggestion == null
          ? null
          : () => _explain(
              context,
              title: _suggestionText(context, suggestion.code).name,
              explanation: l.explainSuggestion,
              rows: [
                (l.quangDuong, _roundDistance(units, suggestion.distanceM)),
              ],
              child: HomeCard(
                child: Text(
                  _suggestionText(context, suggestion.code).note,
                  style: const TextStyle(fontSize: 13, height: 1.5),
                ),
              ),
            ),
      child: _cardBody(
        progress,
        skeletonHeight: 80,
        onRetry: () => ref.invalidate(trainingProgressProvider),
        data: (p) {
          final text = _suggestionText(context, p.suggestion.code);
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  color: RetroTokens.paperSunk,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.directions_run,
                      size: 28,
                      color: RetroTokens.inkSoft,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _roundDistance(units, p.suggestion.distanceM),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      text.name,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      text.note,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: RetroTokens.inkSoft,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/* -------------------------------------------------------------------------- */
/* 5. Dự đoán hiệu suất                                                        */
/* -------------------------------------------------------------------------- */

class _PredictionCard extends ConsumerWidget {
  const _PredictionCard({required this.progress});

  final AsyncValue<TrainingProgress> progress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final units = Units(ref.watch(unitSystemProvider));
    final prediction = progress.valueOrNull?.prediction;

    return _ProgressCard(
      icon: Icons.speed_outlined,
      title: l.duDoanHieuSuat,
      scope: l.trong1ThangQua,
      onOpen: () => _explain(
        context,
        title: l.duDoanHieuSuat,
        explanation: l.explainPrediction,
        rows: prediction == null
            ? const []
            : [
                (
                  _roundDistance(units, prediction.distanceM),
                  _clock(prediction.currentSeconds),
                ),
                (l.trong1ThangQua, _clock(prediction.baselineSeconds)),
              ],
      ),
      child: _cardBody(
        progress,
        skeletonHeight: 78,
        onRetry: () => ref.invalidate(trainingProgressProvider),
        data: (p) {
          final prediction = p.prediction;
          if (prediction == null) {
            return ChartHint(height: 78, text: l.chuaDuDuLieuDuDoan);
          }
          final faster = prediction.deltaSeconds <= 0;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _roundDistance(units, prediction.distanceM),
                      style: const TextStyle(
                        fontSize: 12,
                        color: RetroTokens.inkSoft,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              _clock(prediction.currentSeconds),
                              style: const TextStyle(
                                fontSize: 30,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                        if (prediction.deltaSeconds != 0) ...[
                          const SizedBox(width: 6),
                          _DeltaBadge(
                            text: _clock(prediction.deltaSeconds.abs()),
                            down: faster,
                            tone: faster ? RetroTokens.ok : RetroTokens.accent,
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 120,
                height: 60,
                child: CustomPaint(
                  painter: _SparklinePainter(
                    seconds: [for (final p in prediction.series) p.seconds],
                    startLabel: _clock(prediction.baselineSeconds),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The month's prediction curve. The y axis is inverted — a faster time is
/// higher up — because "the line went up" has to mean "this got better".
class _SparklinePainter extends CustomPainter {
  _SparklinePainter({required this.seconds, required this.startLabel});

  final List<int> seconds;
  final String startLabel;

  @override
  void paint(Canvas canvas, Size size) {
    if (seconds.isEmpty) return;
    const labelWidth = 40.0;
    final left = labelWidth;
    final right = size.width - 6;
    final top = 8.0;
    final bottom = size.height - 8;

    final fastest = seconds.reduce(math.min).toDouble();
    final slowest = seconds.reduce(math.max).toDouble();
    final span = math.max(1.0, slowest - fastest);

    double x(int i) => seconds.length < 2
        ? right
        : left + (right - left) * (i / (seconds.length - 1));
    // Inverted: the fastest time is painted at the top.
    double y(int value) => bottom - ((slowest - value) / span) * (bottom - top);

    final label = TextPainter(
      text: TextSpan(
        text: startLabel,
        style: const TextStyle(fontSize: 10, color: RetroTokens.inkFaint),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: labelWidth);
    label.paint(canvas, Offset(0, y(seconds.first) - 6));

    final path = Path();
    for (var i = 0; i < seconds.length; i++) {
      final point = Offset(x(i), y(seconds[i]));
      i == 0
          ? path.moveTo(point.dx, point.dy)
          : path.lineTo(point.dx, point.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = RetroTokens.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // A thin reference line at where the athlete stands now.
    final current = y(seconds.last);
    canvas.drawLine(
      Offset(left, current),
      Offset(right, current),
      Paint()
        ..color = RetroTokens.paperSunk
        ..strokeWidth = 1,
    );

    final start = Offset(x(0), y(seconds.first));
    canvas
      ..drawCircle(start, 3.5, Paint()..color = RetroTokens.paperRaised)
      ..drawCircle(
        start,
        3.5,
        Paint()
          ..color = RetroTokens.accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );

    final end = Offset(x(seconds.length - 1), current);
    canvas
      ..drawCircle(
        end,
        7,
        Paint()..color = RetroTokens.accent.withValues(alpha: 0.25),
      )
      ..drawCircle(end, 4, Paint()..color = RetroTokens.accent);
  }

  @override
  bool shouldRepaint(_SparklinePainter old) => !identical(old.seconds, seconds);
}

/* -------------------------------------------------------------------------- */
/* 6. Vùng tập luyện                                                           */
/* -------------------------------------------------------------------------- */

const _zoneColors = [
  RetroTokens.zone1,
  RetroTokens.zone2,
  RetroTokens.zone3,
  RetroTokens.zone4,
  RetroTokens.zone5,
  RetroTokens.accent,
];

class _ZonesCard extends ConsumerWidget {
  const _ZonesCard({required this.progress});

  final AsyncValue<TrainingProgress> progress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final zones = progress.valueOrNull?.zones;

    return _ProgressCard(
      icon: Icons.favorite_outline,
      title: l.vungTapLuyen,
      scope: l.trong1ThangQua,
      onOpen: () => _explain(
        context,
        title: l.vungTapLuyen,
        explanation: l.explainZones,
        rows: [
          for (final zone in zones?.zones ?? const <ZoneSlice>[])
            (
              'Z${zone.zone}',
              '${zone.percent}% · ${_duration(context, zone.seconds)}',
            ),
        ],
      ),
      child: _cardBody(
        progress,
        skeletonHeight: 108,
        onRetry: () => ref.invalidate(trainingProgressProvider),
        data: (p) {
          final breakdown = p.zones;
          if (breakdown.topZone == null) {
            return ChartHint(height: 108, text: l.chuaCoDuLieuNhipTim);
          }
          final top = breakdown.topZone!;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.thoiGianNhieuNhat,
                      style: const TextStyle(
                        fontSize: 12,
                        color: RetroTokens.inkSoft,
                      ),
                    ),
                    const SizedBox(height: 2),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        l.phanTramOVung(breakdown.topPercent, top),
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (breakdown.deltaPercent != 0) ...[
                      const SizedBox(height: 6),
                      _DeltaBadge(
                        text: '${breakdown.deltaPercent.abs()}%',
                        down: breakdown.deltaPercent < 0,
                        tone: RetroTokens.inkSoft,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  // Z6 at the top down to Z1, the way a zone chart is read.
                  children: [
                    for (final zone in breakdown.zones.reversed)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 18,
                              child: zone.zone == top
                                  ? Text(
                                      'Z$top',
                                      style: const TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    )
                                  : const SizedBox.shrink(),
                            ),
                            Expanded(
                              child: LayoutBuilder(
                                builder: (context, constraints) => Align(
                                  alignment: Alignment.centerLeft,
                                  child: Container(
                                    height: 8,
                                    width: math.max(
                                      2,
                                      constraints.maxWidth *
                                          (zone.percent /
                                              math.max(
                                                1,
                                                breakdown.topPercent,
                                              )),
                                    ),
                                    decoration: BoxDecoration(
                                      color: zone.zone == top
                                          ? _zoneColors[(top - 1).clamp(0, 5)]
                                          : RetroTokens.paperSunk,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/* -------------------------------------------------------------------------- */
/* 7. Thành tích tốt nhất                                                      */
/* -------------------------------------------------------------------------- */

class _RecordsCard extends ConsumerWidget {
  const _RecordsCard({required this.progress});

  final AsyncValue<TrainingProgress> progress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final units = Units(ref.watch(unitSystemProvider));

    return _ProgressCard(
      icon: Icons.emoji_events_outlined,
      title: l.thanhTichTotNhat,
      onOpen: () => _explain(
        context,
        title: l.thanhTichTotNhat,
        explanation: l.explainRecords,
        rows: [
          for (final r in progress.valueOrNull?.records ?? const <BestEffort>[])
            (_roundDistance(units, r.distanceM), _clock(r.seconds)),
        ],
      ),
      child: _cardBody(
        progress,
        skeletonHeight: 96,
        onRetry: () => ref.invalidate(trainingProgressProvider),
        data: (p) => p.records.isEmpty
            ? ChartHint(height: 96, text: l.chuaCoThanhTichNao)
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final record in p.records)
                    Expanded(
                      child: Column(
                        children: [
                          _Medal(rank: record.rank),
                          const SizedBox(height: 6),
                          Text(
                            _roundDistance(units, record.distanceM),
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(
                                Icons.directions_run,
                                size: 12,
                                color: RetroTokens.inkSoft,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                _clock(record.seconds),
                                style: const TextStyle(fontSize: 13),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            l.tuTruocDenNay,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 10,
                              color: RetroTokens.inkFaint,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

/// "PR" in gold for a standing record, the place in silver for anything below.
class _Medal extends StatelessWidget {
  const _Medal({required this.rank});

  final int rank;

  @override
  Widget build(BuildContext context) {
    final gold = rank <= 1;
    final tone = gold ? RetroTokens.warn : RetroTokens.inkFaint;
    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: gold ? RetroTokens.warnSoft : RetroTokens.paperSunk,
        border: Border.all(color: tone, width: 1.5),
      ),
      child: Text(
        gold ? 'PR' : '$rank',
        style: TextStyle(
          fontSize: gold ? 11 : 13,
          fontWeight: FontWeight.w800,
          color: tone,
        ),
      ),
    );
  }
}

/* -------------------------------------------------------------------------- */
/* 8. Hoạt động hàng tháng                                                     */
/* -------------------------------------------------------------------------- */

class _MonthlyCard extends ConsumerWidget {
  const _MonthlyCard({required this.progress});

  final AsyncValue<TrainingProgress> progress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    return _ProgressCard(
      icon: Icons.stacked_line_chart,
      title: l.hoatDongHangThang,
      scope: l.thangNay,
      onOpen: () => _explain(
        context,
        title: l.hoatDongHangThang,
        explanation: l.explainMonthly,
        rows: [
          (
            l.thangNay,
            _duration(
              context,
              progress.valueOrNull?.thisMonth.totalSeconds ?? 0,
            ),
          ),
          (
            l.tuanTruoc,
            _duration(
              context,
              progress.valueOrNull?.lastMonth.totalSeconds ?? 0,
            ),
          ),
        ],
      ),
      child: _cardBody(
        progress,
        skeletonHeight: 76,
        onRetry: () => ref.invalidate(trainingProgressProvider),
        data: (p) => Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Figure(
                    label: l.thoiGian,
                    value: _duration(context, p.thisMonth.totalSeconds),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l.thangTruocLa(
                      _duration(context, p.lastMonth.totalSeconds),
                    ),
                    style: const TextStyle(
                      fontSize: 11,
                      color: RetroTokens.inkFaint,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 130,
              height: 62,
              child: CustomPaint(
                painter: _MonthlyPainter(
                  thisMonth: p.thisMonth,
                  lastMonth: p.lastMonth,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Two staircases: the month so far against the whole of the month before it.
/// Every session is a step up, so a flat stretch is a stretch of rest days.
class _MonthlyPainter extends CustomPainter {
  _MonthlyPainter({required this.thisMonth, required this.lastMonth});

  final MonthSeries thisMonth;
  final MonthSeries lastMonth;

  @override
  void paint(Canvas canvas, Size size) {
    final days = math.max(
      math.max(thisMonth.daysInMonth, lastMonth.daysInMonth),
      1,
    );
    final peak = math.max(
      math.max(thisMonth.totalSeconds, lastMonth.totalSeconds),
      1,
    );
    const top = 6.0;
    final bottom = size.height - 6;

    double x(int day) => (size.width - 8) * (day / days);
    double y(int seconds) => bottom - (bottom - top) * (seconds / peak);

    Path stairs(List<int> cumulative) {
      final path = Path()..moveTo(x(0), y(0));
      for (var i = 0; i < cumulative.length; i++) {
        path
          ..lineTo(x(i + 1), y(i == 0 ? 0 : cumulative[i - 1]))
          ..lineTo(x(i + 1), y(cumulative[i]));
      }
      return path;
    }

    if (lastMonth.cumulativeSeconds.isNotEmpty) {
      canvas.drawPath(
        stairs(lastMonth.cumulativeSeconds),
        Paint()
          ..color = RetroTokens.inkFaint
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
    if (thisMonth.cumulativeSeconds.isEmpty) return;

    canvas.drawPath(
      stairs(thisMonth.cumulativeSeconds),
      Paint()
        ..color = RetroTokens.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    final start = Offset(x(0), y(0));
    canvas
      ..drawCircle(start, 3.5, Paint()..color = RetroTokens.paperRaised)
      ..drawCircle(
        start,
        3.5,
        Paint()
          ..color = RetroTokens.accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );

    final end = Offset(
      x(thisMonth.cumulativeSeconds.length),
      y(thisMonth.cumulativeSeconds.last),
    );
    canvas
      ..drawCircle(
        end,
        7,
        Paint()..color = RetroTokens.accent.withValues(alpha: 0.25),
      )
      ..drawCircle(end, 4, Paint()..color = RetroTokens.accent);
  }

  @override
  bool shouldRepaint(_MonthlyPainter old) =>
      old.thisMonth != thisMonth || old.lastMonth != lastMonth;
}
