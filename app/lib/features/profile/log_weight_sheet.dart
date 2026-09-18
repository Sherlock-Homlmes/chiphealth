import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import 'profile_screen.dart';

/// Asks for today's weight and records it as of right now. Returns the weight
/// saved, or null when the sheet was dismissed.
Future<double?> logWeight(
  BuildContext context,
  WidgetRef ref, {
  double? current,
}) async {
  final kg = await showModalBottomSheet<double>(
    context: context,
    isScrollControlled: true, // the keyboard must not cover the field
    constraints: const BoxConstraints(maxWidth: 400),
    builder: (_) => _LogWeightSheet(current: current),
  );
  if (kg == null) return null;

  await ref.read(profileRepositoryProvider).addBodyMetric(weightKg: kg);
  // A weigh-in moves every weight chart and, through BMR, today's TDEE.
  ref
    ..invalidate(bodyMetricsRangeProvider)
    ..invalidate(allBodyMetricsProvider)
    ..invalidate(bodyMetricsProvider)
    ..invalidate(meProvider)
    ..invalidate(tdeeInfoProvider)
    ..invalidate(dailyNutritionProvider)
    ..invalidate(nutritionRangeProvider);
  return kg;
}

class _LogWeightSheet extends StatefulWidget {
  const _LogWeightSheet({this.current});

  final double? current;

  @override
  State<_LogWeightSheet> createState() => _LogWeightSheetState();
}

class _LogWeightSheetState extends State<_LogWeightSheet> {
  late final _field = TextEditingController(
    text: widget.current == null ? '' : _trim(widget.current!),
  );
  String? _error;

  static String _trim(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _submit() {
    final kg = double.tryParse(_field.text.trim().replaceAll(',', '.'));
    // Same bounds the API enforces.
    if (kg == null || kg < 20 || kg > 400) {
      setState(() => _error = 'Nhập cân nặng từ 20 đến 400 kg');
      return;
    }
    Navigator.of(context).pop(double.parse(kg.toStringAsFixed(1)));
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
    child: SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Ghi cân nặng',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            const Text(
              'Lưu cân nặng của bạn tại thời điểm này.',
              style: TextStyle(fontSize: 12, color: RetroTokens.inkSoft),
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _field,
                    autofocus: true,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      labelText: 'Cân nặng',
                      suffixText: 'kg',
                      errorText: _error,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: FilledButton(
                    onPressed: _submit,
                    child: const Text('Lưu'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
