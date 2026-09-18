import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';

/// Shown between the shutter and the upload: the photo, plus an optional line
/// for what the camera cannot see ("phở bò tái, ít bánh", "ăn 1/2 đĩa").
/// The text goes to the vision model with the photo.
///
/// Returns null when the user backs out, '' when they skip the note.
Future<String?> showMealHintSheet(BuildContext context, Uint8List photo) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (_) => _MealHintSheet(photo: photo),
    );

class _MealHintSheet extends StatefulWidget {
  const _MealHintSheet({required this.photo});

  final Uint8List photo;

  @override
  State<_MealHintSheet> createState() => _MealHintSheetState();
}

class _MealHintSheetState extends State<_MealHintSheet> {
  final _hint = TextEditingController();

  @override
  void dispose() {
    _hint.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_hint.text.trim());

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: AspectRatio(
                aspectRatio: 4 / 3,
                child: Image.memory(widget.photo, fit: BoxFit.cover),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _hint,
              decoration: const InputDecoration(
                labelText: 'Mô tả thêm — tuỳ chọn',
                hintText: 'VD: phở bò tái, ít bánh; ăn một nửa đĩa…',
                helperText: 'Giúp AI nhận món và khẩu phần chính xác hơn.',
              ),
              textCapitalization: TextCapitalization.sentences,
              minLines: 1,
              maxLines: 3,
              maxLength: 500,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: RetroTokens.accent,
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: _submit,
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Phân tích'),
            ),
          ],
        ),
      ),
    ),
  );
}
