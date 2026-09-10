import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/date_range.dart';
import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/repositories/repositories.dart';

/// How far back the screen opens. Older meals arrive by scrolling.
const kTimelineWindowDays = 7;

/// How many meals each page after the first one fetches.
const _pageSize = 30;

class MealTimelineState {
  const MealTimelineState({
    this.meals = const [],
    this.cursor,
    this.loading = true,
    this.loadingMore = false,
    this.hasMore = true,
    this.error,
  });

  /// Newest first, drafts already filtered out.
  final List<MealLog> meals;

  /// Where the next page starts. Opaque; the server minted it.
  final String? cursor;
  final bool loading;
  final bool loadingMore;
  final bool hasMore;
  final Object? error;

  /// Days in view, newest first, each with its meals in the order they were eaten.
  List<MealDay> get days {
    final byDate = <String, List<MealLog>>{};
    for (final meal in meals) {
      (byDate[meal.localDate] ??= []).add(meal);
    }
    final dates = byDate.keys.toList()..sort((a, b) => b.compareTo(a));
    return [
      for (final date in dates)
        MealDay(
          date: date,
          meals: byDate[date]!.reversed.toList(),
        ),
    ];
  }

  MealTimelineState copyWith({
    List<MealLog>? meals,
    String? cursor,
    bool? loading,
    bool? loadingMore,
    bool? hasMore,
    Object? error,
    bool clearError = false,
  }) =>
      MealTimelineState(
        meals: meals ?? this.meals,
        cursor: cursor ?? this.cursor,
        loading: loading ?? this.loading,
        loadingMore: loadingMore ?? this.loadingMore,
        hasMore: hasMore ?? this.hasMore,
        error: clearError ? null : (error ?? this.error),
      );
}

/// One day's worth of the diary — the subtitle plus what was eaten under it.
class MealDay {
  const MealDay({required this.date, required this.meals});

  final String date;
  final List<MealLog> meals;

  double get totalKcal =>
      meals.fold<double>(0, (sum, m) => sum + m.totalCaloriesKcal);
}

/// The meal diary, paged backwards through time.
///
/// The first page is bounded by date rather than by count — the screen opens on
/// the last week, whatever that week happens to hold — and every page after it
/// is pure cursor paging. That is why the first page has to mint its own cursor
/// when the server does not: an empty week still has to know where to continue
/// from, and that point is the start of the window, not the last row returned.
class MealTimeline extends StateNotifier<MealTimelineState> {
  MealTimeline(this._repo) : super(const MealTimelineState()) {
    refresh();
  }

  final NutritionRepository _repo;

  Future<void> refresh() async {
    state = const MealTimelineState();
    final now = DateTime.now();
    final windowStart =
        DateTime(now.year, now.month, now.day - (kTimelineWindowDays - 1));

    try {
      // A big enough limit that the opening week is one round trip in practice.
      final page =
          await _repo.meals(from: DateRange.iso(windowStart), limit: 100);
      if (!mounted) return;
      state = MealTimelineState(
        meals: _visible(page.items),
        cursor: page.nextCursor ?? _cursorBefore(page.items, windowStart),
        loading: false,
        // The window bounded this page, so there may well be older meals under
        // it even when the server said there was nothing more to send.
        hasMore: true,
      );
    } catch (err) {
      if (mounted) state = MealTimelineState(loading: false, error: err);
    }
  }

  Future<void> loadMore() async {
    final cursor = state.cursor;
    if (state.loading ||
        state.loadingMore ||
        !state.hasMore ||
        cursor == null) {
      return;
    }
    state = state.copyWith(loadingMore: true, clearError: true);

    try {
      final page = await _repo.meals(cursor: cursor, limit: _pageSize);
      if (!mounted) return;
      state = MealTimelineState(
        meals: [...state.meals, ..._visible(page.items)],
        cursor: page.nextCursor,
        loading: false,
        // Unbounded from here on, so the server's answer is the whole truth.
        hasMore: page.nextCursor != null,
      );
    } catch (err) {
      if (mounted) state = state.copyWith(loadingMore: false, error: err);
    }
  }

  /// A meal with no components and no analysis worth the name — one that failed,
  /// or one whose analysis never started — holds nothing worth showing; it is a
  /// draft the detail screen offers to retry or throws away.
  List<MealLog> _visible(List<MealLog> page) =>
      page.where((m) => !m.isFailedDraft).toList();

  /// Where to continue when the opening window returned no cursor of its own:
  /// just before the oldest thing seen, or just before the window itself.
  String _cursorBefore(List<MealLog> page, DateTime windowStart) {
    if (page.isNotEmpty) {
      final last = page.last;
      return '${last.loggedAt}:${last.id}';
    }
    // Empty id: every id sorts after it, so this means "strictly older".
    return '${windowStart.millisecondsSinceEpoch}:';
  }
}

final mealTimelineProvider =
    StateNotifierProvider<MealTimeline, MealTimelineState>(
        (ref) => MealTimeline(ref.watch(nutritionRepositoryProvider)));
