import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/repositories/repositories.dart';

/// How many moments a page carries. A multiple of the grid's three columns, so
/// the last row of a page is never a stub.
const _pageSize = 21;

class MomentsFeedState {
  const MomentsFeedState({
    this.moments = const [],
    this.cursor,
    this.loading = true,
    this.loadingMore = false,
    this.error,
  });

  /// Newest first — the server orders by id, and ids are UUIDv7.
  final List<Moment> moments;

  /// Where the next page starts; null once the server has nothing older.
  final String? cursor;
  final bool loading;
  final bool loadingMore;
  final Object? error;

  bool get hasMore => cursor != null;

  MomentsFeedState copyWith({
    List<Moment>? moments,
    String? cursor,
    bool? loading,
    bool? loadingMore,
    Object? error,
    bool clearError = false,
  }) => MomentsFeedState(
    moments: moments ?? this.moments,
    cursor: cursor ?? this.cursor,
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    error: clearError ? null : (error ?? this.error),
  );
}

/// The community feed, paged backwards forever.
///
/// One controller for both surfaces — the section at the foot of the home
/// screen and the full screen behind it — so scrolling either one deep does not
/// leave the other refetching pages it has already paid for.
class MomentsFeed extends StateNotifier<MomentsFeedState> {
  MomentsFeed(this._repo) : super(const MomentsFeedState()) {
    refresh();
  }

  final MomentsRepository _repo;

  Future<void> refresh() async {
    state = const MomentsFeedState();
    try {
      final page = await _repo.feed(limit: _pageSize);
      if (!mounted) return;
      state = MomentsFeedState(
        moments: page.items,
        cursor: page.nextCursor,
        loading: false,
      );
    } catch (err) {
      if (mounted) state = MomentsFeedState(loading: false, error: err);
    }
  }

  /// Marks one moment as read for this viewer. The local copy is patched
  /// rather than refetched: the pager marks as it scrolls, and a refresh per
  /// swipe would fight the paging.
  Future<void> markViewed(String id) async {
    final at = DateTime.now().millisecondsSinceEpoch;
    final i = state.moments.indexWhere((m) => m.id == id);
    if (i < 0 || state.moments[i].seen) return;

    state = state.copyWith(
      moments: [
        for (final m in state.moments) m.id == id ? m.markedViewed(at) : m,
      ],
    );
    try {
      await _repo.markViewed(id);
    } catch (_) {
      // Read state is a nicety; a failed mark costs the user nothing worse
      // than seeing the moment on home once more.
    }
  }

  /// Removes a moment the user just deleted. Local, because the page it came
  /// from is still valid — refetching would only cost a round trip to learn
  /// what we already know.
  void removed(String id) {
    state = state.copyWith(
      moments: [
        for (final m in state.moments)
          if (m.id != id) m,
      ],
    );
  }

  Future<void> loadMore() async {
    final cursor = state.cursor;
    if (state.loading || state.loadingMore || cursor == null) return;
    state = state.copyWith(loadingMore: true, clearError: true);

    try {
      final page = await _repo.feed(cursor: cursor, limit: _pageSize);
      if (!mounted) return;
      state = MomentsFeedState(
        moments: [...state.moments, ...page.items],
        cursor: page.nextCursor,
        loading: false,
      );
    } catch (err) {
      if (mounted) state = state.copyWith(loadingMore: false, error: err);
    }
  }
}

final momentsFeedProvider =
    StateNotifierProvider<MomentsFeed, MomentsFeedState>(
      (ref) => MomentsFeed(ref.watch(momentsRepositoryProvider)),
    );
