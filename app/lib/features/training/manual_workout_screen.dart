import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/storage/uuid.dart';
import '../../widgets/retro_widgets.dart';
import 'activity_format.dart';
import 'workout_photos.dart';

/// A session typed in after the fact: sport, when, how long and (optionally)
/// how far and how many kcal. Left blank, the server estimates kcal from the
/// sport's MET and the latest weight, and the day's energy budget picks it up.
class ManualWorkoutScreen extends ConsumerStatefulWidget {
  const ManualWorkoutScreen({super.key});

  @override
  ConsumerState<ManualWorkoutScreen> createState() =>
      _ManualWorkoutScreenState();
}

class _ManualWorkoutScreenState extends ConsumerState<ManualWorkoutScreen> {
  final _title = TextEditingController();
  final _hours = TextEditingController(text: '0');
  final _minutes = TextEditingController(text: '30');
  final _distance = TextEditingController();
  final _kcal = TextEditingController();
  final _notes = TextEditingController();

  ActivityType? _activity;
  DateTime _start = DateTime.now().subtract(const Duration(minutes: 30));
  bool _saving = false;
  List<String> _photoIds = const [];

  /// Server preview of what an empty kcal field will be saved as.
  Map<String, dynamic>? _estimate;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    for (final c in [_hours, _minutes, _distance]) {
      c.addListener(_scheduleEstimate);
    }
  }

  void _scheduleEstimate() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _fetchEstimate);
  }

  Future<void> _fetchEstimate() async {
    final activity = _activity;
    final km = _number(_distance);
    final seconds = _durationSeconds;
    if (activity == null || (seconds <= 0 && (km ?? 0) <= 0)) {
      if (mounted) setState(() => _estimate = null);
      return;
    }
    try {
      final e = await ref
          .read(trainingRepositoryProvider)
          .estimate(
            activityTypeId: activity.id,
            durationSeconds: seconds > 0 ? seconds : null,
            distanceM: km == null || km <= 0 ? null : km * 1000,
          );
      if (mounted) setState(() => _estimate = e);
    } catch (_) {
      // Preview only; saving still estimates server-side.
    }
  }

  String? get _estimateText {
    final e = _estimate;
    final kcal = (e?['kcal'] as num?)?.round();
    if (e == null || kcal == null) return null;
    final met = (e['met'] as num?)?.toStringAsFixed(1);
    final kg = (e['weightKg'] as num).toStringAsFixed(0);
    final mins = (((e['seconds'] as num?) ?? 0) / 60).round();
    final parts = [
      'MET $met × $kg kg${e['weightIsFallback'] == true ? ' (chưa có cân nặng, lấy mặc định)' : ''}',
      e['secondsFromDistance'] == true
          ? '~$mins phút theo tốc độ trung bình'
          : '$mins phút',
    ];
    return 'Ước tính ≈ $kcal kcal · ${parts.join(' × ')}';
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final c in [_title, _hours, _minutes, _distance, _kcal, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  int get _durationSeconds =>
      ((int.tryParse(_hours.text) ?? 0) * 60 +
          (int.tryParse(_minutes.text) ?? 0)) *
      60;

  double? _number(TextEditingController c) =>
      double.tryParse(c.text.trim().replaceAll(',', '.'));

  Future<void> _pickStart() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _start,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now(),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_start),
    );
    if (time == null) return;
    setState(
      () => _start = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      ),
    );
  }

  Future<void> _save() async {
    final activity = _activity;
    final seconds = _durationSeconds;
    final km = _number(_distance);
    if (activity == null || (seconds <= 0 && (km ?? 0) <= 0)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Chọn môn và nhập thời lượng hoặc quãng đường.'),
        ),
      );
      return;
    }
    setState(() => _saving = true);
    final startedAt = _start.millisecondsSinceEpoch;
    final kcal = _number(_kcal);
    final title = _title.text.trim();
    try {
      final id = uuidV7(_start);
      await ref
          .read(trainingRepositoryProvider)
          .saveSession(
            id: id,
            source: 'manual_entry',
            activityTypeId: activity.id,
            startedAt: startedAt,
            endedAt: seconds > 0 ? startedAt + seconds * 1000 : null,
            durationSeconds: seconds > 0 ? seconds : null,
            movingSeconds: seconds > 0 ? seconds : null,
            distanceM: km == null || km <= 0 ? null : km * 1000,
            caloriesBurnedKcal: kcal == null || kcal <= 0 ? null : kcal,
            title: title.isEmpty ? defaultTitleFor(startedAt, activity) : title,
            notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
            photoAssetIds: _photoIds,
          );
      ref.invalidate(workoutFeedProvider);
      ref.invalidate(personalRecordsProvider);
      ref.invalidate(dailyNutritionProvider);
      if (mounted) context.pushReplacement('/workouts/$id');
    } catch (err) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$err')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final activities = ref.watch(activityTypesProvider);
    final digits = [FilteringTextInputFormatter.digitsOnly];
    final decimal = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))];
    final loc = MaterialLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nhập hoạt động'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('Lưu'),
          ),
        ],
      ),
      body: PhoneFrame(
        child: asyncBody(
          activities,
          data: (list) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              WorkoutPhotoPicker(
                initialIds: _photoIds,
                onChanged: (ids) => _photoIds = ids,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<ActivityType>(
                initialValue: _activity,
                decoration: const InputDecoration(labelText: 'Môn'),
                items: [
                  for (final a in list)
                    DropdownMenuItem(
                      value: a,
                      child: Row(
                        children: [
                          Icon(activityIcon(a.code), size: 18),
                          const SizedBox(width: 8),
                          Text(a.name),
                        ],
                      ),
                    ),
                ],
                onChanged: (v) {
                  setState(() => _activity = v);
                  _fetchEstimate();
                },
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: _pickStart,
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Bắt đầu lúc',
                    suffixIcon: Icon(Icons.event),
                  ),
                  child: Text(
                    '${loc.formatShortDate(_start)} · '
                    '${loc.formatTimeOfDay(TimeOfDay.fromDateTime(_start), alwaysUse24HourFormat: true)}',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _hours,
                      decoration: const InputDecoration(labelText: 'Giờ'),
                      keyboardType: TextInputType.number,
                      inputFormatters: digits,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _minutes,
                      decoration: const InputDecoration(labelText: 'Phút'),
                      keyboardType: TextInputType.number,
                      inputFormatters: digits,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _distance,
                decoration: const InputDecoration(
                  labelText: 'Quãng đường (km) — tuỳ chọn',
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: decimal,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _kcal,
                decoration: InputDecoration(
                  labelText: 'Calo đốt (kcal) — tuỳ chọn',
                  hintText: _estimate?['kcal'] == null
                      ? null
                      : '${(_estimate!['kcal'] as num).round()}',
                  helperText:
                      _estimateText ??
                      'Để trống: tự ước tính theo môn, thời lượng / quãng '
                          'đường và cân nặng.',
                  helperMaxLines: 3,
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: decimal,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _title,
                decoration: const InputDecoration(
                  labelText: 'Tiêu đề — tuỳ chọn',
                ),
                textCapitalization: TextCapitalization.sentences,
                maxLength: 200,
              ),
              TextField(
                controller: _notes,
                decoration: const InputDecoration(
                  labelText: 'Ghi chú',
                  alignLabelWithHint: true,
                ),
                minLines: 2,
                maxLines: 5,
                maxLength: 1000,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
