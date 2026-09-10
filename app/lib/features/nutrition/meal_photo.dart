import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme/tokens.dart';

/// The meal photo as a square, at whatever size the caller needs: a thumbnail in
/// the diary, a header image on the detail screen, the whole screen while the
/// analysis runs. One widget so the corner radius and the fallback plate icon
/// never drift apart between them.
class MealPhotoThumb extends ConsumerWidget {
  const MealPhotoThumb({super.key, required this.assetId, this.size = 84});

  final String? assetId;
  final double size;

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

    return FutureBuilder<Uint8List>(
      future: ref.read(mediaRepositoryProvider).bytes(assetId!),
      builder: (_, snap) => ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: snap.hasData
            ? Image.memory(
                snap.data!,
                height: size,
                width: size,
                fit: BoxFit.cover,
              )
            : placeholder,
      ),
    );
  }
}
