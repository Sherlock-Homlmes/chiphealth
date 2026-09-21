import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../l10n/gen/app_localizations.dart';
import '../models/models.dart';

/// Everything is stored and transmitted in metric; this is the only place that
/// converts, so an imperial user never causes metric data to be written.
class Units {
  const Units(this.system);

  final UnitSystem system;

  bool get isImperial => system == UnitSystem.imperial;

  static final _n0 = NumberFormat('#,##0');
  static final _n1 = NumberFormat('#,##0.#');

  String weight(double? kg) {
    if (kg == null) return '—';
    return isImperial
        ? '${_n1.format(kg * 2.20462)} lb'
        : '${_n1.format(kg)} kg';
  }

  String height(double? cm) {
    if (cm == null) return '—';
    if (!isImperial) return '${_n0.format(cm)} cm';
    final totalInches = cm / 2.54;
    final feet = totalInches ~/ 12;
    final inches = (totalInches % 12).round();
    return "$feet'$inches\"";
  }

  String distance(double? meters) {
    if (meters == null) return '—';
    return isImperial
        ? '${_n1.format(meters / 1609.344)} mi'
        : '${_n1.format(meters / 1000)} km';
  }

  /// Pace is stored per kilometre; imperial users think per mile.
  String pace(double? secPerKm) {
    if (secPerKm == null || secPerKm <= 0) return '—';
    final sec = isImperial ? secPerKm * 1.609344 : secPerKm;
    final minutes = sec ~/ 60;
    final seconds = (sec % 60).round();
    final unit = isImperial ? '/mi' : '/km';
    return '$minutes:${seconds.toString().padLeft(2, '0')}$unit';
  }

  static String duration(int? seconds) {
    if (seconds == null) return '—';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
    if (m > 0) return '${m}m ${s.toString().padLeft(2, '0')}s';
    return '${s}s';
  }

  static String hoursMinutes(int? seconds) {
    if (seconds == null) return '—';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    return '${h}h${m.toString().padLeft(2, '0')}';
  }

  static String kcal(double? value) =>
      value == null ? '—' : '${_n0.format(value)} kcal';
  static String grams(double? value) =>
      value == null ? '—' : '${_n1.format(value)} g';
  static String milligrams(double? value) =>
      value == null ? '—' : '${_n0.format(value)} mg';

  /// `YYYY-MM-DD` in the device's local calendar — the key every log row uses.
  static String localDate(DateTime moment) =>
      DateFormat('yyyy-MM-dd').format(moment);
  static String today() => localDate(DateTime.now());
  static String dayLabel(String isoDate) =>
      DateFormat('EEE d/M', 'vi').format(DateTime.parse(isoDate));

  /// Subtitle for a day of the meal diary. Recent days are named rather than
  /// dated: a diary that says "Hôm nay" reads faster than one that says 9/9.
  /// Takes a context because "hôm nay" / "today" follows the app's language.
  static String dayHeading(BuildContext context, String isoDate) {
    final day = DateTime.parse(isoDate);
    final now = DateTime.now();
    final midnight = DateTime(now.year, now.month, now.day);
    final diff = midnight
        .difference(DateTime(day.year, day.month, day.day))
        .inDays;
    if (diff == 0) return AppL10n.of(context).homNay;
    if (diff == 1) return AppL10n.of(context).homQua;
    return DateFormat(
      'EEEE, d/M',
      Localizations.localeOf(context).languageCode,
    ).format(day);
  }

  static String timeOfDay(int epochMs) =>
      DateFormat('HH:mm').format(DateTime.fromMillisecondsSinceEpoch(epochMs));
}
