import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../core/providers.dart';
import '../../core/storage/uuid.dart';
import '../../core/utils/clip_reader.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/retro_widgets.dart';

/// Log a meal by writing it down ("nhập tay").
///
/// The box takes free text; the mic button dictates into it. A clip is only
/// transcribed and appended to whatever is already typed — the user reviews
/// the text before "Phân tích" sends it, and the audio is never stored.
class VoiceLogScreen extends ConsumerStatefulWidget {
  const VoiceLogScreen({super.key});

  @override
  ConsumerState<VoiceLogScreen> createState() => _VoiceLogScreenState();
}

class _VoiceLogScreenState extends ConsumerState<VoiceLogScreen> {
  final _recorder = AudioRecorder();
  final _typed = TextEditingController();
  bool _recording = false;
  bool _transcribing = false;
  bool _held = false;
  bool _starting = false;
  DateTime _startedAt = DateTime.now();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _recorder.dispose();
    _typed.dispose();
    super.dispose();
  }

  String _guessMealType() {
    final hour = DateTime.now().hour;
    if (hour < 10) return 'breakfast';
    if (hour < 15) return 'lunch';
    if (hour < 21) return 'dinner';
    return 'snack';
  }

  /// Push-to-talk: recording lasts exactly as long as the finger is down.
  /// [_held] tracks the finger, since the permission prompt and recorder start
  /// are async and the user may already have let go when they finish.
  Future<void> _pressStart() async {
    _held = true;
    if (_busy || _transcribing || _recording || _starting) return;
    _starting = true;
    try {
      if (!await _recorder.hasPermission()) {
        setState(() => _error = 'Chưa được cấp quyền micro.');
        return;
      }
      if (!_held || !mounted) return;
      // `record` ignores the path on web and hands back a blob: URL, but on a
      // phone it writes exactly this file — an empty path there never creates
      // one and reading the clip back dies with PathNotFoundException. The
      // cache dir is inside the app sandbox and swept by the OS; the uuid
      // name keeps a re-record from clobbering an in-flight upload.
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
      _startedAt = DateTime.now();
      setState(() {
        _recording = true;
        _error = null;
      });
    } catch (err) {
      // A recorder that cannot start (audio session taken by a call, storage
      // full…) must surface in the UI, not as an unhandled async error from
      // the pointer listener.
      if (mounted) setState(() => _error = '$err');
      return;
    } finally {
      _starting = false;
    }
    if (!_held) await _pressEnd();
  }

  Future<void> _pressEnd() async {
    _held = false;
    if (!_recording) return;
    final path = await _recorder.stop();
    final heldFor = DateTime.now().difference(_startedAt);
    setState(() => _recording = false);
    // A tap is not speech; sending it would only earn a "không nghe rõ".
    if (heldFor < const Duration(milliseconds: 500)) {
      setState(() => _error = 'Nhấn và giữ nút mic trong lúc nói.');
      if (path != null) unawaited(deleteClip(path));
      return;
    }
    if (path != null) await _dictate(path);
  }

  /// Appends the clip's text to the box — never replaces what is there.
  Future<void> _dictate(String audioPath) async {
    setState(() {
      _transcribing = true;
      _error = null;
    });
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
      final current = _typed.text.trimRight();
      final joined = current.isEmpty ? text : '$current $text';
      _typed.value = TextEditingValue(
        text: joined,
        selection: TextSelection.collapsed(offset: joined.length),
      );
    } catch (err) {
      if (mounted) setState(() => _error = '$err');
    } finally {
      // The bytes are in memory by now (or the read failed); either way the
      // temp file has no further purpose.
      unawaited(deleteClip(audioPath));
      if (mounted) setState(() => _transcribing = false);
    }
  }

  Future<void> _submit() async {
    final transcript = _typed.text.trim();
    if (transcript.isEmpty) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(nutritionRepositoryProvider);
      final meal = await repo.createMeal(mealType: _guessMealType());
      await repo.logSpoken(meal.id, transcript: transcript);
      ref.invalidate(dailyNutritionProvider);
      if (mounted) context.pushReplacement('/meals/${meal.id}');
    } catch (err) {
      if (mounted) setState(() => _error = '$err');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _micButton() {
    if (_transcribing) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox(
          height: 22,
          width: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return Listener(
      onPointerDown: _busy ? null : (_) => _pressStart(),
      onPointerUp: (_) => _pressEnd(),
      onPointerCancel: (_) => _pressEnd(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: _recording ? 56 : 48,
        width: _recording ? 56 : 48,
        decoration: BoxDecoration(
          color: _recording ? RetroTokens.accent : RetroTokens.action,
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.mic, color: Colors.white),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RetroTokens.paper,
      appBar: AppBar(title: const Text('Nhập tay / Nói')),
      body: PhoneFrame(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextField(
              controller: _typed,
              maxLines: 4,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Trưa nay ăn hai bát cơm với thịt kho và canh rau',
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _micButton(),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _recording
                        ? 'Đang nghe… thả tay để dừng'
                        : _transcribing
                        ? 'Đang chuyển giọng nói thành chữ…'
                        : 'Nhấn và giữ mic để nói, chữ sẽ được thêm vào ô trên',
                    style: const TextStyle(
                      color: RetroTokens.inkSoft,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy || _recording || _transcribing ? null : _submit,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
              ),
              child: _busy
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Phân tích'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: const TextStyle(color: RetroTokens.accent),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
