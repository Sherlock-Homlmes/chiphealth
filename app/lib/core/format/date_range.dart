import 'package:intl/intl.dart';

/// How the progress screen slices time. The ‹ › buttons step by whichever unit
/// is selected; `custom` is a fixed range the user picked and does not step.
enum PeriodMode { week, month, year, custom }

extension PeriodModeLabel on PeriodMode {
  String get label => switch (this) {
    PeriodMode.week => 'Tuần',
    PeriodMode.month => 'Tháng',
    PeriodMode.year => 'Năm',
    PeriodMode.custom => 'Tùy chọn khoảng thời gian',
  };
}

/// An inclusive span of local dates. Value type, so it can key a provider
/// family without re-fetching on every rebuild.
class DateRange {
  const DateRange(this.start, this.end);

  final DateTime start;
  final DateTime end;

  static final _iso = DateFormat('yyyy-MM-dd');
  static final _dayMonth = DateFormat('d/M');
  static final _weekday = DateFormat('E', 'vi');

  String get fromIso => _iso.format(start);
  String get toIso => _iso.format(end);

  int get days => end.difference(start).inDays + 1;

  /// Every date in the range, oldest first. Used as the x axis of every chart,
  /// so a day with no data still gets a slot.
  List<DateTime> get dates => [
    for (var i = 0; i < days; i++)
      DateTime(start.year, start.month, start.day + i),
  ];

  bool contains(DateTime day) => !day.isBefore(start) && !day.isAfter(end);

  /// This range folded into [first]..[last]. showDateRangePicker asserts its
  /// initial range sits inside the pickable window, but the period being
  /// viewed usually runs past today (a week ends Sunday, a month the 31st),
  /// and stepping back far enough predates the earliest pickable date — so
  /// the preselection is clamped before it reaches the picker.
  DateRange clampedTo(DateTime first, DateTime last) {
    final s = start.isBefore(first) ? first : start;
    var e = end.isAfter(last) ? last : end;
    if (e.isBefore(s)) e = s;
    return DateRange(s, e);
  }

  static String iso(DateTime day) => _iso.format(day);

  /// Axis label for one day: weekday inside a week, day/month otherwise.
  String tick(DateTime day) =>
      days <= 7 ? _weekday.format(day) : _dayMonth.format(day);

  @override
  bool operator ==(Object other) =>
      other is DateRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

/// The period being viewed: a mode plus an anchor date inside it. Stepping is
/// calendar arithmetic (DateTime(y, m + 1, d)), never Duration, so months and
/// years of different lengths land where a human expects.
class Period {
  const Period({required this.mode, required this.anchor, this.custom});

  factory Period.thisWeek() {
    final now = DateTime.now();
    return Period(
      mode: PeriodMode.week,
      anchor: DateTime(now.year, now.month, now.day),
    );
  }

  final PeriodMode mode;
  final DateTime anchor;
  final DateRange? custom;

  static final _monthYear = DateFormat('MM/yyyy');
  static final _dayMonth = DateFormat('d/M');

  DateRange get range {
    switch (mode) {
      case PeriodMode.week:
        final monday = DateTime(
          anchor.year,
          anchor.month,
          anchor.day - (anchor.weekday - 1),
        );
        return DateRange(
          monday,
          DateTime(monday.year, monday.month, monday.day + 6),
        );
      case PeriodMode.month:
        return DateRange(
          DateTime(anchor.year, anchor.month, 1),
          DateTime(anchor.year, anchor.month + 1, 0),
        );
      case PeriodMode.year:
        return DateRange(
          DateTime(anchor.year, 1, 1),
          DateTime(anchor.year, 12, 31),
        );
      case PeriodMode.custom:
        return custom ?? DateRange(anchor, anchor);
    }
  }

  Period step(int delta) => switch (mode) {
    PeriodMode.week => Period(
      mode: mode,
      anchor: DateTime(anchor.year, anchor.month, anchor.day + 7 * delta),
    ),
    PeriodMode.month => Period(
      mode: mode,
      anchor: DateTime(anchor.year, anchor.month + delta, 1),
    ),
    PeriodMode.year => Period(
      mode: mode,
      anchor: DateTime(anchor.year + delta, anchor.month, 1),
    ),
    // A hand-picked range has no next or previous.
    PeriodMode.custom => this,
  };

  /// True once the range would run past today: there is nothing to show in the
  /// future, so ›  is disabled.
  bool get isLatest {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return !range.end.isBefore(today);
  }

  String get label {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (mode) {
      case PeriodMode.week:
        if (range.contains(today)) return 'Tuần này';
        final lastWeek = Period(mode: mode, anchor: today).step(-1).range;
        if (range == lastWeek) return 'Tuần trước';
        return '${_dayMonth.format(range.start)} – ${_dayMonth.format(range.end)}';
      case PeriodMode.month:
        if (anchor.year == today.year && anchor.month == today.month) {
          return 'Tháng này';
        }
        return 'Tháng ${_monthYear.format(range.start)}';
      case PeriodMode.year:
        if (anchor.year == today.year) return 'Năm nay';
        return 'Năm ${range.start.year}';
      case PeriodMode.custom:
        return '${_dayMonth.format(range.start)} – ${_dayMonth.format(range.end)}';
    }
  }
}
