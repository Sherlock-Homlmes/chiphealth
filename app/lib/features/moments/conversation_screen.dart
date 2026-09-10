import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/format/units.dart';
import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/retro_widgets.dart';
import 'moment_tile.dart';

/// One conversation, Instagram-shaped: a message that answers a photo carries
/// the photo pinned above it, so a reply reads in the context of what it
/// answers without leaving the chat.
class ConversationScreen extends ConsumerStatefulWidget {
  const ConversationScreen({
    super.key,
    required this.userId,
    required this.title,
  });

  final String userId;
  final String title;

  @override
  ConsumerState<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends ConsumerState<ConversationScreen> {
  final _controller = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    // Opening the conversation is what clears its badge.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(conversationsProvider.notifier).markRead(widget.userId);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final body = _controller.text.trim();
    if (body.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await ref
          .read(momentsRepositoryProvider)
          .sendMessage(widget.userId, body);
      _controller.clear();
      ref.invalidate(conversationProvider(widget.userId));
      await ref.read(conversationsProvider.notifier).refresh();
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$err')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(conversationProvider(widget.userId));
    final myId = ref.watch(authControllerProvider).user?.id;

    // A message that arrives while the chat is open belongs on screen straight
    // away, not on the next manual refresh.
    ref.listen(momentEventsProvider, (_, next) {
      final event = next.valueOrNull;
      if (event?.event != 'message') return;
      if (event!.data['senderId'] != widget.userId) return;
      ref.invalidate(conversationProvider(widget.userId));
      ref.read(conversationsProvider.notifier).markRead(widget.userId);
    });

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: PhoneFrame(
        child: Column(
          children: [
            Expanded(
              child: messages.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (err, _) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      '$err',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: RetroTokens.accent),
                    ),
                  ),
                ),
                data: (items) => items.isEmpty
                    ? const Center(
                        child: Text(
                          'Chưa có tin nhắn nào.',
                          style: TextStyle(color: RetroTokens.inkSoft),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                        itemCount: items.length,
                        itemBuilder: (_, i) => _Bubble(
                          message: items[i],
                          mine: items[i].senderId == myId,
                        ),
                      ),
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        textInputAction: TextInputAction.send,
                        maxLength: 500,
                        onSubmitted: (_) => _send(),
                        decoration: const InputDecoration(
                          hintText: 'Nhắn tin…',
                          counterText: '',
                          isDense: true,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: _sending ? null : _send,
                      icon: _sending
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.send, color: RetroTokens.accent),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.mine});

  final DirectMessage message;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final photoAssetId = message.photoAssetId;

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          // The pinned photo: what this message is answering.
          if (photoAssetId != null) ...[
            Text(
              mine
                  ? 'Đã trả lời khoảnh khắc'
                  : 'Đã trả lời khoảnh khắc của bạn',
              style: const TextStyle(fontSize: 10, color: RetroTokens.inkFaint),
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                height: 120,
                width: 90,
                child: MomentPhoto(assetId: photoAssetId),
              ),
            ),
            const SizedBox(height: 4),
          ],
          // A reaction is the emoji itself, big and unwrapped — a bubble around
          // one glyph reads as a message about a reaction rather than as one.
          if (message.isReaction)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(message.body, style: const TextStyle(fontSize: 28)),
            )
          else
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              constraints: const BoxConstraints(maxWidth: 260),
              decoration: BoxDecoration(
                color: mine ? RetroTokens.accentSoft : RetroTokens.paperRaised,
                border: Border.all(
                  color: mine ? RetroTokens.accent : RetroTokens.panelLine,
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(message.body),
                  Text(
                    Units.timeOfDay(message.createdAt),
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
    );
  }
}
