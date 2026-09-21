import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/units.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/retro_widgets.dart';
import '../training/workout_photos.dart';
import 'sleep_screen.dart';

/// The morning after: what the night came to, and the chance to say something
/// about it before it becomes a row in the list.
///
/// A workout gets this (title, note, photos) and a night did not — it saved
/// silently and dropped the user back on the list. Everything here is
/// optional: "Xong" with nothing filled in keeps the night exactly as the
/// recorder saved it.
class SleepReviewScreen extends ConsumerStatefulWidget {
  const SleepReviewScreen({super.key, required this.session});

  final SleepSession session;

  @override
  ConsumerState<SleepReviewScreen> createState() => _SleepReviewScreenState();
}

class _SleepReviewScreenState extends ConsumerState<SleepReviewScreen> {
  late final _title = TextEditingController(text: widget.session.title ?? '');
  late final _notes = TextEditingController(text: widget.session.notes ?? '');
  late List<String> _photos = [...widget.session.photoAssetIds];
  bool _saving = false;

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final session = widget.session;
    try {
      await ref
          .read(sleepRepositoryProvider)
          .updateSession(
            session.id,
            startedAt: session.startedAt,
            endedAt: session.endedAt ?? session.startedAt,
            title: _title.text.trim(),
            notes: _notes.text.trim(),
            photoAssetIds: _photos,
          );
      ref.invalidate(sleepSessionsProvider);
      ref.invalidate(sleepDebtProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$err')));
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final l10n = AppL10n.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.dem),
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? l10n.dangLuu : l10n.hoanThanh),
          ),
        ],
      ),
      body: PhoneFrame(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            RetroBox(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _Stat(
                    label: l10n.thoiGianNgu,
                    value: Units.hoursMinutes(session.totalSleepSeconds ?? 0),
                  ),
                  _Stat(
                    label: l10n.diNguLuc,
                    value: Units.timeOfDay(session.startedAt),
                  ),
                  _Stat(
                    label: l10n.thucDayLuc,
                    value: Units.timeOfDay(
                      session.endedAt ?? session.startedAt,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _title,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: l10n.tieuDeTuyChon),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notes,
              minLines: 3,
              maxLines: 6,
              maxLength: 2000,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: l10n.ghiChu,
                hintText: l10n.buoiNayTheNaoChiaSe,
              ),
            ),
            const SizedBox(height: 4),
            // The same picker a workout uses: camera or library, compressed
            // and uploaded before the tile appears.
            WorkoutPhotoPicker(
              initialIds: _photos,
              onChanged: (ids) => _photos = ids,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
              ),
              child: Text(_saving ? l10n.dangLuu : l10n.hoanThanh),
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(
        value,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 20),
      ),
      const SizedBox(height: 2),
      Text(
        label,
        style: const TextStyle(fontSize: 12, color: RetroTokens.inkSoft),
      ),
    ],
  );
}
