import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../core/format/date_range.dart';
import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/repositories/repositories.dart';
import '../../core/storage/uuid.dart';
import '../../core/theme/tokens.dart';
import '../../core/utils/clip_reader.dart';
import '../../widgets/retro_widgets.dart';
import '../home/water_controller.dart';
import '../nutrition/meal_timeline.dart';
import '../sleep/sleep_screen.dart';
import 'typing_effects.dart';

/// "Trợ lý AI": a chat with the health agent.
///
/// The agent answers from the user's own data and may propose writes (log a
/// meal, fix a portion, delete a workout…). A proposal arrives as a card under
/// the reply and nothing happens until the user taps "Xác nhận" on it. Threads
/// are kept server-side; the history sheet switches between them.
class CoachScreen extends ConsumerStatefulWidget {
  const CoachScreen({super.key});

  @override
  ConsumerState<CoachScreen> createState() => _CoachScreenState();
}

class _CoachScreenState extends ConsumerState<CoachScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _messages = <CoachMessage>[];

  /// Dictation, same stack as the manual meal screen: the recorder writes a
  /// throw-away clip, the server transcribes it, the text lands in the box.
  final _recorder = AudioRecorder();
  bool _recording = false;
  bool _transcribing = false;

  /// Photo waiting to go out with the next message, picked but not uploaded:
  /// upload only happens when the user actually sends.
  Uint8List? _photoBytes;

  /// Covers the async gap while the recorder starts or stops, where
  /// [_recording] does not yet reflect reality and a double tap would start a
  /// second recording or stop one already stopped.
  bool _micBusy = false;
  DateTime _recordedFrom = DateTime.now();

  /// Null for a fresh thread: it is only created when the first message goes out,
  /// so opening the screen and leaving does not litter the history.
  String? _conversationId;
  bool _loading = true;
  bool _sending = false;
  Object? _error;

  /// Only the newest reply types itself in; history renders instantly.
  int? _animatingIndex;

  /// Action ids with a confirm/cancel request in flight.
  final _busyActions = <String>{};

  static const _suggestions = [
    'Hôm nay mình ăn đủ chưa?',
    'Lên thực đơn 3 bữa giúp mình giảm cân',
    'Tuần này mình tập luyện thế nào?',
    'Tối qua mình ngủ có đủ không?',
  ];

  @override
  void initState() {
    super.initState();
    _openLatest();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    // Also stops a recording still in flight when the user walks away.
    _recorder.dispose();
    super.dispose();
  }

  CoachRepository get _repo => ref.read(coachRepositoryProvider);

  Future<void> _openLatest() async {
    try {
      final existing = await _repo.conversations();
      if (existing.isEmpty) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      await _open(existing.first.id);
    } catch (err) {
      if (mounted) {
        setState(() {
          _error = err;
          _loading = false;
        });
      }
    }
  }

  Future<void> _open(String id) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final history = await _repo.messages(id);
      if (!mounted) return;
      setState(() {
        _conversationId = id;
        _animatingIndex = null;
        _messages
          ..clear()
          ..addAll(history);
        _loading = false;
      });
      _scrollToEnd(jump: true);
    } catch (err) {
      if (mounted) {
        setState(() {
          _error = err;
          _loading = false;
        });
      }
    }
  }

  void _startNew() {
    setState(() {
      _conversationId = null;
      _messages.clear();
      _animatingIndex = null;
      _error = null;
    });
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _input.text).trim();
    final photo = _photoBytes;
    // Locked while the mic works, so half-dictated text cannot go out. A turn
    // is text, a photo, or both — never an empty one.
    if ((text.isEmpty && photo == null) ||
        _sending ||
        _recording ||
        _transcribing) {
      return;
    }

    // The photo uploads before the bubble appears, so the optimistic message
    // carries the real asset id and renders the actual image; a text-only
    // turn keeps appearing instantly.
    String? photoAssetId;
    if (photo != null) {
      setState(() {
        _sending = true;
        _photoBytes = null;
      });
      try {
        // Same kind and limits as the meal flow; the assistant route accepts
        // the user's own photos of that kind (see backend migration 0008).
        photoAssetId = await ref
            .read(mediaRepositoryProvider)
            .upload(photo, kind: 'meal_photo', mimeType: 'image/jpeg');
      } catch (err) {
        if (mounted) {
          setState(() => _sending = false);
          _snack('$err');
        }
        return;
      }
    }

    setState(() {
      _messages.add(
        CoachMessage(role: 'user', content: text, photoAssetId: photoAssetId),
      );
      if (preset == null) _input.clear();
      _sending = true;
    });
    _scrollToEnd();

    try {
      final id = _conversationId ?? await _repo.startConversation();
      _conversationId = id;
      // Water lives only on this device, so the agent hears it from here.
      final today = DateRange.iso(DateTime.now());
      final reply = await _repo.send(
        id,
        text,
        photoAssetId: photoAssetId,
        waterMlToday: ref.read(waterProvider(today)),
        waterTargetMl: ref.read(waterTargetProvider),
      );
      if (!mounted) return;
      setState(() {
        _messages.add(reply);
        _animatingIndex = _messages.length - 1;
      });
      _scrollToEnd();
    } catch (err) {
      if (mounted) _snack('$err');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Gallery pick, tuned like the meal photo flow: 1600 px and quality 85 is
  /// what the vision model needs without shipping camera-sized files.
  Future<void> _pickPhoto() async {
    if (_sending || _recording || _transcribing) return;
    final shot = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 1600,
    );
    if (shot == null) return;
    final bytes = await shot.readAsBytes();
    if (!mounted) return;
    setState(() => _photoBytes = bytes);
  }

  /// Tap-to-talk: one tap starts recording, the next stops it and dictates.
  Future<void> _toggleMic() async {
    if (_micBusy || _transcribing || _sending) return;
    _micBusy = true;
    try {
      if (_recording) {
        final path = await _recorder.stop();
        final spokenFor = DateTime.now().difference(_recordedFrom);
        if (!mounted) {
          if (path != null) unawaited(deleteClip(path));
          return;
        }
        setState(() => _recording = false);
        // A tap-length burst is not speech; transcribing it would only earn
        // a "không nghe rõ".
        if (spokenFor < const Duration(milliseconds: 500)) {
          _snack('Đoạn ghi quá ngắn — bấm mic để nói rồi bấm lại khi hết.');
          if (path != null) unawaited(deleteClip(path));
          return;
        }
        if (path != null) await _dictate(path);
        return;
      }
      if (!await _recorder.hasPermission()) {
        if (mounted) _snack('Chưa được cấp quyền micro.');
        return;
      }
      if (!mounted) return;
      // `record` ignores the path on web and hands back a blob: URL, but on a
      // phone it writes exactly this file. The cache dir is inside the app
      // sandbox and swept by the OS; the uuid name keeps a re-record from
      // clobbering an in-flight transcription.
      final clipPath = kIsWeb
          ? ''
          : p.join(
              (await getTemporaryDirectory()).path,
              'dictation_${uuidV7()}.m4a',
            );
      // Browsers record Opus in WebM; AAC is what the phones encode natively.
      await _recorder.start(
        RecordConfig(encoder: kIsWeb ? AudioEncoder.opus : AudioEncoder.aacLc),
        path: clipPath,
      );
      _recordedFrom = DateTime.now();
      setState(() => _recording = true);
    } catch (err) {
      // A recorder that cannot start or stop (audio session taken by a call,
      // storage full…) must surface in the UI, not as an unhandled async
      // error from the tap handler.
      if (mounted) {
        setState(() => _recording = false);
        _snack('$err');
      }
    } finally {
      _micBusy = false;
    }
  }

  /// Appends the clip's text to the input box — never replaces what is there,
  /// and never sends: the user reviews the transcript before hitting send.
  Future<void> _dictate(String audioPath) async {
    setState(() => _transcribing = true);
    try {
      final text =
          (await ref
                  .read(nutritionRepositoryProvider)
                  .transcribeClip(
                    await readClip(audioPath),
                    mimeType: kIsWeb ? 'audio/webm' : 'audio/mp4',
                  ))
              .trim();
      if (text.isEmpty || !mounted) return;
      final current = _input.text.trimRight();
      var joined = current.isEmpty ? text : '$current $text';
      // The field's own cap: without this the next keystroke would re-apply
      // the formatter and abruptly eat whatever landed past the limit.
      if (joined.length > 4000) joined = joined.substring(0, 4000);
      _input.value = TextEditingValue(
        text: joined,
        selection: TextSelection.collapsed(offset: joined.length),
      );
    } catch (err) {
      if (mounted) _snack('$err');
    } finally {
      // The bytes are in memory by now (or the read failed); either way the
      // temp file has no further purpose.
      unawaited(deleteClip(audioPath));
      if (mounted) setState(() => _transcribing = false);
    }
  }

  Future<void> _resolve(CoachAction action, {required bool confirm}) async {
    setState(() => _busyActions.add(action.id));
    try {
      final outcome = confirm
          ? await _repo.confirmAction(action.id)
          : await _repo.cancelAction(action.id);
      if (!mounted) return;

      final waterMl = outcome.waterMl;
      if (waterMl != null) {
        await ref.read(waterProvider(outcome.waterDate!).notifier).add(waterMl);
      }
      if (confirm) _refreshData();

      setState(() {
        for (var i = 0; i < _messages.length; i++) {
          final m = _messages[i];
          if (!m.actions.any((a) => a.id == action.id)) continue;
          _messages[i] = m.copyWith(
            actions: [
              for (final a in m.actions) a.id == action.id ? outcome.action : a,
            ],
          );
        }
        _messages.add(outcome.message);
      });
      _scrollToEnd();
    } catch (err) {
      if (mounted) _snack('$err');
    } finally {
      if (mounted) setState(() => _busyActions.remove(action.id));
    }
  }

  /// A confirmed write can touch any screen the user returns to.
  void _refreshData() {
    ref
      ..invalidate(dailyNutritionProvider)
      ..invalidate(nutritionRangeProvider)
      ..invalidate(mealTimelineProvider)
      ..invalidate(workoutFeedProvider)
      ..invalidate(personalRecordsProvider)
      ..invalidate(sleepDebtProvider)
      ..invalidate(sleepSessionsProvider)
      ..invalidate(bodyMetricsRangeProvider)
      ..invalidate(allBodyMetricsProvider);
  }

  void _openLink(CoachAction action) {
    final id = action.linkId;
    switch (action.linkType) {
      case 'meal':
        context.push('/meals/$id');
      case 'workout':
        context.push('/workouts/$id');
      case 'sleep':
        context.go('/sleep');
    }
  }

  Future<void> _showHistory() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (_) => _HistorySheet(current: _conversationId),
    );
    if (picked == null || !mounted) return;
    if (picked == _HistorySheet.newThread) {
      _startNew();
    } else if (picked.startsWith(_HistorySheet.deletedPrefix)) {
      if (picked.substring(_HistorySheet.deletedPrefix.length) ==
          _conversationId) {
        _startNew();
      }
    } else {
      await _open(picked);
    }
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  void _scrollToEnd({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final end = _scroll.position.maxScrollExtent;
      if (jump) {
        _scroll.jumpTo(end);
      } else {
        _scroll.animateTo(
          end,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trợ lý AI'),
        actions: [
          IconButton(
            tooltip: 'Cuộc trò chuyện',
            icon: const Icon(Icons.history),
            onPressed: _sending ? null : _showHistory,
          ),
          IconButton(
            tooltip: 'Cuộc trò chuyện mới',
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: _sending ? null : _startNew,
          ),
        ],
      ),
      body: PhoneFrame(
        // Tapping outside the composer — a bubble, empty space — drops keyboard
        // focus so the keyboard hides. Interactive children (buttons, the text
        // field, selectable text) win their own taps first.
        child: GestureDetector(
          onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
          child: Column(
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    '$_error',
                    style: const TextStyle(color: RetroTokens.accent),
                  ),
                ),
              Expanded(child: _body()),
              _composer(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_messages.isEmpty && !_sending) {
      return _EmptyState(suggestions: _suggestions, onPick: _send);
    }
    return ListView.builder(
      controller: _scroll,
      // Scrolling the thread also puts the keyboard away, like messengers do.
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.all(16),
      itemCount: _messages.length + (_sending ? 1 : 0),
      itemBuilder: (_, i) {
        if (i == _messages.length) return const CoachThinkingIndicator();
        final message = _messages[i];
        final animating = i == _animatingIndex && !message.isUser;
        return Column(
          crossAxisAlignment: message.isUser
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            _Bubble(
              message: message,
              animate: animating,
              onFinished: () {
                if (mounted) setState(() => _animatingIndex = null);
              },
            ),
            // Cards wait for the reply to finish typing, so the user reads what
            // is proposed before being asked to confirm it.
            if (!animating)
              for (final action in message.actions)
                _ActionCard(
                  action: action,
                  busy: _busyActions.contains(action.id),
                  onConfirm: () => _resolve(action, confirm: true),
                  onCancel: () => _resolve(action, confirm: false),
                  onOpen: () => _openLink(action),
                ),
          ],
        );
      },
    );
  }

  Widget _composer() => Container(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
    decoration: const BoxDecoration(
      color: RetroTokens.paperRaised,
      border: Border(
        top: BorderSide(color: RetroTokens.ink, width: RetroTokens.border),
      ),
    ),
    child: SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_photoBytes != null) _photoChip(),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 4,
                  // The API's own cap; past it the send would only bounce.
                  inputFormatters: [LengthLimitingTextInputFormatter(4000)],
                  decoration: InputDecoration(
                    hintText: _recording
                        ? 'Đang nghe… bấm mic để dừng'
                        : _transcribing
                        ? 'Đang chuyển giọng nói thành chữ…'
                        : 'Hỏi về ăn uống, tập luyện, giấc ngủ…',
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Gửi kèm ảnh',
                onPressed: _sending || _recording || _transcribing
                    ? null
                    : _pickPhoto,
                icon: const Icon(Icons.add_photo_alternate_outlined, size: 22),
              ),
              const SizedBox(width: 4),
              _micButton(),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _sending || _recording || _transcribing
                    ? null
                    : _send,
                child: const Icon(Icons.send, size: 18),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  /// The photo about to go out with the next message: thumbnail, a hint that
  /// it can go out alone, and a remove button.
  Widget _photoChip() => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            _photoBytes!,
            width: 56,
            height: 56,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          ),
        ),
        const SizedBox(width: 8),
        const Expanded(
          child: Text(
            'Ảnh sẽ gửi kèm — có thể bỏ trống lời nhắn',
            style: TextStyle(fontSize: 12),
          ),
        ),
        IconButton(
          tooltip: 'Bỏ ảnh',
          onPressed: _sending ? null : () => setState(() => _photoBytes = null),
          icon: const Icon(Icons.close, size: 18),
        ),
      ],
    ),
  );

  /// Mic dictation in the composer. Styled after the meal screen's mic — the
  /// one other place in the app that records — so both mics read as the same
  /// affordance: green circle at rest, accent and grown while listening,
  /// spinner while the clip is being transcribed.
  Widget _micButton() {
    if (_transcribing) {
      return const SizedBox(
        height: 22,
        width: 22,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return Tooltip(
      message: _recording ? 'Dừng nghe' : 'Nói',
      child: GestureDetector(
        onTap: _sending ? null : _toggleMic,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: _recording ? 48 : 40,
          width: _recording ? 48 : 40,
          decoration: BoxDecoration(
            color: _recording ? RetroTokens.accent : RetroTokens.action,
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.mic, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}

class _Bubble extends ConsumerWidget {
  const _Bubble({
    required this.message,
    required this.animate,
    required this.onFinished,
  });

  final CoachMessage message;
  final bool animate;
  final VoidCallback onFinished;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      // 78% of the 400-wide phone frame, as a constant: the frame already caps
      // the screen, so reading the window here would let bubbles outgrow it on
      // a tablet.
      constraints: const BoxConstraints(maxWidth: 312),
      decoration: BoxDecoration(
        color: message.isUser
            ? RetroTokens.accentSoft
            : RetroTokens.paperRaised,
        border: Border.all(color: RetroTokens.ink, width: RetroTokens.border),
        borderRadius: BorderRadius.circular(RetroTokens.radiusLg),
        boxShadow: const [RetroTokens.shadowSm],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Photo-only turns (empty text) must not leave an empty text node.
          if (message.photoAssetId != null)
            _BubblePhoto(assetId: message.photoAssetId!),
          if (message.content.isNotEmpty)
            animate
                ? TypewriterText(text: message.content, onFinished: onFinished)
                : SelectableText(message.content),
        ],
      ),
    );
  }
}

/// The photo inside a user bubble. Loaded through the API (private asset) via
/// a provider, so scroll-throughs reuse the bytes instead of refetching.
class _BubblePhoto extends ConsumerWidget {
  const _BubblePhoto({required this.assetId});

  final String assetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(mediaBytesProvider(assetId));
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: bytes.when(
          data: (b) => Image.memory(
            b,
            width: 220,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          ),
          loading: () => const SizedBox(
            width: 220,
            height: 140,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          ),
          error: (e, _) => SizedBox(
            width: 220,
            height: 56,
            child: Center(
              child: Text(
                'Không tải được ảnh',
                style: TextStyle(fontSize: 12, color: RetroTokens.inkFaint),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One proposed write. Pending cards carry the only buttons that change data;
/// resolved ones stay in the thread as a record of what was done.
class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.action,
    required this.busy,
    required this.onConfirm,
    required this.onCancel,
    required this.onOpen,
  });

  final CoachAction action;
  final bool busy;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;
  final VoidCallback onOpen;

  static IconData _icon(String tool) {
    if (tool.contains('meal')) return Icons.restaurant;
    if (tool.contains('workout')) return Icons.directions_run;
    if (tool.contains('sleep')) return Icons.bedtime;
    if (tool.contains('water')) return Icons.water_drop;
    return Icons.monitor_weight;
  }

  (String, Color, Color) get _status {
    // Confirmed, then the target was deleted — a record, nothing to open.
    if (action.deleted) {
      return ('Đã xóa', RetroTokens.inkFaint, RetroTokens.paperSunk);
    }
    return switch (action.status) {
      'confirmed' => ('Đã thực hiện', RetroTokens.ok, RetroTokens.okSoft),
      'cancelled' => ('Đã huỷ', RetroTokens.inkFaint, RetroTokens.paperSunk),
      'failed' => (
        'Không thực hiện được',
        RetroTokens.accent,
        RetroTokens.accentSoft,
      ),
      'expired' => ('Đã hết hạn', RetroTokens.inkFaint, RetroTokens.paperSunk),
      _ => ('Chờ xác nhận', RetroTokens.warn, RetroTokens.warnSoft),
    };
  }

  @override
  Widget build(BuildContext context) {
    final (label, tone, background) = _status;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      constraints: const BoxConstraints(maxWidth: 312),
      child: RetroBox(
        shadow: action.isPending,
        color: action.isPending ? RetroTokens.paperRaised : RetroTokens.paper,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_icon(action.tool), size: 18, color: RetroTokens.ink),
                const SizedBox(width: 8),
                RetroChip(label, tone: tone, background: background),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              action.summary,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            for (final line in action.details)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  line,
                  style: const TextStyle(
                    fontSize: 12,
                    color: RetroTokens.inkSoft,
                  ),
                ),
              ),
            if (action.status == 'failed' && action.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  action.error!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: RetroTokens.accent,
                  ),
                ),
              ),
            if (action.isPending) ...[
              const SizedBox(height: 10),
              if (busy)
                const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton(
                      onPressed: onCancel,
                      child: const Text('Huỷ'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: onConfirm,
                      child: const Text('Xác nhận'),
                    ),
                  ],
                ),
            ] else if (action.status == 'confirmed' &&
                action.linkType != null &&
                !action.deleted)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(onPressed: onOpen, child: const Text('Mở')),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.suggestions, required this.onPick});

  final List<String> suggestions;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Icon(Icons.smart_toy_outlined, size: 40, color: RetroTokens.ink),
        const SizedBox(height: 12),
        const Text(
          'Trợ lý AI',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        const Text(
          'Hỏi về bữa ăn, tập luyện, giấc ngủ của bạn. Trợ lý đọc dữ liệu '
          'bạn đã ghi, và có thể ghi hay sửa giúp — luôn chờ bạn xác nhận '
          'trước.',
          textAlign: TextAlign.center,
          style: TextStyle(color: RetroTokens.inkSoft),
        ),
        const SizedBox(height: 20),
        for (final s in suggestions)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: RetroBox(
              shadow: false,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              onTap: () => onPick(s),
              child: Text(s),
            ),
          ),
      ],
    );
  }
}

/// Past threads. Pops with a conversation id, [newThread], or
/// `[deletedPrefix]<id>` after a delete so the screen can drop an open thread.
class _HistorySheet extends ConsumerStatefulWidget {
  const _HistorySheet({required this.current});

  final String? current;

  static const newThread = '__new__';
  static const deletedPrefix = '__deleted__:';

  @override
  ConsumerState<_HistorySheet> createState() => _HistorySheetState();
}

class _HistorySheetState extends ConsumerState<_HistorySheet> {
  late Future<List<CoachConversation>> _future = _load();
  String? _deleted;

  Future<List<CoachConversation>> _load() =>
      ref.read(coachRepositoryProvider).conversations();

  Future<void> _delete(CoachConversation c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Xoá cuộc trò chuyện?'),
        content: Text(c.title ?? 'Cuộc trò chuyện'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Thôi'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Xoá'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(coachRepositoryProvider).deleteConversation(c.id);
    if (!mounted) return;
    _deleted = c.id;
    setState(() => _future = _load());
  }

  @override
  Widget build(BuildContext context) {
    final format = DateFormat('HH:mm dd/MM');
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        Navigator.of(context).pop(
          _deleted == null ? null : '${_HistorySheet.deletedPrefix}$_deleted',
        );
      },
      child: SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.6,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.add_comment_outlined),
                title: const Text('Cuộc trò chuyện mới'),
                onTap: () => Navigator.of(context).pop(_HistorySheet.newThread),
              ),
              const Divider(height: 1),
              Expanded(
                child: FutureBuilder<List<CoachConversation>>(
                  future: _future,
                  builder: (_, snap) {
                    if (snap.hasError) {
                      return Center(child: Text('${snap.error}'));
                    }
                    if (!snap.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final items = snap.data!;
                    if (items.isEmpty) {
                      return const Center(
                        child: Text('Chưa có cuộc trò chuyện'),
                      );
                    }
                    return ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (_, i) {
                        final c = items[i];
                        final at = c.lastMessageAt;
                        return ListTile(
                          selected: c.id == widget.current,
                          title: Text(
                            c.title ?? 'Cuộc trò chuyện',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: at == null
                              ? null
                              : Text(
                                  format.format(
                                    DateTime.fromMillisecondsSinceEpoch(at),
                                  ),
                                ),
                          trailing: IconButton(
                            tooltip: 'Xoá',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _delete(c),
                          ),
                          onTap: () => Navigator.of(context).pop(c.id),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
