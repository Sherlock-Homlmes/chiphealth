import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme/tokens.dart';

/// The server's cap on a moment caption.
const kMomentCaptionMaxLength = 200;

/// Review before posting a meal to Khoảnh khắc: the photo exactly as friends
/// will see it, and the caption, pre-filled but the user's to rewrite. Returns
/// the caption to post, or null when the user backs out — nothing goes to the
/// feed without that last look.
Future<String?> showMomentComposeDialog(
  BuildContext context, {
  required String photoAssetId,
  required String initialCaption,
}) => showDialog<String>(
  context: context,
  builder: (_) => _MomentComposeDialog(
    photoAssetId: photoAssetId,
    initialCaption: initialCaption,
  ),
);

class _MomentComposeDialog extends ConsumerStatefulWidget {
  const _MomentComposeDialog({
    required this.photoAssetId,
    required this.initialCaption,
  });

  final String photoAssetId;
  final String initialCaption;

  @override
  ConsumerState<_MomentComposeDialog> createState() =>
      _MomentComposeDialogState();
}

class _MomentComposeDialogState extends ConsumerState<_MomentComposeDialog> {
  late final _caption = TextEditingController(
    text: widget.initialCaption.length > kMomentCaptionMaxLength
        ? widget.initialCaption.substring(0, kMomentCaptionMaxLength)
        : widget.initialCaption,
  );

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final photo = ref.watch(mediaBytesProvider(widget.photoAssetId));

    return AlertDialog(
      backgroundColor: RetroTokens.paperRaised,
      title: const Text('Đăng lên Khoảnh khắc'),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: photo.when(
                    data: (bytes) => Image.memory(
                      bytes,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    ),
                    loading: () => const ColoredBox(
                      color: RetroTokens.paperSunk,
                      child: Center(child: CircularProgressIndicator()),
                    ),
                    error: (_, __) => const ColoredBox(
                      color: RetroTokens.paperSunk,
                      child: Center(
                        child: Text(
                          'Không tải được ảnh',
                          style: TextStyle(color: RetroTokens.inkSoft),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _caption,
                autofocus: true,
                minLines: 2,
                maxLines: 5,
                maxLength: kMomentCaptionMaxLength,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Mô tả',
                  hintText: 'Viết vài dòng về bữa ăn…',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Hủy'),
        ),
        FilledButton(
          // No posting a photo that never loaded: what the user reviewed has
          // to be what goes out.
          onPressed: photo.hasValue
              ? () => Navigator.pop(context, _caption.text.trim())
              : null,
          child: const Text('Đăng'),
        ),
      ],
    );
  }
}
