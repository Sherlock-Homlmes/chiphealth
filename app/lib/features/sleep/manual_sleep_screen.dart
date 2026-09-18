import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/units.dart';
import '../../core/providers.dart';
import '../../widgets/retro_widgets.dart';
import 'sleep_screen.dart';

/// A night typed in after the fact: bedtime, wake-up and how long it took to
/// fall asleep. No stages — the server counts in-bed time minus the latency
/// as sleep. One night per wake-up day, so this replaces a night already
/// logged for that morning.
class ManualSleepScreen extends ConsumerStatefulWidget {
  const ManualSleepScreen({super.key});

  @override
  ConsumerState<ManualSleepScreen> createState() => _ManualSleepScreenState();
}

class _ManualSleepScreenState extends ConsumerState<ManualSleepScreen> {
  final _latency = TextEditingController(text: '15');
  late DateTime _bed;
  late DateTime _wake;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    // Last night 23:00 → this morning 07:00, clamped so it is not in the future.
    final today7 = DateTime(now.year, now.month, now.day, 7);
    _wake = today7.isAfter(now) ? now : today7;
    _bed = DateTime(_wake.year, _wake.month, _wake.day - 1, 23);
  }

  @override
  void dispose() {
    _latency.dispose();
    super.dispose();
  }

  Future<DateTime?> _pick(DateTime initial) async {
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now(),
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  Future<void> _save() async {
    if (!_wake.isAfter(_bed)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Giờ thức dậy phải sau giờ đi ngủ.')),
      );
      return;
    }
    final latencyMin = int.tryParse(_latency.text) ?? 0;
    setState(() => _saving = true);
    try {
      await ref
          .read(sleepRepositoryProvider)
          .upload(
            source: 'manual',
            startedAt: _bed.millisecondsSinceEpoch,
            endedAt: _wake.millisecondsSinceEpoch,
            stages: const [],
            sleepLatencySeconds: latencyMin > 0 ? latencyMin * 60 : null,
          );
      ref.invalidate(sleepDebtProvider);
      ref.invalidate(sleepSessionsProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (err) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$err')));
      }
    }
  }

  String _format(DateTime t) {
    final loc = MaterialLocalizations.of(context);
    return '${loc.formatShortDate(t)} · '
        '${loc.formatTimeOfDay(TimeOfDay.fromDateTime(t), alwaysUse24HourFormat: true)}';
  }

  Widget _timeField(
    String label,
    DateTime value,
    IconData icon,
    ValueChanged<DateTime> onPicked,
  ) {
    return InkWell(
      onTap: () async {
        final picked = await _pick(value);
        if (picked != null) setState(() => onPicked(picked));
      },
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, suffixIcon: Icon(icon)),
        child: Text(_format(value)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final inBed = _wake.difference(_bed);
    final latency = Duration(minutes: int.tryParse(_latency.text) ?? 0);
    final asleep = inBed - latency;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nhập giấc ngủ'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('Lưu'),
          ),
        ],
      ),
      body: PhoneFrame(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _timeField('Đi ngủ lúc', _bed, Icons.bedtime, (v) => _bed = v),
            const SizedBox(height: 12),
            _timeField(
              'Thức dậy lúc',
              _wake,
              Icons.wb_sunny_outlined,
              (v) => _wake = v,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _latency,
              decoration: const InputDecoration(
                labelText: 'Mất bao lâu để ngủ (phút)',
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            if (!inBed.isNegative)
              StatTile(
                value: Units.duration(asleep.isNegative ? 0 : asleep.inSeconds),
                label: 'thời gian ngủ',
              ),
            const SizedBox(height: 12),
            const Text(
              'Mỗi buổi sáng chỉ có một đêm: lưu sẽ thay đêm đã ghi cho '
              'ngày thức dậy đó (nếu có).',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
