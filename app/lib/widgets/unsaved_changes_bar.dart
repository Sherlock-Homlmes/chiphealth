import 'package:flutter/material.dart';

import '../core/theme/tokens.dart';

/// Discord-style save bar: hidden until something changes, then slides up from
/// the bottom with "Đặt lại" and "Lưu". Screens that stage edits locally lay it
/// over their content in a Stack, e.g.
///
/// ```dart
/// Positioned(left: 12, right: 12, bottom: 12, child: UnsavedChangesBar(...))
/// ```
///
/// and pad their scroll view by ~96 at the bottom so the bar never hides the
/// last item.
class UnsavedChangesBar extends StatelessWidget {
  const UnsavedChangesBar({
    super.key,
    required this.visible,
    required this.onReset,
    required this.onSave,
    this.saving = false,
    this.message = 'Có thông tin chưa cập nhật',
  });

  final bool visible;
  final VoidCallback onReset;
  final VoidCallback onSave;

  /// Both buttons lock while the save is in flight.
  final bool saving;
  final String message;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !visible,
    child: AnimatedSlide(
      offset: visible ? Offset.zero : const Offset(0, 2),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          decoration: BoxDecoration(
            color: RetroTokens.ink,
            borderRadius: BorderRadius.circular(RetroTokens.radiusLg),
            boxShadow: const [
              BoxShadow(
                color: Color(0x40000000),
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(
                    color: RetroTokens.paper,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(
                onPressed: saving ? null : onReset,
                style: TextButton.styleFrom(foregroundColor: RetroTokens.paper),
                child: const Text('Đặt lại'),
              ),
              const SizedBox(width: 4),
              FilledButton(
                onPressed: saving ? null : onSave,
                style: FilledButton.styleFrom(
                  backgroundColor: RetroTokens.ok,
                  foregroundColor: Colors.white,
                ),
                child: Text(saving ? 'Đang lưu…' : 'Lưu'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
