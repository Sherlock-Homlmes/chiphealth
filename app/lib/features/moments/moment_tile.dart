import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/units.dart';
import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';

/// One moment as a square-ish card: the photo, its caption, who posted it.
/// Shared by the community screen and the section at the foot of home so the
/// two surfaces cannot drift apart.
class MomentTile extends StatelessWidget {
  const MomentTile({
    super.key,
    required this.moment,
    this.nested = false,
    this.compact = false,
    this.onTap,
  });

  final Moment moment;

  /// Home's community strip: the tiles are small and only ever open the full
  /// feed, so who posted is a face in the corner of the photo rather than a
  /// line of text under it.
  final bool compact;

  /// True when the tile sits inside another card (the community section on
  /// home): the full ink border and hard shadow are the page-level treatment,
  /// and repeating them inside a card draws a doubled frame.
  final bool nested;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => RetroBox(
    padding: EdgeInsets.zero,
    onTap: onTap,
    shadow: !nested,
    borderColor: nested ? RetroTokens.panelLine : RetroTokens.ink,
    borderWidth: nested ? 1 : RetroTokens.border,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: compact
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    MomentPhoto(assetId: moment.photoAssetId),
                    Positioned(top: 6, left: 6, child: AuthorAvatar.of(moment)),
                  ],
                )
              : MomentPhoto(assetId: moment.photoAssetId),
        ),
        if (!compact)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (moment.caption != null)
                  Text(
                    moment.caption!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                Text(
                  '${moment.authorName ?? 'Bạn'} · ${Units.timeOfDay(moment.createdAt)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
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

/// The author's face, small, over the photo. Falls back to the first letter of
/// their name when the identity provider gave us no picture — a blank circle
/// says less than an initial does.
class AuthorAvatar extends StatelessWidget {
  const AuthorAvatar({super.key, this.name, this.avatarUrl, this.size = 22});

  /// The moment's author. A convenience for the common case — a tile knows the
  /// moment, not the two fields inside it.
  AuthorAvatar.of(Moment moment, {Key? key, double size = 22})
    : this(
        key: key,
        name: moment.authorName,
        avatarUrl: moment.authorAvatarUrl,
        size: size,
      );

  final String? name;
  final String? avatarUrl;
  final double size;

  @override
  Widget build(BuildContext context) {
    final url = avatarUrl;
    final label = name ?? 'Bạn';

    // The ring and shadow sit on an outer box; the picture is clipped by its
    // own ClipOval. A decoration's clip does not reach the <img> element the
    // web falls back to for cross-origin avatars (Google's), which then drew
    // square over the circle.
    return Container(
      height: size,
      width: size,
      padding: const EdgeInsets.all(1.5),
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        // A ring, so a light avatar on a light photo still reads as a face.
        color: RetroTokens.paperRaised,
        boxShadow: [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 3,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: ClipOval(
        child: url == null
            ? Center(
                child: Text(
                  label.characters.first.toUpperCase(),
                  style: TextStyle(
                    fontSize: size * 0.5,
                    fontWeight: FontWeight.w700,
                    color: RetroTokens.inkSoft,
                  ),
                ),
              )
            : Image.network(
                url,
                fit: BoxFit.cover,
                width: size,
                height: size,
                // A provider that 403s on a stale picture URL must not paint
                // an exception over the tile.
                errorBuilder: (_, __, ___) => const Icon(
                  Icons.person,
                  size: 14,
                  color: RetroTokens.inkFaint,
                ),
              ),
      ),
    );
  }
}

/// The photo itself. Media sits behind the bearer-authenticated media endpoint,
/// so it is fetched as bytes rather than handed to `Image.network`.
class MomentPhoto extends ConsumerWidget {
  const MomentPhoto({super.key, required this.assetId});

  final String assetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(mediaBytesProvider(assetId));

    return Container(
      width: double.infinity,
      color: RetroTokens.paperSunk,
      alignment: Alignment.center,
      child: bytes.when(
        data: (data) => Image.memory(
          data,
          width: double.infinity,
          height: double.infinity,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          // Decoding happens during paint, where an exception would take the
          // whole grid down rather than the one tile that cannot be decoded.
          errorBuilder: (_, __, ___) => const Icon(
            Icons.broken_image_outlined,
            color: RetroTokens.inkFaint,
          ),
        ),
        loading: () => const SizedBox(
          height: 18,
          width: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        error: (_, __) => IconButton(
          tooltip: 'Tải lại ảnh',
          icon: const Icon(Icons.refresh, color: RetroTokens.inkFaint),
          onPressed: () => ref.invalidate(mediaBytesProvider(assetId)),
        ),
      ),
    );
  }
}
