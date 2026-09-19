import 'package:flutter/material.dart';

import '../../core/models/models.dart';
import '../../core/theme/tokens.dart';
import 'activity_format.dart';
import 'workout_photos.dart';

/// What the athlete fills in after a recording, or edits later.
class WorkoutDraft {
  const WorkoutDraft({
    required this.activity,
    required this.title,
    required this.notes,
    this.perceivedExertion,
    this.photoAssetIds = const [],
  });

  final ActivityType? activity;
  final String title;
  final String notes;
  final int? perceivedExertion;

  /// The complete ordered list; the server full-replaces on save.
  final List<String> photoAssetIds;
}

/// Title, sport, notes and perceived exertion — Strava's "Save activity" form.
/// The title starts as the generated one ("Chạy bộ buổi sáng") and keeps
/// following the sport until the athlete types over it.
class WorkoutFormFields extends StatefulWidget {
  const WorkoutFormFields({
    super.key,
    required this.activities,
    required this.startedAt,
    required this.initial,
    required this.onChanged,
  });

  final List<ActivityType> activities;
  final int startedAt;
  final WorkoutDraft initial;
  final ValueChanged<WorkoutDraft> onChanged;

  @override
  State<WorkoutFormFields> createState() => _WorkoutFormFieldsState();
}

class _WorkoutFormFieldsState extends State<WorkoutFormFields> {
  late final _title = TextEditingController(text: widget.initial.title);
  late final _notes = TextEditingController(text: widget.initial.notes);
  late ActivityType? _activity = widget.initial.activity;
  late int? _rpe = widget.initial.perceivedExertion;
  late List<String> _photos = [...widget.initial.photoAssetIds];

  /// True while the title is still the generated one for the current sport.
  late bool _titleIsDefault =
      widget.initial.title == defaultTitleFor(widget.startedAt, _activity);

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _emit() => widget.onChanged(
    WorkoutDraft(
      activity: _activity,
      title: _title.text.trim(),
      notes: _notes.text.trim(),
      perceivedExertion: _rpe,
      photoAssetIds: List.unmodifiable(_photos),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WorkoutPhotoPicker(
          initialIds: _photos,
          onChanged: (ids) {
            _photos = ids;
            _emit();
          },
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _title,
          decoration: const InputDecoration(labelText: 'Tiêu đề'),
          textCapitalization: TextCapitalization.sentences,
          maxLength: 200,
          onChanged: (_) {
            _titleIsDefault = false;
            _emit();
          },
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<ActivityType>(
          initialValue: _activity,
          decoration: const InputDecoration(labelText: 'Môn'),
          items: [
            for (final a in widget.activities)
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
          onChanged: (value) {
            setState(() {
              _activity = value;
              if (_titleIsDefault) {
                _title.text = defaultTitleFor(widget.startedAt, value);
              }
            });
            _emit();
          },
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _notes,
          decoration: const InputDecoration(
            labelText: 'Ghi chú',
            hintText: 'Buổi này thế nào? Chia sẻ thêm…',
            alignLabelWithHint: true,
          ),
          minLines: 3,
          maxLines: 6,
          maxLength: 1000,
          onChanged: (_) => _emit(),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Text(
              'Cảm nhận nỗ lực',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            Text(
              _rpe == null ? 'Chưa chọn' : '$_rpe/10 · ${_rpeLabel(_rpe!)}',
              style: const TextStyle(color: RetroTokens.inkSoft),
            ),
          ],
        ),
        Slider(
          value: (_rpe ?? 0).toDouble(),
          min: 0,
          max: 10,
          divisions: 10,
          label: _rpe == null ? '—' : '$_rpe',
          onChanged: (v) {
            setState(() => _rpe = v == 0 ? null : v.round());
            _emit();
          },
        ),
      ],
    );
  }
}

String _rpeLabel(int rpe) => switch (rpe) {
  <= 2 => 'Rất nhẹ',
  <= 4 => 'Nhẹ',
  <= 6 => 'Vừa',
  <= 8 => 'Nặng',
  _ => 'Tối đa',
};
