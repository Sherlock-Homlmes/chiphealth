import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/tokens.dart';
import '../core/l10n/gen/app_localizations.dart';

/// Phone-frame layout: the content never stretches past a comfortable reading
/// width on a tablet or a desktop build. Every screen wraps its body in this,
/// so the whole app shares one column width with the home screen.
class PhoneFrame extends StatelessWidget {
  const PhoneFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      child: child,
    ),
  );
}

/// Section header used on every screen, so headings never drift in size/weight.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.action});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text.toUpperCase(),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
              color: RetroTokens.inkSoft,
            ),
          ),
        ),
        if (action != null) action!,
      ],
    ),
  );
}

/// Big number + caption. The number always uses the monospace face.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.value,
    required this.label,
    this.tone = RetroTokens.ink,
    this.onTap,
  });

  final String value;
  final String label;
  final Color tone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => RetroBox(
    onTap: onTap,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // A value like "1,140 kcal" must shrink to fit, not wrap: two lines
        // read as two separate figures. softWrap must be off, or the Text
        // wraps at the tile width before FittedBox can measure it.
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.visible,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(color: tone),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: RetroTokens.inkSoft),
        ),
      ],
    ),
  );
}

class RetroChip extends StatelessWidget {
  const RetroChip(
    this.text, {
    super.key,
    this.tone = RetroTokens.inkSoft,
    this.background,
  });

  final String text;
  final Color tone;
  final Color? background;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: background ?? RetroTokens.paperSunk,
      border: Border.all(color: tone),
      borderRadius: BorderRadius.circular(2),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, color: tone, fontWeight: FontWeight.w600),
    ),
  );
}

/// The one place loading / error / empty are rendered, so no screen can quietly
/// show a blank body.
Widget asyncBody<T>(
  AsyncValue<T> value, {
  required Widget Function(T data) data,
  bool Function(T data)? emptyWhen,
  String? emptyText,
  VoidCallback? onRetry,
}) {
  return value.when(
    loading: () => const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: CircularProgressIndicator(),
      ),
    ),
    error: (err, _) => Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$err',
              textAlign: TextAlign.center,
              style: const TextStyle(color: RetroTokens.accent),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              // A Builder, because this helper is a function and has no
              // context of its own — and the label is localized.
              Builder(
                builder: (context) => OutlinedButton(
                  onPressed: onRetry,
                  child: Text(AppL10n.of(context).thuLai),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
    data: (value) {
      if (emptyWhen?.call(value) ?? false) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Builder(
              builder: (context) => Text(
                emptyText ?? AppL10n.of(context).chuaCoDuLieu,
                style: const TextStyle(color: RetroTokens.inkFaint),
              ),
            ),
          ),
        );
      }
      return data(value);
    },
  );
}
