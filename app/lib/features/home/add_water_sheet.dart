import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/theme/tokens.dart';
import 'water_controller.dart';

/// Asks for an amount in millilitres and adds it to the day. Returns what was
/// added, or null when the sheet was dismissed — callers away from the water
/// card have nothing on screen to show for it and say so themselves.
Future<int?> addWater(
  BuildContext context,
  WidgetRef ref, {
  required String date,
  required int drunk,
  required int target,
}) async {
  final ml = await showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true, // the keyboard must not cover the field
    // Same phone-frame width as every screen, so the sheet never stretches
    // edge-to-edge on a tablet.
    constraints: const BoxConstraints(maxWidth: 400),
    builder: (_) => _AddWaterSheet(drunk: drunk, target: target),
  );
  if (ml == null || ml == 0) return null;
  await ref.read(waterProvider(date).notifier).add(ml);
  return ml;
}

class _AddWaterSheet extends StatefulWidget {
  const _AddWaterSheet({required this.drunk, required this.target});

  final int drunk;
  final int target;

  @override
  State<_AddWaterSheet> createState() => _AddWaterSheetState();
}

class _AddWaterSheetState extends State<_AddWaterSheet> {
  final _field = TextEditingController(text: WaterController.cupMl.toString());

  static const _presets = [100, 200, 250, 330, 500];
  static final _ml = NumberFormat('#,##0');

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _submit([int? amount]) {
    final ml = amount ?? int.tryParse(_field.text.trim()) ?? 0;
    Navigator.of(context).pop(ml.clamp(0, 5000));
  }

  @override
  Widget build(BuildContext context) => Padding(
    // Lifts the sheet above the keyboard.
    padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
    child: SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Thêm nước',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'Hôm nay: ${_ml.format(widget.drunk)} / '
              '${_ml.format(widget.target)} ml',
              style: const TextStyle(fontSize: 12, color: RetroTokens.inkSoft),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final preset in _presets)
                  OutlinedButton(
                    onPressed: () => _submit(preset),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                    ),
                    child: Text('$preset ml'),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _field,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                    decoration: const InputDecoration(
                      labelText: 'Lượng nước',
                      suffixText: 'ml',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(onPressed: _submit, child: const Text('Thêm')),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
