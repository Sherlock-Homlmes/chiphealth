import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../widgets/retro_widgets.dart';
import 'activity_format.dart';
import 'workout_form.dart';
import '../../core/l10n/gen/app_localizations.dart';

class WorkoutEditScreen extends ConsumerStatefulWidget {
  const WorkoutEditScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<WorkoutEditScreen> createState() => _WorkoutEditScreenState();
}

class _WorkoutEditScreenState extends ConsumerState<WorkoutEditScreen> {
  WorkoutDraft? _draft;
  bool _saving = false;

  Future<void> _save(WorkoutDraft draft) async {
    final activity = draft.activity;
    if (activity == null) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(trainingRepositoryProvider)
          .update(
            widget.sessionId,
            activityTypeId: activity.id,
            title: draft.title.isEmpty ? null : draft.title,
            notes: draft.notes.isEmpty ? null : draft.notes,
            perceivedExertion: draft.perceivedExertion,
            photoAssetIds: draft.photoAssetIds,
          );
      ref.invalidate(workoutDetailProvider(widget.sessionId));
      ref.invalidate(workoutFeedProvider);
      if (mounted) context.pop();
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
    final detail = ref.watch(workoutDetailProvider(widget.sessionId));
    final activities = ref.watch(activityTypesProvider);
    final list = activities.valueOrNull;
    final data = detail.valueOrNull;
    final session = data == null ? null : WorkoutSession.fromJson(data);
    final type = list
        ?.where((t) => t.id == session?.activityTypeId)
        .firstOrNull;
    final initial = session == null || list == null
        ? null
        : WorkoutDraft(
            activity: type,
            title: session.title ?? defaultWorkoutTitle(context, session, type),
            notes: session.notes ?? '',
            perceivedExertion: session.perceivedExertion,
            photoAssetIds: session.photoAssetIds,
          );
    final draft = _draft ?? initial;

    return Scaffold(
      appBar: AppBar(
        title: Text(AppL10n.of(context).chinhSuaHoatDong),
        actions: [
          TextButton(
            onPressed: _saving || draft == null ? null : () => _save(draft),
            child: Text(AppL10n.of(context).luu),
          ),
        ],
      ),
      body: PhoneFrame(
        child: asyncBody(
          detail,
          data: (_) {
            if (session == null || initial == null) {
              return const LinearProgressIndicator();
            }
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                WorkoutFormFields(
                  activities: list!,
                  startedAt: session.startedAt,
                  initial: initial,
                  onChanged: (d) => setState(() => _draft = d),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
