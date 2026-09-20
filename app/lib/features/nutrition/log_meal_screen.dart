import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../core/format/units.dart';
import '../../core/providers.dart';
import '../../core/storage/uuid.dart';
import '../../core/theme/tokens.dart';
import '../../core/utils/clip_reader.dart';
import '../../widgets/retro_widgets.dart';

/// The one way into a meal: a photo (shot or picked) on top, what the camera
/// cannot see typed or dictated underneath.
///
/// The two used to be separate entries in the "+" menu, which made the user
/// choose a method before they had decided what to say. They are one screen
/// now: either half alone is a complete meal, and together the text rides
/// along with the photo as the note the vision model reads.
///
/// A clip is only transcribed and appended to whatever is already typed — the
/// user reviews the text before "Phân tích" sends it, and the audio is never
/// stored.
class LogMealScreen extends ConsumerStatefulWidget {
  const LogMealScreen({super.key});

  @override
  ConsumerState<LogMealScreen> createState() => _LogMealScreenState();
}

class _LogMealScreenState extends ConsumerState<LogMealScreen> {
  final _recorder = AudioRecorder();
  final _typed = TextEditingController();

  Uint8List? _photo;

  /// When the meal was eaten. Defaults to now, because that is the usual case,
  /// but a meal typed up hours later belongs to the hour it was eaten — both
  /// for the diary and for the meal type guessed from it.
  DateTime _at = DateTime.now();
  bool _picking = false;
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

  /// From the chosen hour, not the clock: a dinner logged at midnight is still
  /// dinner. The user can change it on the detail screen either way.
  String _guessMealType() {
    final hour = _at.hour;
    if (hour < 10) return 'breakfast';
    if (hour < 15) return 'lunch';
    if (hour < 21) return 'dinner';
    return 'snack';
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _at,
      // A meal is logged after it is eaten, so the future is not a date it can
      // land on; a year back is more history than the diary needs.
      firstDate: DateTime(now.year - 1),
      lastDate: now,
      helpText: 'Ngày ăn',
      cancelText: 'Huỷ',
      confirmText: 'Chọn',
    );
    if (picked == null) return;
    setState(() {
      _at = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _at.hour,
        _at.minute,
      );
    });
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_at),
      helpText: 'Giờ ăn',
      cancelText: 'Huỷ',
      confirmText: 'Chọn',
    );
    if (picked == null) return;
    setState(() {
      _at = DateTime(_at.year, _at.month, _at.day, picked.hour, picked.minute);
    });
  }

  /// Shutter or library — the same picker either way, so the photo lands in
  /// the same place and the rest of the screen never has to know which.
  Future<void> _pickPhoto(ImageSource source) async {
    if (_picking || _busy) return;
    setState(() => _picking = true);
    try {
      final shot = await ImagePicker().pickImage(
        source: source,
        imageQuality: 85,
        maxWidth: 1600,
      );
      if (shot == null) return;
      final bytes = await shot.readAsBytes();
      if (!mounted) return;
      setState(() {
        _photo = bytes;
        _error = null;
      });
    } catch (err) {
      if (mounted) setState(() => _error = '$err');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
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

  /// With a photo the text is the note the vision model reads alongside it;
  /// without one the text *is* the meal and goes down the spoken path. Either
  /// way the user lands on the same detail screen, which owns the analysis.
  Future<void> _submit() async {
    final text = _typed.text.trim();
    final photo = _photo;
    if (photo == null && text.isEmpty) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(nutritionRepositoryProvider);
      if (photo != null) {
        final assetId = await ref
            .read(mediaRepositoryProvider)
            .upload(photo, kind: 'meal_photo', mimeType: 'image/jpeg');
        final meal = await repo.createMeal(
          mealType: _guessMealType(),
          photoAssetId: assetId,
          note: text.isEmpty ? null : text,
          loggedAt: _at.millisecondsSinceEpoch,
        );
        // A failure to *start* the analysis is not a failure to log the meal:
        // the row exists either way, so the detail screen is opened regardless
        // and owns the error — it is the screen with the retry on it.
        try {
          await repo.analyze(meal.id);
        } catch (_) {
          // Reported on the detail screen, which is about to open.
        }
        ref.invalidate(dailyNutritionProvider);
        if (mounted) context.pushReplacement('/meals/${meal.id}');
        return;
      }

      final meal = await repo.createMeal(
        mealType: _guessMealType(),
        loggedAt: _at.millisecondsSinceEpoch,
      );
      await repo.logSpoken(meal.id, transcript: text);
      ref.invalidate(dailyNutritionProvider);
      if (mounted) context.pushReplacement('/meals/${meal.id}');
    } catch (err) {
      if (mounted) setState(() => _error = '$err');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _photoPanel() {
    final photo = _photo;
    if (photo != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: AspectRatio(
              aspectRatio: 4 / 3,
              child: Image.memory(photo, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _pickPhoto(ImageSource.camera),
                  icon: const Icon(Icons.photo_camera, size: 18),
                  label: const Text('Chụp lại'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _pickPhoto(ImageSource.gallery),
                  icon: const Icon(Icons.photo_library_outlined, size: 18),
                  label: const Text('Đổi ảnh'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Bỏ ảnh',
                onPressed: _busy ? null : () => setState(() => _photo = null),
                icon: const Icon(Icons.close, color: RetroTokens.accent),
              ),
            ],
          ),
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
      decoration: BoxDecoration(
        color: RetroTokens.paperSunk,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          if (_picking)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: SizedBox(
                height: 26,
                width: 26,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else ...[
            const Icon(
              Icons.photo_camera_outlined,
              size: 30,
              color: RetroTokens.inkFaint,
            ),
            const SizedBox(height: 6),
            const Text(
              'Chụp bữa ăn để AI nhận diện từng thành phần',
              textAlign: TextAlign.center,
              style: TextStyle(color: RetroTokens.inkSoft, fontSize: 12),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: RetroTokens.accent,
                    minimumSize: const Size.fromHeight(44),
                  ),
                  onPressed: _busy || _picking
                      ? null
                      : () => _pickPhoto(ImageSource.camera),
                  icon: const Icon(Icons.photo_camera, size: 18),
                  label: const Text('Chụp ảnh'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                  ),
                  onPressed: _busy || _picking
                      ? null
                      : () => _pickPhoto(ImageSource.gallery),
                  icon: const Icon(Icons.photo_library_outlined, size: 18),
                  label: const Text('Thư viện'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// When it was eaten. Two buttons rather than a single field: the date is
  /// almost always today and the time almost never now, so they are tapped at
  /// very different rates.
  Widget _whenRow() => Row(
    children: [
      Expanded(
        child: OutlinedButton.icon(
          onPressed: _busy ? null : _pickDate,
          icon: const Icon(Icons.event, size: 18),
          label: Text(
            Units.dayHeading(
              '${_at.year.toString().padLeft(4, '0')}-'
              '${_at.month.toString().padLeft(2, '0')}-'
              '${_at.day.toString().padLeft(2, '0')}',
            ),
          ),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: OutlinedButton.icon(
          onPressed: _busy ? null : _pickTime,
          icon: const Icon(Icons.schedule, size: 18),
          label: Text(Units.timeOfDay(_at.millisecondsSinceEpoch)),
        ),
      ),
    ],
  );

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
    final hasPhoto = _photo != null;
    // Either half is enough on its own, but an empty screen has nothing to
    // analyse — the button says so by staying off.
    final canSubmit = hasPhoto || _typed.text.trim().isNotEmpty;

    return Scaffold(
      backgroundColor: RetroTokens.paper,
      appBar: AppBar(title: const Text('Ghi bữa ăn')),
      body: PhoneFrame(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _photoPanel(),
            const SizedBox(height: 14),
            _whenRow(),
            const SizedBox(height: 10),
            TextField(
              controller: _typed,
              maxLines: 4,
              maxLength: 500,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: hasPhoto
                    ? 'Mô tả thêm — tuỳ chọn'
                    : 'Bữa ăn của bạn',
                hintText: hasPhoto
                    ? 'VD: phở bò tái, ít bánh; ăn một nửa đĩa…'
                    : 'Trưa nay ăn hai bát cơm với thịt kho và canh rau',
                helperText: hasPhoto
                    ? 'Giúp AI nhận món và khẩu phần chính xác hơn.'
                    : 'Không có ảnh thì chỉ cần gõ hoặc nói, máy tự tách thành phần.',
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: 4),
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
              onPressed:
                  _busy || _recording || _transcribing || _picking || !canSubmit
                  ? null
                  : _submit,
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
