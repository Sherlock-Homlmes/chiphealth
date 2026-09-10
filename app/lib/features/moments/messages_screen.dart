import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/units.dart';
import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/retro_widgets.dart';
import 'conversation_screen.dart';
import 'moment_tile.dart';

/// The messages list: one row per friend, newest activity first. Everything a
/// friend sends — an answer to a photo, a reaction — arrives here.
class MessagesScreen extends ConsumerWidget {
  const MessagesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(conversationsProvider);

    // A message landing while the list is open moves the row it belongs to.
    ref.listen(momentEventsProvider, (_, __) {});

    return Scaffold(
      appBar: AppBar(title: const Text('Tin nhắn')),
      body: PhoneFrame(
        child: RefreshIndicator(
          onRefresh: () => ref.read(conversationsProvider.notifier).refresh(),
          child: _body(context, state),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, ConversationsState state) {
    if (state.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.items.isEmpty) {
      // Scrollable even when empty, so pull-to-refresh still works.
      return ListView(
        padding: const EdgeInsets.all(32),
        children: [
          Text(
            state.error != null
                ? '${state.error}'
                : 'Chưa có tin nhắn nào.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: RetroTokens.inkSoft),
          ),
        ],
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: state.items.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) => _ConversationRow(conversation: state.items[i]),
    );
  }
}

class _ConversationRow extends StatelessWidget {
  const _ConversationRow({required this.conversation});

  final Conversation conversation;

  /// What the row says under the name. A reaction reads as an action rather
  /// than as a message whose text happens to be an emoji.
  String get _preview {
    final last = conversation.lastMessage;
    if (last.isReaction) return 'Đã thả ${last.body} vào khoảnh khắc';
    return last.body;
  }

  @override
  Widget build(BuildContext context) {
    final unread = conversation.unread > 0;
    final photoAssetId = conversation.lastMessage.photoAssetId;

    return ListTile(
      leading: AuthorAvatar(
        name: conversation.displayName,
        avatarUrl: conversation.avatarUrl,
        size: 40,
      ),
      title: Text(
        conversation.label,
        style: TextStyle(
            fontWeight: unread ? FontWeight.w700 : FontWeight.w500),
      ),
      subtitle: Text(_preview, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            Units.timeOfDay(conversation.lastMessage.createdAt),
            style: const TextStyle(fontSize: 11, color: RetroTokens.inkFaint),
          ),
          // The photo the last message answers, so a row reads in context.
          if (photoAssetId != null) ...[
            const SizedBox(width: 8),
            SizedBox(
              height: 40,
              width: 32,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: MomentPhoto(assetId: photoAssetId),
              ),
            ),
          ],
          if (unread)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: RetroTokens.accent,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '${conversation.unread}',
                  style: const TextStyle(
                      fontSize: 10,
                      color: Colors.white,
                      fontWeight: FontWeight.w700),
                ),
              ),
            ),
        ],
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ConversationScreen(
            userId: conversation.userId,
            title: conversation.label,
          ),
        ),
      ),
    );
  }
}
