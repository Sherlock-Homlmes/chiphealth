import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/retro_widgets.dart';
import 'typing_effects.dart';

class CoachScreen extends ConsumerStatefulWidget {
  const CoachScreen({super.key});

  @override
  ConsumerState<CoachScreen> createState() => _CoachScreenState();
}

class _CoachScreenState extends ConsumerState<CoachScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _messages = <CoachMessage>[];
  String? _conversationId;
  bool _sending = false;
  Object? _error;

  /// Only the newest reply types itself in; history renders instantly.
  int? _animatingIndex;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      final repo = ref.read(coachRepositoryProvider);
      final existing = await repo.conversations();
      final id = existing.isNotEmpty
          ? existing.first['id'] as String
          : await repo.startConversation();
      final history = await repo.messages(id);
      if (!mounted) return;
      setState(() {
        _conversationId = id;
        _messages
          ..clear()
          ..addAll(history);
      });
    } catch (err) {
      if (mounted) setState(() => _error = err);
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    final id = _conversationId;
    if (text.isEmpty || id == null || _sending) return;

    setState(() {
      _messages.add(CoachMessage(role: 'user', content: text));
      _input.clear();
      _sending = true;
    });
    _scrollToEnd();

    try {
      final reply = await ref.read(coachRepositoryProvider).send(id, text);
      if (!mounted) return;
      setState(() {
        _messages.add(reply);
        _animatingIndex = _messages.length - 1;
      });
      _scrollToEnd();
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$err')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Huấn luyện viên')),
      body: PhoneFrame(
        child: Column(
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('$_error',
                    style: const TextStyle(color: RetroTokens.accent)),
              ),
            Expanded(
              child: _conversationId == null && _error == null
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.all(16),
                      itemCount: _messages.length + (_sending ? 1 : 0),
                      itemBuilder: (_, i) {
                        if (i == _messages.length) {
                          return const CoachThinkingIndicator();
                        }
                        final message = _messages[i];
                        return Align(
                          alignment: message.isUser
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 10),
                            padding: const EdgeInsets.all(12),
                            // 78% of the 400-wide phone frame, as a constant:
                            // the frame already caps the screen, so reading
                            // the window here would let bubbles outgrow it on
                            // a tablet.
                            constraints: const BoxConstraints(maxWidth: 312),
                            decoration: BoxDecoration(
                              color: message.isUser
                                  ? RetroTokens.accentSoft
                                  : RetroTokens.paperRaised,
                              border: Border.all(
                                  color: RetroTokens.ink,
                                  width: RetroTokens.border),
                              borderRadius:
                                  BorderRadius.circular(RetroTokens.radiusLg),
                              boxShadow: const [RetroTokens.shadowSm],
                            ),
                            child: i == _animatingIndex && !message.isUser
                                ? TypewriterText(
                                    text: message.content,
                                    onFinished: () {
                                      if (mounted) {
                                        setState(() => _animatingIndex = null);
                                      }
                                    },
                                  )
                                : Text(message.content),
                          ),
                        );
                      },
                    ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              decoration: const BoxDecoration(
                color: RetroTokens.paperRaised,
                border: Border(
                    top: BorderSide(
                        color: RetroTokens.ink, width: RetroTokens.border)),
              ),
              child: SafeArea(
                top: false,
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        minLines: 1,
                        maxLines: 4,
                        decoration:
                            const InputDecoration(hintText: 'Hỏi coach…'),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _sending ? null : _send,
                      child: const Icon(Icons.send, size: 18),
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
