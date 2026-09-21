import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';

import '../../core/api/api_exception.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/config/env.dart';
import '../../core/format/units.dart';
import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/retro_widgets.dart';
import 'messages_screen.dart';
import 'moment_camera_screen.dart';
import 'moment_composer.dart';
import 'moment_menu.dart';
import 'moment_tile.dart';
import 'moments_feed.dart';
import '../../core/l10n/gen/app_localizations.dart';

/// Locket-style: a photo goes to friends and lands on their home-screen widget.
class MomentsScreen extends ConsumerStatefulWidget {
  const MomentsScreen({super.key});

  @override
  ConsumerState<MomentsScreen> createState() => _MomentsScreenState();
}

class _MomentsScreenState extends ConsumerState<MomentsScreen> {
  bool _posting = false;

  /// The feed has two surfaces: one moment at a time, filling the screen, and
  /// a contact-sheet grid. The pager is the default — a moment from a friend is
  /// meant to be looked at, not scanned.
  bool _grid = false;

  /// Only the grid filters, but the pager reads the same filtered list, so
  /// picking a person in the grid and switching back keeps you on that person.
  String? _filterUserId;

  final _pageController = PageController();

  /// Which moment the pager is on. Tracked here because the controller has no
  /// page to report until it is attached, and the grid can hand it one.
  int _page = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    // The shot is reviewed and captioned on the camera screen itself; what
    // comes back is already the photo the user chose to send.
    final shot = await MomentCameraScreen.open(context);
    if (shot == null || !mounted) return;
    await _post(shot.bytes, shot.caption);
  }

  Future<void> _post(Uint8List bytes, String? caption) async {
    setState(() => _posting = true);
    try {
      final assetId = await ref
          .read(mediaRepositoryProvider)
          .upload(bytes, kind: 'moment_photo', mimeType: 'image/jpeg');
      await ref
          .read(momentsRepositoryProvider)
          .post(photoAssetId: assetId, caption: caption);
      await ref.read(momentsFeedProvider.notifier).refresh();
      await _refreshWidget();
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(_postError(err)),
            duration: const Duration(seconds: 6),
            // The photo is still in memory, so the failure is recoverable
            // without going back to the camera.
            action: SnackBarAction(
              label: AppL10n.of(context).thuLai,
              onPressed: () => _post(bytes, caption),
            ),
          ),
        );
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  /// Upload failures are the ones a user can act on — too large, offline, a
  /// session that expired mid-post — so they get their own wording instead of
  /// the exception's `toString`.
  String _postError(Object err) {
    if (err is! ApiException) return AppL10n.of(context).khongDangDuocAnhThuLai;
    switch (err.code) {
      case 'UPLOAD_TOO_LARGE':
        return AppL10n.of(context).anhQuaNangChupLaiVoi;
      case 'NETWORK_ERROR':
        return AppL10n.of(context).matKetNoiKhiTaiAnh;
      case 'BAD_MEDIA':
        return AppL10n.of(context).anhTaiLenBiLoiChup;
      default:
        return err.isUnauthenticated
            ? AppL10n.of(context).phienDangNhapHetHanDang
            : err.message;
    }
  }

  /// Pushes the newest unseen friend moment into the native widget and asks the
  /// OS to redraw it.
  Future<void> _refreshWidget() async {
    try {
      final moments = await ref.read(momentsRepositoryProvider).widget();
      final first = moments.isEmpty ? null : moments.first;
      await HomeWidget.saveWidgetData<String>(
        'moment_author',
        first?.authorName ?? '',
      );
      await HomeWidget.saveWidgetData<String>(
        'moment_caption',
        first?.caption ?? '',
      );
      await HomeWidget.saveWidgetData<String>(
        'moment_asset',
        first?.photoAssetId ?? '',
      );
      await HomeWidget.updateWidget(
        name: Env.widgetName,
        iOSName: Env.widgetName,
      );
    } catch (_) {
      // The widget is a nice-to-have; never let it break posting.
    }
  }

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(momentsFeedProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(AppL10n.of(context).congDong),
        actions: [
          IconButton(
            tooltip: _grid
                ? AppL10n.of(context).xemTungAnh
                : AppL10n.of(context).xemDangLuoi,
            icon: Icon(
              _grid ? Icons.crop_portrait_outlined : Icons.grid_view_outlined,
            ),
            onPressed: () => setState(() => _grid = !_grid),
          ),
          MessagesBadge(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const MessagesScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.connect_without_contact_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const _FriendsScreen()),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _posting ? null : _capture,
        backgroundColor: RetroTokens.accent,
        foregroundColor: Colors.white,
        child: _posting
            ? const SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.camera_alt),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(momentsFeedProvider.notifier).refresh(),
        // The feed pages backwards forever, so loading is driven by how close
        // the grid is to its end rather than by a "tải thêm" button.
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            final m = n.metrics;
            if (m.axis == Axis.vertical && m.pixels > m.maxScrollExtent - 400) {
              ref.read(momentsFeedProvider.notifier).loadMore();
            }
            return false;
          },
          child: PhoneFrame(child: _body(feed)),
        ),
      ),
    );
  }

  Widget _body(MomentsFeedState feed) {
    if (feed.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (feed.moments.isEmpty) {
      // Still scrollable: pull-to-refresh is the only way back from an error,
      // and a non-scrolling child gives RefreshIndicator nothing to listen to.
      return ListView(
        padding: const EdgeInsets.all(32),
        children: [
          Text(
            feed.error != null
                ? '${feed.error}'
                : AppL10n.of(context).chuaCoKhoanhKhacNaoChup,
            textAlign: TextAlign.center,
            style: const TextStyle(color: RetroTokens.inkSoft),
          ),
        ],
      );
    }

    final moments = _filterUserId == null
        ? feed.moments
        : feed.moments.where((m) => m.userId == _filterUserId).toList();

    return _grid ? _gridView(feed, moments) : _pagerView(feed, moments);
  }

  /// The default surface: one moment per screen, the next one a swipe down.
  Widget _pagerView(MomentsFeedState feed, List<Moment> moments) {
    if (moments.isEmpty) return _emptyFilter();

    // onPageChanged never fires for the page the pager opens on, so without
    // this the moment it lands on would stay unread.
    if (_page < moments.length) _markVisible(moments[_page].id);

    // A page of its own for the next batch, so the swipe that asks for it has
    // something to land on instead of stopping dead at the last photo.
    final tail = feed.loadingMore ? 1 : 0;

    return PageView.builder(
      controller: _pageController,
      scrollDirection: Axis.vertical,
      // Page physics alone never overscroll, and RefreshIndicator has nothing
      // to listen to without one.
      physics: const PageScrollPhysics().applyTo(
        const AlwaysScrollableScrollPhysics(),
      ),
      itemCount: moments.length + tail,
      onPageChanged: (i) {
        _page = i;
        if (i >= moments.length) return;
        // Landing on a page is what counts as having seen it, and home reads
        // the same flag to decide what is still news.
        ref.read(momentsFeedProvider.notifier).markViewed(moments[i].id);
        if (i >= moments.length - 2) {
          ref.read(momentsFeedProvider.notifier).loadMore();
        }
      },
      itemBuilder: (_, i) {
        if (i >= moments.length) {
          return const Center(
            child: SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        return _MomentPage(moment: moments[i]);
      },
    );
  }

  /// The contact sheet: photos only. Who posted what is the pager's job — here
  /// the person is picked once, at the top, and the tiles stay uncaptioned.
  Widget _gridView(MomentsFeedState feed, List<Moment> moments) {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _PersonPicker(
            // The unfiltered feed, so the picker never hides the person you
            // would need to tap to get back out of a filter.
            moments: feed.moments,
            selected: _filterUserId,
            onChanged: (id) => setState(() => _filterUserId = id),
          ),
        ),
        if (moments.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: _EmptyFilterText(),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              delegate: SliverChildBuilderDelegate(
                (_, i) => _GridPhoto(
                  moment: moments[i],
                  onTap: () => _openInPager(i),
                ),
                childCount: moments.length,
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
            child: _FeedFooter(feed: feed),
          ),
        ),
      ],
    );
  }

  /// Marking during build would write to a provider mid-frame, so it waits for
  /// the frame to end.
  void _markVisible(String id) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(momentsFeedProvider.notifier).markViewed(id);
    });
  }

  /// Tapping a tile leaves the grid on that same moment.
  void _openInPager(int index) {
    setState(() {
      _grid = false;
      _page = index;
    });
    // The pager only exists after this frame rebuilds, so the controller has
    // no clients to jump until then.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pageController.hasClients) _pageController.jumpToPage(index);
    });
  }

  /// A list rather than a centred text: pull-to-refresh needs a scrollable,
  /// and a filter with nothing behind it is a state you refresh out of.
  Widget _emptyFilter() => ListView(
    padding: const EdgeInsets.all(32),
    children: const [_EmptyFilterText()],
  );
}

class _EmptyFilterText extends StatelessWidget {
  const _EmptyFilterText();

  @override
  Widget build(BuildContext context) => Text(
    AppL10n.of(context).nguoiNayChuaCoKhoanhKhac,
    textAlign: TextAlign.center,
    style: TextStyle(color: RetroTokens.inkSoft),
  );
}

/// One moment at full size: the photo, its caption and author, then the two
/// things you can do about it — react, or say something.
class _MomentPage extends ConsumerWidget {
  const _MomentPage({required this.moment});

  final Moment moment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mine = moment.userId == ref.watch(authControllerProvider).user?.id;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RetroBox(
            padding: EdgeInsets.zero,
            child: AspectRatio(
              aspectRatio: 1,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  MomentPhoto(assetId: moment.photoAssetId),
                  // Your own photo is the only one you can share, keep or take
                  // down, so the menu belongs to it alone.
                  if (mine)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: MomentMenuButton(moment: moment),
                    ),
                ],
              ),
            ),
          ),
          if (moment.caption != null) ...[
            const SizedBox(height: 16),
            Text(
              moment.caption!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, color: RetroTokens.ink),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            '${moment.authorName ?? 'Bạn'} · ${Units.timeOfDay(moment.createdAt)}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: RetroTokens.inkFaint),
          ),
          // Nobody replies to themselves: under your own photo the actions are
          // the menu on it, not a message box. Everything written here goes to
          // the messages list, which is where the conversation is read.
          if (!mine) ...[
            const SizedBox(height: 12),
            MomentComposer(moment: moment),
          ],
        ],
      ),
    );
  }
}

/// A grid cell: the photo and nothing else.
class _GridPhoto extends StatelessWidget {
  const _GridPhoto({required this.moment, this.onTap});

  final Moment moment;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => RetroBox(
    padding: EdgeInsets.zero,
    onTap: onTap,
    shadow: false,
    borderColor: RetroTokens.panelLine,
    borderWidth: 1,
    child: MomentPhoto(assetId: moment.photoAssetId),
  );
}

/// Who to look at: everyone, or one person at a time. Built from the moments
/// already loaded, so it lists exactly the people the feed can show.
class _PersonPicker extends StatelessWidget {
  const _PersonPicker({
    required this.moments,
    required this.selected,
    required this.onChanged,
  });

  final List<Moment> moments;
  final String? selected;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    // Insertion order, so the picker does not reshuffle as pages arrive.
    final people = <String, String>{};
    for (final m in moments) {
      people.putIfAbsent(
        m.userId,
        () => m.authorName ?? AppL10n.of(context).ban,
      );
    }

    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          _chip(label: AppL10n.of(context).tatCa, id: null),
          for (final entry in people.entries)
            _chip(label: entry.value, id: entry.key),
        ],
      ),
    );
  }

  Widget _chip({required String label, required String? id}) {
    final on = selected == id;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: RetroBox(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        shadow: false,
        color: on ? RetroTokens.accentSoft : RetroTokens.paperRaised,
        borderColor: on ? RetroTokens.accent : RetroTokens.panelLine,
        borderWidth: on ? RetroTokens.border : 1,
        onTap: () => onChanged(id),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: on ? RetroTokens.accent : RetroTokens.inkSoft,
              fontWeight: on ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// What sits under the last row: the next page arriving, the error that stopped
/// it, or nothing once the feed has reached its end.
class _FeedFooter extends ConsumerWidget {
  const _FeedFooter({required this.feed});

  final MomentsFeedState feed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (feed.loadingMore) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: SizedBox(
            height: 20,
            width: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (feed.error != null) {
      return Center(
        child: TextButton(
          onPressed: () => ref.read(momentsFeedProvider.notifier).loadMore(),
          child: Text(AppL10n.of(context).taiThem),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

class _FriendsScreen extends ConsumerStatefulWidget {
  const _FriendsScreen();

  @override
  ConsumerState<_FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends ConsumerState<_FriendsScreen> {
  final _email = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final friends = ref.watch(friendsProvider);
    final requests = ref.watch(friendRequestsProvider);

    return Scaffold(
      appBar: AppBar(title: Text(AppL10n.of(context).banBe)),
      body: PhoneFrame(
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _email,
                      decoration: InputDecoration(
                        labelText: AppL10n.of(context).emailCuaBanBe,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () async {
                      try {
                        await ref
                            .read(momentsRepositoryProvider)
                            .requestFriend(_email.text.trim());
                        _email.clear();
                        ref.invalidate(friendRequestsProvider);
                        ref.invalidate(friendsProvider);
                      } catch (err) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(
                            context,
                          ).showSnackBar(SnackBar(content: Text('$err')));
                        }
                      }
                    },
                    child: Text(AppL10n.of(context).moi),
                  ),
                ],
              ),
            ),
            SectionTitle(AppL10n.of(context).loiMoiDen),
            asyncBody(
              requests,
              emptyWhen: (data) => (data['incoming'] as List?)?.isEmpty ?? true,
              emptyText: AppL10n.of(context).khongCoLoiMoiNao,
              data: (data) => Column(
                children: [
                  for (final raw in (data['incoming'] as List? ?? const []))
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: RetroBox(
                        child: Row(
                          children: [
                            Expanded(
                              child: Text('${(raw as Map)['requesterId']}'),
                            ),
                            TextButton(
                              onPressed: () async {
                                await ref
                                    .read(momentsRepositoryProvider)
                                    .acceptRequest(raw['id'] as String);
                                ref.invalidate(friendRequestsProvider);
                                ref.invalidate(friendsProvider);
                              },
                              child: Text(AppL10n.of(context).dongY),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            SectionTitle(AppL10n.of(context).banBe),
            asyncBody(
              friends,
              emptyWhen: (list) => list.isEmpty,
              emptyText: AppL10n.of(context).chuaCoBanNao,
              data: (list) => Column(
                children: [
                  for (final friend in list)
                    ListTile(
                      title: Text(friend.label),
                      subtitle: Text(friend.email ?? ''),
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
