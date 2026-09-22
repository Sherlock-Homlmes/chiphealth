import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/repositories/repositories.dart';

/// How many of the latest meals the screen opens on, however old they are.
const kTimelineFirstPage = 10;

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

  /// Newest first, exactly what the server returned — nothing is filtered out.
  /// A meal whose analysis failed stays in the diary with a retry on its row:
  /// hiding it looked like the meal had never been logged, and the user had no
  /// way to ask for it to be analysed again.
  final List<MealLog> meals;

  /// Where the next page starts. Opaque; the server minted it.
  final String? cursor;
  final bool loading;
  final bool loadingMore;
  final bool hasMore;
  final Object? error;

  /// Days in view, newest first, each with its latest-eaten meal on top.
  List<MealDay> get days {
    final byDate = <String, List<MealLog>>{};
    for (final meal in meals) {
      (byDate[meal.localDate] ??= []).add(meal);
    }
    final dates = byDate.keys.toList()..sort((a, b) => b.compareTo(a));
    return [
      // Latest meal on top (dinner, lunch, breakfast), by the time it was
      // eaten (loggedAt, which the user can move) — never by creation order.
      for (final date in dates)
        MealDay(
          date: date,
          meals: byDate[date]!
            ..sort(
              (a, b) => a.loggedAt != b.loggedAt
                  ? b.loggedAt.compareTo(a.loggedAt)
                  : b.id.compareTo(a.id),
            ),
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
  }) => MealTimelineState(
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
/// The screen opens on the latest [kTimelineFirstPage] meals — however far back
/// they go, so a quiet week never leaves it looking empty — and pages by cursor
/// from there. The oldest day on a page is topped up to whole before showing,
/// so no day heading ever sums only part of that day.
class MealTimeline extends StateNotifier<MealTimelineState> {
  MealTimeline(this._repo) : super(const MealTimelineState()) {
    refresh();
  }

  final NutritionRepository _repo;

  Future<void> refresh() async {
    state = const MealTimelineState();
    try {
      final page = await _wholeDays(
        await _repo.meals(limit: kTimelineFirstPage),
      );
      if (!mounted) return;
      state = MealTimelineState(
        meals: page.items,
        cursor: page.nextCursor,
        loading: false,
        hasMore: page.nextCursor != null,
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
      final page = await _wholeDays(
        await _repo.meals(cursor: cursor, limit: _pageSize),
      );
      if (!mounted) return;
      state = MealTimelineState(
        meals: [...state.meals, ...page.items],
        cursor: page.nextCursor,
        loading: false,
        hasMore: page.nextCursor != null,
      );
    } catch (err) {
      if (mounted) state = state.copyWith(loadingMore: false, error: err);
    }
  }

  /// Fetches the rest of the oldest day on [page] when the page cut it short.
  Future<MealPage> _wholeDays(MealPage page) async {
    final cursor = page.nextCursor;
    if (cursor == null || page.items.isEmpty) return page;
    final rest = await _repo.meals(
      from: page.items.last.localDate,
      cursor: cursor,
      limit: 100,
    );
    // The date filter ends this page, not the diary: continue from the last
    // meal seen, whether or not the day added any.
    final items = [...page.items, ...rest.items];
    final last = items.last;
    return MealPage(items: items, nextCursor: '${last.loggedAt}:${last.id}');
  }
}

final mealTimelineProvider =
    StateNotifierProvider<MealTimeline, MealTimelineState>(
      (ref) => MealTimeline(ref.watch(nutritionRepositoryProvider)),
    );
