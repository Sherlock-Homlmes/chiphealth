import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import 'floating_emoji.dart';

/// The emoji that sit beside the message box, plus the picker behind "+".
/// One reaction per person: tapping a second one replaces the first.
const kQuickReactions = ['❤️', '🔥', '😂'];

/// What the "+" opens. A fixed set rather than a system emoji keyboard: the
/// point is one tap, not a search box.
const kMoreReactions = [
  '😮', '😍', '🥹', '😭', '😅', '🤣',
  '👍', '👏', '🙌', '💪', '🎉', '✨',
  '😎', '🤔', '🥰', '😱', '💯', '🍀',
];

/// What sits under a moment: a box to write in on the left, the reactions on
/// the right. Nothing else — what gets sent goes to the messages list, which is
/// where the conversation is read.
class MomentComposer extends ConsumerStatefulWidget {
  const MomentComposer({super.key, required this.moment});

  final Moment moment;

  @override
  ConsumerState<MomentComposer> createState() => _MomentComposerState();
}

class _MomentComposerState extends ConsumerState<MomentComposer> {
  final _controller = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _failed(Object err) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('$err')));
  }

  Future<void> _send() async {
    final body = _controller.text.trim();
    if (body.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(momentsRepositoryProvider)
          .replyToMoment(widget.moment.id, body);
      if (!mounted) return;
      _controller.clear();
      FocusScope.of(context).unfocus();
      // It landed in the messages list, so that list should already know.
      await ref.read(conversationsProvider.notifier).refresh();
    } catch (err) {
      _failed(err);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// [origin] is where the emoji should appear to leave from — the icon that
  /// was tapped, so the animation belongs to the thing it confirms.
  Future<void> _react(String emoji, {required BuildContext origin}) async {
    if (_busy) return;
    setState(() => _busy = true);
    // Floated before the request, not after: the tap is what the animation
    // answers, and a slow network should not make it feel dropped.
    floatEmoji(origin, emoji);
    try {
      await ref.read(momentsRepositoryProvider).react(widget.moment.id, emoji);
      await ref.read(conversationsProvider.notifier).refresh();
    } catch (err) {
      _failed(err);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickMore() async {
    final emoji = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: RetroTokens.paper,
      constraints: const BoxConstraints(maxWidth: 400),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            alignment: WrapAlignment.center,
            children: [
              for (final emoji in kMoreReactions)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(sheetContext).pop(emoji),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(emoji, style: const TextStyle(fontSize: 28)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (emoji == null || !mounted) return;
    await _react(emoji, origin: context);
  }

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              textInputAction: TextInputAction.send,
              maxLength: 500,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                hintText: 'Gửi tin nhắn…',
                counterText: '',
                isDense: true,
                filled: true,
                fillColor: RetroTokens.paperRaised,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(999),
                  borderSide: const BorderSide(color: RetroTokens.panelLine),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(999),
                  borderSide: const BorderSide(color: RetroTokens.panelLine),
                ),
              ),
            ),
          ),
          for (final emoji in kQuickReactions)
            _ReactionButton(
              emoji: emoji,
              onTap: (origin) => _react(emoji, origin: origin),
            ),
          // One more tap for anything outside the three above.
          IconButton(
            tooltip: 'Thêm biểu cảm',
            onPressed: _busy ? null : _pickMore,
            icon: const Icon(Icons.add_reaction_outlined,
                color: RetroTokens.inkSoft),
          ),
        ],
      );
}

/// One tappable emoji. It hands its own context back so the animation can start
/// from exactly where the finger landed.
class _ReactionButton extends StatelessWidget {
  const _ReactionButton({required this.emoji, required this.onTap});

  final String emoji;
  final ValueChanged<BuildContext> onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onTap(context),
        child: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Text(emoji, style: const TextStyle(fontSize: 24)),
        ),
      );
}

/// Unread-count badge for the messages icon in the app bar.
class MessagesBadge extends ConsumerWidget {
  const MessagesBadge({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(conversationsProvider).unread;

    return Stack(
      alignment: Alignment.center,
      children: [
        IconButton(
          tooltip: 'Tin nhắn',
          icon: const Icon(Icons.chat_bubble_outline),
          onPressed: onTap,
        ),
        if (unread > 0)
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              constraints: const BoxConstraints(minWidth: 16),
              decoration: BoxDecoration(
                color: RetroTokens.accent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                unread > 99 ? '99+' : '$unread',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 10,
                    color: Colors.white,
                    fontWeight: FontWeight.w700),
              ),
            ),
          ),
      ],
    );
  }
}
