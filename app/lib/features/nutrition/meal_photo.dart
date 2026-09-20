import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme/tokens.dart';

/// Full-screen viewer behind a tap on a meal photo: pinch to zoom, tap the
/// scrim to close. The same gesture a workout photo answers to
/// (features/training/workout_photos.dart) — a photo in this app zooms.
Future<void> showMealPhotoViewer(BuildContext context, String assetId) =>
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (dialogContext) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(dialogContext).pop(),
        child: Center(
          child: InteractiveViewer(
            maxScale: 5,
            child: MealPhotoThumb(assetId: assetId, size: 400),
          ),
        ),
      ),
    );

/// The meal photo as a square, at whatever size the caller needs: a thumbnail in
/// the diary, a header image on the detail screen, the whole screen while the
/// analysis runs. One widget so the corner radius and the fallback plate icon
/// never drift apart between them.
///
/// [onTap] is what makes it openable; the placeholder never takes a tap, since
/// there is nothing behind it to enlarge.
class MealPhotoThumb extends ConsumerWidget {
  const MealPhotoThumb({
    super.key,
    required this.assetId,
    this.size = 84,
    this.onTap,
  });

  final String? assetId;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Radius tracks the size: a 20 pt corner on a 44 pt tile is a circle.
    final radius = size >= 160
        ? 28.0
        : size >= 72
        ? 20.0
        : 12.0;
    final placeholder = Container(
      height: size,
      width: size,
      decoration: BoxDecoration(
        color: RetroTokens.paperSunk,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(
        Icons.restaurant,
        size: size >= 160
            ? 56
            : size >= 72
            ? 24
            : 18,
        color: RetroTokens.inkFaint,
      ),
    );

    if (assetId == null) return placeholder;

    Widget wrap(Widget child) => onTap == null
        ? child
        : GestureDetector(
            onTap: onTap,
            behavior: HitTestBehavior.opaque,
            child: child,
          );

    // Cached per asset id: the detail screen polls every 2 s while the analysis
    // runs, and a fresh fetch on each rebuild dropped back to the placeholder
    // every time — the photo blinked for the whole wait.
    final bytes = ref.watch(mediaBytesProvider(assetId!)).valueOrNull;
    return wrap(
      ClipRRect(
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
      ),
    );
  }
}
