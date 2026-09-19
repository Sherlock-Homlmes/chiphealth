import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/providers.dart';
import '../../core/theme/tokens.dart';

/// Strava-style ceiling; the server rejects anything longer (max 5).
const maxWorkoutPhotos = 5;

/// One photo of a session, at whatever size the caller needs: a thumbnail in
/// the feed, a tile in the attach strip, the hero of the detail gallery. Same
/// idea as MealPhotoThumb — one widget so the corner radius and the fallback
/// icon never drift between screens.
class WorkoutPhotoTile extends ConsumerWidget {
  const WorkoutPhotoTile({super.key, required this.assetId, this.size = 84});

  final String assetId;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final radius = size >= 160 ? 28.0 : size >= 72 ? 20.0 : 12.0;
    final placeholder = Container(
      height: size,
      width: size,
      decoration: BoxDecoration(
        color: RetroTokens.paperSunk,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(
        Icons.directions_run,
        size: size >= 160 ? 56 : size >= 72 ? 24 : 18,
        color: RetroTokens.inkFaint,
      ),
    );

    final bytes = ref.watch(mediaBytesProvider(assetId)).valueOrNull;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: bytes != null
          ? Image.memory(
              bytes,
              height: size,
              width: size,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            )
          : placeholder,
    );
  }
}

/// Full-screen swipeable viewer behind a tap on any photo: pinch to zoom,
/// swipe between the session's photos, tap the scrim to close.
Future<void> showWorkoutPhotoViewer(
  BuildContext context,
  List<String> assetIds,
  int initialIndex,
) => showDialog<void>(
  context: context,
  barrierColor: Colors.black87,
  builder: (dialogContext) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => Navigator.of(dialogContext).pop(),
    child: _PhotoViewer(assetIds: assetIds, initialIndex: initialIndex),
  ),
);

class _PhotoViewer extends StatelessWidget {
  const _PhotoViewer({required this.assetIds, required this.initialIndex});

  final List<String> assetIds;
  final int initialIndex;

  @override
  Widget build(BuildContext context) => PageView.builder(
    controller: PageController(initialPage: initialIndex),
    itemCount: assetIds.length,
    itemBuilder: (_, i) => Center(
      child: InteractiveViewer(
        maxScale: 5,
        child: WorkoutPhotoTile(assetId: assetIds[i], size: 400),
      ),
    ),
  );
}

/// The attach strip on the create/edit screens: the photos already attached
/// (each with a remove button), an add tile while under the cap, and a "n/5"
/// counter. Picking runs camera-or-gallery, compresses like meal photos, and
/// uploads before the tile appears — so [onChanged] only ever carries asset
/// ids the server already holds.
class WorkoutPhotoPicker extends ConsumerStatefulWidget {
  const WorkoutPhotoPicker({
    super.key,
    required this.initialIds,
    required this.onChanged,
  });

  final List<String> initialIds;
  final ValueChanged<List<String>> onChanged;

  @override
  ConsumerState<WorkoutPhotoPicker> createState() => _WorkoutPhotoPickerState();
}

class _WorkoutPhotoPickerState extends ConsumerState<WorkoutPhotoPicker> {
  late final List<String> _ids = [...widget.initialIds];
  bool _uploading = false;

  /// The ceiling is enforced server-side too; stopping here keeps the error a
  /// friendly disabled tile instead of a 400 snackbar.
  bool get _full => _ids.length >= maxWorkoutPhotos;

  Future<void> _pick(ImageSource source) async {
    final shot = await ImagePicker().pickImage(
      source: source,
      imageQuality: 85,
      maxWidth: 1600,
    );
    if (shot == null) return;
    final bytes = await shot.readAsBytes();
    if (!mounted) return;

    setState(() => _uploading = true);
    try {
      // 'meal_photo' on purpose: D1 cannot widen media_assets' kind CHECK, so
      // every photo domain rides the kind that already has the right rules —
      // images only, owner-only reads. See 0008_coach_photo.sql.
      final assetId = await ref
          .read(mediaRepositoryProvider)
          .upload(bytes, kind: 'meal_photo', mimeType: 'image/jpeg');
      if (!mounted) return;
      setState(() => _ids.add(assetId));
      widget.onChanged(List.unmodifiable(_ids));
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$err')));
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _chooseSource() => showModalBottomSheet<ImageSource>(
    context: context,
    backgroundColor: RetroTokens.paperRaised,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    constraints: const BoxConstraints(maxWidth: 400),
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            height: 4,
            width: 40,
            decoration: BoxDecoration(
              color: RetroTokens.paperSunk,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera),
            title: const Text(
              'Chụp ảnh',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            onTap: () => Navigator.pop(sheet, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library),
            title: const Text(
              'Chọn từ thư viện',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            onTap: () => Navigator.pop(sheet, ImageSource.gallery),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  ).then((source) => source == null ? null : _pick(source));

  void _remove(int index) {
    setState(() => _ids.removeAt(index));
    widget.onChanged(List.unmodifiable(_ids));
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const Text(
            'Ảnh hoạt động',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          Text(
            '${_ids.length}/$maxWorkoutPhotos',
            style: const TextStyle(color: RetroTokens.inkSoft, fontSize: 12),
          ),
        ],
      ),
      const SizedBox(height: 8),
      SizedBox(
        height: 88,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (var i = 0; i < _ids.length; i++)
              Padding(
                padding: EdgeInsets.only(right: i == _ids.length - 1 ? 0 : 8),
                child: _removableTile(_ids[i], i),
              ),
            if (!_full)
              Padding(
                padding: EdgeInsets.only(left: _ids.isEmpty ? 0 : 8),
                child: _addTile(),
              ),
          ],
        ),
      ),
    ],
  );

  Widget _removableTile(String assetId, int index) => Stack(
    clipBehavior: Clip.none,
    children: [
      GestureDetector(
        onTap: () => showWorkoutPhotoViewer(context, _ids, index),
        child: WorkoutPhotoTile(assetId: assetId, size: 88),
      ),
      Positioned(
        top: -6,
        right: -6,
        child: GestureDetector(
          onTap: () => _remove(index),
          child: Container(
            height: 22,
            width: 22,
            decoration: const BoxDecoration(
              color: RetroTokens.ink,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.close, size: 14, color: Colors.white),
          ),
        ),
      ),
    ],
  );

  Widget _addTile() => InkWell(
    borderRadius: BorderRadius.circular(12),
    onTap: _uploading ? null : _chooseSource,
    child: Container(
      height: 88,
      width: 88,
      decoration: BoxDecoration(
        color: RetroTokens.paperSunk,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: RetroTokens.paperRaised),
      ),
      child: _uploading
          ? const Center(
              child: SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : const Icon(Icons.add_photo_alternate_outlined, size: 28),
    ),
  );
}
