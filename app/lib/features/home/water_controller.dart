import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/format/date_range.dart';

/// Water is the one daily number the API does not store yet, so it lives on the
/// device: one integer of millilitres per local date, plus a single target.
/// Keeping it here (rather than in a repository) makes it obvious that nothing
/// syncs — when the endpoint lands, only this file changes.
class WaterController extends StateNotifier<int> {
  WaterController(this.localDate) : super(0) {
    _load();
  }

  final String localDate;

  static const cupMl = 250;
  static const prefix = 'water.ml.';

  String get _key => '$prefix$localDate';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    state = prefs.getInt(_key) ?? 0;
  }

  Future<void> _persist(int ml) async {
    state = ml;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key, ml);
  }

  Future<void> addCup() => _persist(state + cupMl);

  /// Any amount, from the "nhập ml" sheet. Negative amounts are how a mistyped
  /// entry is taken back, so the total floors at zero rather than going below.
  Future<void> add(int ml) => _persist((state + ml).clamp(0, 20000));

  /// Tapping cup n means "I have drunk n cups"; tapping the last filled cup
  /// again empties it, which is the only undo the row needs.
  Future<void> setCups(int cups) {
    final next = (cups * cupMl).clamp(0, 100 * cupMl);
    return _persist(next == state ? next - cupMl : next);
  }

  Future<void> reset() => _persist(0);
}

/// How full glass [index] is, 0..1, for [drunkMl] millilitres drunk.
///
/// Water is logged in millilitres, not in whole glasses, so 380 ml of 250 ml
/// glasses is one full glass and a second one just over half — the row has to
/// be able to draw that. Lives here, next to the ml, so the drawing code cannot
/// invent a different rule.
double cupFillRatio(int index, int drunkMl,
    {int cupMl = WaterController.cupMl}) {
  if (cupMl <= 0) return 0;
  return ((drunkMl - index * cupMl) / cupMl).clamp(0.0, 1.0);
}

class WaterTargetController extends StateNotifier<int> {
  WaterTargetController() : super(2000) {
    _load();
  }

  static const _key = 'water.target.ml';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    state = prefs.getInt(_key) ?? 2000;
  }

  Future<void> set(int ml) async {
    state = ml;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key, ml);
  }
}

/// Millilitres drunk on one local date (`YYYY-MM-DD`).
final waterProvider =
    StateNotifierProvider.family<WaterController, int, String>(
        (ref, date) => WaterController(date));

final waterTargetProvider = StateNotifierProvider<WaterTargetController, int>(
    (ref) => WaterTargetController());

/// Millilitres per day across a period, for the progress chart. Days never
/// logged read as 0 rather than being dropped, so the bars line up with the
/// other charts' x axis.
final waterRangeProvider =
    FutureProvider.family<Map<String, int>, DateRange>((ref, range) async {
  // Watching the single-day notifiers keeps the chart live while the user taps
  // glasses on the home screen. Only worth it for a short range — a year would
  // spin up 365 notifiers to redraw twelve bars.
  if (range.days <= 31) {
    for (final day in range.dates) {
      ref.watch(waterProvider(DateRange.iso(day)));
    }
  }
  final prefs = await SharedPreferences.getInstance();
  return {
    for (final day in range.dates)
      DateRange.iso(day):
          prefs.getInt('${WaterController.prefix}${DateRange.iso(day)}') ?? 0,
  };
});
