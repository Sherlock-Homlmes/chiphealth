import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:record/record.dart';

import '../../core/providers.dart';
import '../../core/utils/clip_reader.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/retro_widgets.dart';

/// Log a meal by describing it out loud.
///
/// The clip goes straight to the API and is never stored: the server transcribes
/// it, pulls the components out of the sentence and throws the audio away. The
/// transcript box under the button is the same endpoint without the microphone,
/// which is what "nhập tay" uses and what makes this testable without a mic.
class VoiceLogScreen extends ConsumerStatefulWidget {
  const VoiceLogScreen({super.key, this.typedOnly = false});

  /// "Nhập tay" reuses this screen with the recorder hidden.
  final bool typedOnly;

  @override
  ConsumerState<VoiceLogScreen> createState() => _VoiceLogScreenState();
}

class _VoiceLogScreenState extends ConsumerState<VoiceLogScreen> {
  final _recorder = AudioRecorder();
  final _typed = TextEditingController();
  bool _recording = false;
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

  Future<void> _toggleRecording() async {
    if (_recording) {
      final path = await _recorder.stop();
      setState(() => _recording = false);
      if (path != null) await _submit(audioPath: path);
      return;
    }

    if (!await _recorder.hasPermission()) {
      setState(() => _error = 'Chưa được cấp quyền micro.');
      return;
    }
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc),
      path: '',
    );
    setState(() {
      _recording = true;
      _error = null;
    });
  }

  Future<void> _submit({String? audioPath}) async {
    final transcript = _typed.text.trim();
    if (audioPath == null && transcript.isEmpty) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(nutritionRepositoryProvider);
      final meal = await repo.createMeal(mealType: _guessMealType());
      if (audioPath != null) {
        await repo.logSpoken(
          meal.id,
          audio: await readClip(audioPath),
          mimeType: 'audio/mp4',
        );
      } else {
        await repo.logSpoken(meal.id, transcript: transcript);
      }
      ref.invalidate(dailyNutritionProvider);
      if (mounted) context.pushReplacement('/meals/${meal.id}');
    } catch (err) {
      if (mounted) setState(() => _error = '$err');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RetroTokens.paper,
      appBar: AppBar(title: Text(widget.typedOnly ? 'Nhập tay' : 'Nói')),
      body: PhoneFrame(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (!widget.typedOnly && !kIsWeb) ...[
              Center(
                child: Column(
                  children: [
                    const SizedBox(height: 24),
                    GestureDetector(
                      onTap: _busy ? null : _toggleRecording,
                      child: Container(
                        height: 120,
                        width: 120,
                        decoration: BoxDecoration(
                          color: _recording
                              ? RetroTokens.accent
                              : RetroTokens.action,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _recording ? Icons.stop : Icons.mic,
                          size: 46,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      _recording
                          ? 'Đang nghe… nhấn để dừng'
                          : 'Nhấn rồi kể bữa ăn của bạn',
                      style: const TextStyle(color: RetroTokens.inkSoft),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Ví dụ: "trưa nay ăn hai bát cơm với thịt kho"',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: RetroTokens.inkFaint,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              const Divider(),
              const SizedBox(height: 12),
              const Text(
                'Hoặc gõ ra',
                style: TextStyle(color: RetroTokens.inkSoft),
              ),
              const SizedBox(height: 8),
            ],
            TextField(
              controller: _typed,
              maxLines: 4,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Trưa nay ăn hai bát cơm với thịt kho và canh rau',
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : () => _submit(),
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
