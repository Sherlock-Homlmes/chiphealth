import 'package:flutter/material.dart';

import '../../core/format/units.dart';
import '../../core/models/models.dart';
import '../../core/l10n/gen/app_localizations.dart';

IconData activityIcon(String? code) => switch (code) {
  'running' || 'trail_running' || 'treadmill' => Icons.directions_run,
  'walking' => Icons.directions_walk,
  'hiking' || 'trekking' => Icons.hiking,
  'cycling' ||
  'mountain_biking' ||
  'indoor_cycling' ||
  'spinning' => Icons.directions_bike,
  'swimming' || 'open_water_swimming' => Icons.pool,
  'rowing' => Icons.rowing,
  'kayaking' => Icons.kayaking,
  'skiing' => Icons.downhill_skiing,
  'snowboarding' => Icons.snowboarding,
  'stair_climbing' => Icons.stairs,
  'badminton' => Icons.sports_tennis,
  'football' || 'futsal' => Icons.sports_soccer,
  'yoga' => Icons.self_improvement,
  _ when code != null && _strength.contains(code) => Icons.fitness_center,
  _ => Icons.sports,
};

const _strength = {
  'gym_strength',
  'powerlifting',
  'bodyweight_training',
  'calisthenics',
  'crossfit',
  'kettlebell',
  'circuit_training',
};

bool _isRide(String? code) =>
    code == 'cycling' ||
    code == 'mountain_biking' ||
    code == 'indoor_cycling' ||
    code == 'spinning';

/// Strava's "Morning Run": the activity plus the part of day it started in.
String defaultWorkoutTitle(
  BuildContext context,
  WorkoutSession s,
  ActivityType? type,
) => defaultTitleFor(context, s.startedAt, type);

String defaultTitleFor(
  BuildContext context,
  int startedAtMs,
  ActivityType? type,
) {
  final hour = DateTime.fromMillisecondsSinceEpoch(startedAtMs).hour;
  final part = switch (hour) {
    >= 4 && < 11 => AppL10n.of(context).buoiSang,
    >= 11 && < 14 => AppL10n.of(context).buoiTrua,
    >= 14 && < 18 => AppL10n.of(context).buoiChieu,
    >= 18 && < 22 => AppL10n.of(context).buoiToi,
    _ => AppL10n.of(context).demKhuya,
  };
  return '${type?.name ?? 'Buổi tập'} $part';
}

/// "Hôm nay lúc 07:12", "Hôm qua lúc 18:40", "3 thg 9, 2026 lúc 06:05".
String workoutWhen(BuildContext context, int startedAtMs, {DateTime? now}) {
  final at = DateTime.fromMillisecondsSinceEpoch(startedAtMs);
  final today = now ?? DateTime.now();
  final day = DateTime(at.year, at.month, at.day);
  final diff = DateTime(today.year, today.month, today.day).difference(day);
  final time =
      '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
  final date = switch (diff.inDays) {
    0 => AppL10n.of(context).homNay,
    1 => AppL10n.of(context).homQua,
    _ => '${at.day} thg ${at.month}, ${at.year}',
  };
  return AppL10n.of(context).workoutWhenAt(date, time);
}

typedef WorkoutStat = ({String label, String value});

/// The three numbers under a feed card's title, picked per sport the way
/// Strava does: rides show speed, runs show pace, non-GPS sports only time.
List<WorkoutStat> workoutStats(
  BuildContext context,
  WorkoutSession s,
  ActivityType? type,
  Units units,
) {
  final hasDistance = (s.distanceM ?? 0) > 0;
  final stats = <WorkoutStat>[];
  if (hasDistance) {
    stats.add((
      label: AppL10n.of(context).quangDuong,
      value: units.distance(s.distanceM),
    ));
    if (_isRide(type?.code)) {
      final secs = s.durationSeconds ?? 0;
      if (secs > 0) {
        final kmh = s.distanceM! / 1000 / (secs / 3600);
        stats.add((
          label: AppL10n.of(context).tocDoTb,
          value: units.isImperial
              ? '${(kmh / 1.609344).toStringAsFixed(1)} mi/h'
              : '${kmh.toStringAsFixed(1)} km/h',
        ));
      }
    } else if (s.avgPaceSecPerKm != null || (s.durationSeconds ?? 0) > 0) {
      stats.add((
        label: 'Pace',
        value: units.pace(
          s.avgPaceSecPerKm ?? s.durationSeconds! / (s.distanceM! / 1000),
        ),
      ));
    }
  }
  stats.add((
    label: AppL10n.of(context).thoiGian,
    value: Units.duration(s.durationSeconds),
  ));
  if (!hasDistance && (s.caloriesBurnedKcal ?? 0) > 0) {
    stats.add((label: 'Calo', value: '${s.caloriesBurnedKcal!.round()} kcal'));
  }
  if (!hasDistance && s.avgHeartRate != null) {
    stats.add((
      label: AppL10n.of(context).nhipTimTb,
      value: '${s.avgHeartRate} bpm',
    ));
  }
  return stats.take(3).toList();
}
