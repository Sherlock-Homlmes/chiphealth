import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import 'moments_feed.dart';
import 'save_image.dart';

enum _MomentAction { share, save, delete }

/// The "…" over your own photo: share it, keep a copy, or take it down. Only
/// the author sees it — the other three actions on a friend's moment are the
/// composer's.
class MomentMenuButton extends ConsumerStatefulWidget {
  const MomentMenuButton({super.key, required this.moment});

  final Moment moment;

  @override
  ConsumerState<MomentMenuButton> createState() => _MomentMenuButtonState();
}

class _MomentMenuButtonState extends ConsumerState<MomentMenuButton> {
  bool _busy = false;

  Future<void> _open() async {
    final action = await showModalBottomSheet<_MomentAction>(
      context: context,
      backgroundColor: RetroTokens.paper,
      constraints: const BoxConstraints(maxWidth: 400),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('Chia sẻ'),
              onTap: () => Navigator.pop(sheetContext, _MomentAction.share),
            ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('Lưu ảnh'),
              onTap: () => Navigator.pop(sheetContext, _MomentAction.save),
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline,
                color: RetroTokens.accent,
              ),
              title: const Text(
                'Xoá',
                style: TextStyle(color: RetroTokens.accent),
              ),
              onTap: () => Navigator.pop(sheetContext, _MomentAction.delete),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;

    switch (action) {
      case _MomentAction.share:
        await _share();
      case _MomentAction.save:
        await _save();
      case _MomentAction.delete:
        await _delete();
    }
  }

  /// The photo itself, not a link: the media endpoint is bearer-authenticated,
  /// so a URL would be useless to whoever receives it.
  Future<Uint8List> _bytes() =>
      ref.read(mediaBytesProvider(widget.moment.photoAssetId).future);

  Future<void> _share() async {
    setState(() => _busy = true);
    try {
      final bytes = await _bytes();
      await SharePlus.instance.share(
        ShareParams(
          text: widget.moment.caption,
          files: [
            XFile.fromData(
              bytes,
              mimeType: 'image/jpeg',
              name: 'chiphealth.jpg',
            ),
          ],
          fileNameOverrides: const ['chiphealth.jpg'],
        ),
      );
    } catch (err) {
      _failed(err);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await saveImage(
        await _bytes(),
        filename: 'chiphealth_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('Đã lưu ảnh vào máy.')));
      }
    } catch (err) {
      _failed(err);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Xoá khoảnh khắc?'),
        content: const Text('Bạn bè sẽ không thấy ảnh này nữa.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Huỷ'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text(
              'Xoá',
              style: TextStyle(color: RetroTokens.accent),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await ref.read(momentsRepositoryProvider).deleteMoment(widget.moment.id);
      ref.read(momentsFeedProvider.notifier).removed(widget.moment.id);
    } catch (err) {
      _failed(err);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _failed(Object err) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('$err')));
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: _busy ? null : _open,
    child: Container(
      height: 32,
      width: 32,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Color(0x66000000),
      ),
      child: _busy
          ? const SizedBox(
              height: 14,
              width: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : const Icon(Icons.more_horiz, size: 20, color: Colors.white),
    ),
  );
}
