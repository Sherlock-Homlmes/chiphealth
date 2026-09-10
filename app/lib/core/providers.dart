import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api/api_client.dart';
import 'api/sse.dart';
import 'auth/auth_controller.dart';
import 'auth/token_store.dart';
import 'format/date_range.dart';
import 'models/models.dart';
import 'repositories/repositories.dart';

final tokenStoreProvider = Provider<TokenStore>((ref) => TokenStore());

final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClient(tokens: ref.watch(tokenStoreProvider));
  // A rejected refresh token is the one case where the session is really gone —
  // but in a dev build it is worth one attempt at a fresh dev session first.
  client.recoverSession = () =>
      ref.read(authControllerProvider.notifier).seedDevSession();
  client.onSessionExpired = () async =>
      ref.read(authControllerProvider.notifier).signOut();
  return client;
});

final profileRepositoryProvider = Provider(
  (ref) => ProfileRepository(ref.watch(apiClientProvider)),
);
final mediaRepositoryProvider = Provider(
  (ref) => MediaRepository(ref.watch(apiClientProvider)),
);
final nutritionRepositoryProvider = Provider(
  (ref) => NutritionRepository(ref.watch(apiClientProvider)),
);
final trainingRepositoryProvider = Provider(
  (ref) => TrainingRepository(ref.watch(apiClientProvider)),
);
final sleepRepositoryProvider = Provider(
  (ref) => SleepRepository(ref.watch(apiClientProvider)),
);
final coachRepositoryProvider = Provider(
  (ref) => CoachRepository(ref.watch(apiClientProvider)),
);
final momentsRepositoryProvider = Provider(
  (ref) => MomentsRepository(ref.watch(apiClientProvider)),
);

/// Unit system of the signed-in user; metric until we know otherwise.
final unitSystemProvider = Provider<UnitSystem>(
  (ref) =>
      ref.watch(authControllerProvider).user?.unitSystem ?? UnitSystem.metric,
);

final activityTypesProvider = FutureProvider<List<ActivityType>>((ref) {
  final locale = ref.watch(authControllerProvider).user?.locale ?? 'vi';
  return ref.watch(profileRepositoryProvider).activityTypes(locale);
});

final dailyNutritionProvider = FutureProvider.family<DailyNutrition, String?>(
  (ref, date) => ref.watch(nutritionRepositoryProvider).daily(date),
);

/// Daily rollups for a whole period — the progress screen's charts.
final nutritionRangeProvider =
    FutureProvider.family<List<DailyNutrition>, DateRange>(
      (ref, range) => ref
          .watch(nutritionRepositoryProvider)
          .range(range.fromIso, range.toIso),
    );

final bodyMetricsRangeProvider =
    FutureProvider.family<List<BodyMetric>, DateRange>(
      (ref, range) => ref
          .watch(profileRepositoryProvider)
          .bodyMetrics(from: range.fromIso, to: range.toIso, limit: 200),
    );

/// Every body metric ever recorded: the BMI card needs the last known height,
/// which may have been entered long before the current period.
final allBodyMetricsProvider = FutureProvider<List<BodyMetric>>(
  (ref) => ref.watch(profileRepositoryProvider).bodyMetrics(limit: 200),
);

final goalsProvider = FutureProvider<List<Goal>>(
  (ref) => ref.watch(profileRepositoryProvider).goals(),
);

final sleepDebtProvider = FutureProvider<SleepDebt>(
  (ref) => ref.watch(sleepRepositoryProvider).debt(),
);

final sleepSessionProvider = FutureProvider.family<SleepSession, String>(
  (ref, id) => ref.watch(sleepRepositoryProvider).session(id),
);

final personalRecordsProvider = FutureProvider<List<PersonalRecord>>(
  (ref) => ref.watch(trainingRepositoryProvider).records(),
);

final workoutFeedProvider = FutureProvider<List<WorkoutSession>>(
  (ref) => ref.watch(trainingRepositoryProvider).feed(),
);

final workoutDetailProvider =
    FutureProvider.family<Map<String, dynamic>, String>(
      (ref, id) => ref.watch(trainingRepositoryProvider).detail(id),
    );

final insightsProvider = FutureProvider<List<CoachInsight>>(
  (ref) => ref.watch(coachRepositoryProvider).insights(),
);

final friendsProvider = FutureProvider<List<Friend>>(
  (ref) => ref.watch(momentsRepositoryProvider).friends(),
);

final friendRequestsProvider = FutureProvider<Map<String, dynamic>>(
  (ref) => ref.watch(momentsRepositoryProvider).pendingRequests(),
);

/// Replies and reactions as they happen, over SSE.
///
/// The stream closes itself every few minutes (a Worker should not hold a
/// connection forever), so this reconnects and carries `since` forward — the
/// server replays anything that landed while the socket was down, which makes a
/// dropped connection invisible rather than a hole in the timeline.
final momentEventsProvider = StreamProvider<SseEvent>((ref) async* {
  final api = ref.watch(apiClientProvider);
  var since = DateTime.now().millisecondsSinceEpoch;

  var alive = true;
  ref.onDispose(() => alive = false);

  while (alive) {
    final uri = await api.streamUri(
      '/v1/moments/stream',
      query: {'since': '$since'},
    );
    if (uri == null) {
      // No session yet: nothing to listen to until sign-in completes.
      await Future<void>.delayed(const Duration(seconds: 5));
      continue;
    }
    try {
      await for (final event in connectSse(uri)) {
        final at = event.data['createdAt'];
        if (at is int && at > since) since = at;
        yield event;
      }
    } catch (_) {
      // A dropped stream is ordinary; the delay below keeps a server that is
      // down from being hammered.
    }
    if (alive) await Future<void>.delayed(const Duration(seconds: 3));
  }
});

/// The messages list: one row per friend, most recent first.
class ConversationsState {
  const ConversationsState({
    this.items = const [],
    this.loading = true,
    this.error,
  });

  final List<Conversation> items;
  final bool loading;
  final Object? error;

  int get unread => items.fold(0, (sum, c) => sum + c.unread);
}

class ConversationsController extends StateNotifier<ConversationsState> {
  ConversationsController(this._repo) : super(const ConversationsState()) {
    refresh();
  }

  final MomentsRepository _repo;

  Future<void> refresh() async {
    try {
      final items = await _repo.conversations();
      if (mounted) state = ConversationsState(items: items, loading: false);
    } catch (err) {
      if (mounted) state = ConversationsState(loading: false, error: err);
    }
  }

  /// A message that arrived over the stream. The list is patched rather than
  /// refetched so the badge moves the instant it lands.
  void received(DirectMessage message) {
    final other = message.senderId;
    final rest = [
      for (final c in state.items)
        if (c.userId != other) c,
    ];
    final existing = state.items.where((c) => c.userId == other).firstOrNull;

    state = ConversationsState(
      loading: false,
      items: [
        Conversation(
          userId: other,
          displayName: existing?.displayName ?? message.senderName,
          avatarUrl: existing?.avatarUrl ?? message.senderAvatarUrl,
          unread: (existing?.unread ?? 0) + 1,
          lastMessage: message,
        ),
        ...rest,
      ],
    );
  }

  /// Local first, then the server: opening a conversation clears its badge.
  Future<void> markRead(String userId) async {
    state = ConversationsState(
      loading: false,
      items: [
        for (final c in state.items)
          if (c.userId == userId)
            Conversation(
              userId: c.userId,
              displayName: c.displayName,
              avatarUrl: c.avatarUrl,
              unread: 0,
              lastMessage: c.lastMessage,
            )
          else
            c,
      ],
    );
    try {
      await _repo.markConversationRead(userId);
    } catch (_) {
      // The next refresh puts the badge back if the server disagreed.
    }
  }
}

final conversationsProvider =
    StateNotifierProvider<ConversationsController, ConversationsState>((ref) {
      final controller = ConversationsController(
        ref.watch(momentsRepositoryProvider),
      );
      // The stream feeds the same list the screen reads, so an open messages screen
      // and the badge behind it can never disagree.
      ref.listen(momentEventsProvider, (_, next) {
        final event = next.valueOrNull;
        if (event?.event != 'message') return;
        controller.received(DirectMessage.fromJson(event!.data));
      });
      return controller;
    });

/// One conversation's messages, oldest first.
final conversationProvider = FutureProvider.family<List<DirectMessage>, String>(
  (ref, userId) => ref.watch(momentsRepositoryProvider).messages(userId),
);

/// Bytes of one media asset, keyed by asset id./// Bytes of one media asset, keyed by asset id. Cached per id so a grid of
/// photos fetches each object once instead of on every rebuild and scroll.
final mediaBytesProvider = FutureProvider.family<Uint8List, String>(
  (ref, assetId) => ref.watch(mediaRepositoryProvider).bytes(assetId),
);
