/// Hand-written models — no codegen, so the app compiles straight after
/// `flutter pub get`. Field names mirror api_design.md exactly (camelCase JSON,
/// epoch-millisecond timestamps, metric units, `YYYY-MM-DD` local dates).
library;

int _int(dynamic v, [int fallback = 0]) => (v as num?)?.toInt() ?? fallback;
int? _intOrNull(dynamic v) => (v as num?)?.toInt();
double? _dbl(dynamic v) => (v as num?)?.toDouble();
double _dblOr(dynamic v, [double fallback = 0]) =>
    (v as num?)?.toDouble() ?? fallback;
bool _bool(dynamic v, [bool fallback = false]) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  return fallback;
}

DateTime dateTimeFromMs(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);

/* ----------------------------------------------------------------- identity */

enum UnitSystem { metric, imperial }

class AppUser {
  const AppUser({
    required this.id,
    required this.email,
    this.displayName,
    this.avatarUrl,
    this.role = 'user',
    this.locale = 'vi',
    this.unitSystem = UnitSystem.metric,
    this.timezone = 'Asia/Ho_Chi_Minh',
  });

  final String id;
  final String email;
  final String? displayName;
  final String? avatarUrl;
  final String role;
  final String locale;
  final UnitSystem unitSystem;
  final String timezone;

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
    id: json['id'] as String,
    email: json['email'] as String,
    displayName: json['displayName'] as String?,
    avatarUrl: json['avatarRemoteUrl'] as String?,
    role: json['role'] as String? ?? 'user',
    locale: json['locale'] as String? ?? 'vi',
    unitSystem: json['unitSystem'] == 'imperial'
        ? UnitSystem.imperial
        : UnitSystem.metric,
    timezone: json['timezone'] as String? ?? 'Asia/Ho_Chi_Minh',
  );
}

class UserProfile {
  const UserProfile({
    this.dateOfBirth,
    this.biologicalSex,
    this.activityLevel = 'moderate',
    this.maxHeartRateOverride,
    this.restingHeartRate,
    this.targetSleepMinutes = 480,
    this.bedtimeTarget,
    this.waketimeTarget,
    this.dailyCalorieOverrideKcal,
  });

  final String? dateOfBirth;
  final String? biologicalSex;
  final String activityLevel;
  final int? maxHeartRateOverride;
  final int? restingHeartRate;
  final int targetSleepMinutes;
  final String? bedtimeTarget;
  final String? waketimeTarget;

  /// The user's own daily energy figure; null means the formula decides.
  final double? dailyCalorieOverrideKcal;

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
    dateOfBirth: json['dateOfBirth'] as String?,
    biologicalSex: json['biologicalSex'] as String?,
    activityLevel: json['activityLevel'] as String? ?? 'moderate',
    maxHeartRateOverride: _intOrNull(json['maxHeartRateOverride']),
    restingHeartRate: _intOrNull(json['restingHeartRate']),
    targetSleepMinutes: _int(json['targetSleepMinutes'], 480),
    bedtimeTarget: json['bedtimeTarget'] as String?,
    waketimeTarget: json['waketimeTarget'] as String?,
    dailyCalorieOverrideKcal: _dbl(json['dailyCalorieOverrideKcal']),
  );

  Map<String, dynamic> toJson() => {
    'dateOfBirth': dateOfBirth,
    'biologicalSex': biologicalSex,
    'activityLevel': activityLevel,
    'maxHeartRateOverride': maxHeartRateOverride,
    'restingHeartRate': restingHeartRate,
    'targetSleepMinutes': targetSleepMinutes,
    'bedtimeTarget': bedtimeTarget,
    'waketimeTarget': waketimeTarget,
    'dailyCalorieOverrideKcal': dailyCalorieOverrideKcal,
  };
}

class BodyMetric {
  const BodyMetric({
    required this.recordedAt,
    required this.localDate,
    this.weightKg,
    this.heightCm,
    this.bodyFatPercent,
    this.muscleMassKg,
  });

  final int recordedAt;
  final String localDate;
  final double? weightKg;
  final double? heightCm;
  final double? bodyFatPercent;
  final double? muscleMassKg;

  factory BodyMetric.fromJson(Map<String, dynamic> json) => BodyMetric(
    recordedAt: _int(json['recordedAt']),
    localDate: json['localDate'] as String? ?? '',
    weightKg: _dbl(json['weightKg']),
    heightCm: _dbl(json['heightCm']),
    bodyFatPercent: _dbl(json['bodyFatPercent']),
    muscleMassKg: _dbl(json['muscleMassKg']),
  );
}

class Goal {
  const Goal({
    required this.id,
    required this.goalType,
    required this.startValue,
    required this.status,
    this.targetValue,
    this.targetUnit,
    this.deadline,
    this.priority = 0,
  });

  final String id;
  final String goalType;
  final double startValue;
  final String status;
  final double? targetValue;
  final String? targetUnit;
  final String? deadline;
  final int priority;

  /// 0..1 progress from the baseline snapshot toward the target.
  double progress(double? current) {
    final target = targetValue;
    if (target == null || current == null || target == startValue) return 0;
    final done = (current - startValue) / (target - startValue);
    return done.clamp(0.0, 1.0);
  }

  factory Goal.fromJson(Map<String, dynamic> json) => Goal(
    id: json['id'] as String,
    goalType: json['goalType'] as String,
    startValue: _dblOr(json['startValue']),
    status: json['status'] as String? ?? 'active',
    targetValue: _dbl(json['targetValue']),
    targetUnit: json['targetUnit'] as String?,
    deadline: json['deadline'] as String?,
    priority: _int(json['priority']),
  );
}

class ChronicCondition {
  const ChronicCondition({
    required this.id,
    required this.description,
    this.isActive = true,
  });

  final String id;
  final String description;
  final bool isActive;

  factory ChronicCondition.fromJson(Map<String, dynamic> json) =>
      ChronicCondition(
        id: json['id'] as String,
        description: json['description'] as String,
        isActive: _bool(json['isActive'], true),
      );
}

class ActivityType {
  const ActivityType({
    required this.id,
    required this.code,
    required this.name,
    required this.category,
    required this.supportsGps,
    required this.supportsSets,
  });

  final int id;
  final String code;
  final String name;
  final String category;
  final bool supportsGps;
  final bool supportsSets;

  factory ActivityType.fromJson(Map<String, dynamic> json) => ActivityType(
    id: _int(json['id']),
    code: json['code'] as String,
    name: json['name'] as String? ?? json['code'] as String,
    category: json['category'] as String? ?? 'other',
    supportsGps: _bool(json['supportsGps']),
    supportsSets: _bool(json['supportsSets']),
  );
}

/* ---------------------------------------------------------------- nutrition */

class MealItem {
  const MealItem({
    required this.id,
    required this.ingredientName,
    required this.quantityG,
    required this.caloriesKcal,
    this.quantityLabel,
    this.proteinG,
    this.carbsG,
    this.fatG,
    this.fiberG,
    this.sugarG,
    this.sodiumMg,
    this.waterMl,
    this.source = 'ai_estimated',
    this.confidence,
    this.isUserCorrected = false,
  });

  final int id;
  final String ingredientName;
  final double quantityG;
  final double caloriesKcal;
  final String? quantityLabel;
  final double? proteinG;
  final double? carbsG;
  final double? fatG;
  final double? fiberG;
  final double? sugarG;
  final double? sodiumMg;

  /// Fluid this component carries, in ml — the whole glass for a drink, the
  /// water content for a food. Null when the analysis never estimated it.
  final double? waterMl;
  final String source;
  final double? confidence;
  final bool isUserCorrected;

  factory MealItem.fromJson(Map<String, dynamic> json) => MealItem(
    id: _int(json['id']),
    ingredientName: json['ingredientName'] as String,
    quantityG: _dblOr(json['quantityG']),
    caloriesKcal: _dblOr(json['caloriesKcal']),
    quantityLabel: json['quantityLabel'] as String?,
    proteinG: _dbl(json['proteinG']),
    carbsG: _dbl(json['carbsG']),
    fatG: _dbl(json['fatG']),
    fiberG: _dbl(json['fiberG']),
    sugarG: _dbl(json['sugarG']),
    sodiumMg: _dbl(json['sodiumMg']),
    waterMl: _dbl(json['waterMl']),
    source: json['source'] as String? ?? 'ai_estimated',
    confidence: _dbl(json['confidence']),
    isUserCorrected: _bool(json['isUserCorrected']),
  );

  Map<String, dynamic> toJson() => {
    'ingredientName': ingredientName,
    'quantityG': quantityG,
    'quantityLabel': quantityLabel,
    'caloriesKcal': caloriesKcal,
    'proteinG': proteinG,
    'carbsG': carbsG,
    'fatG': fatG,
    'fiberG': fiberG,
    'sugarG': sugarG,
    'sodiumMg': sodiumMg,
    'waterMl': waterMl,
  };
}

/// One page of the meal timeline. The cursor is opaque to the client: the
/// server encodes `loggedAt:id` so paging is stable when two meals share a
/// timestamp.
class MealPage {
  const MealPage({required this.items, this.nextCursor});

  final List<MealLog> items;
  final String? nextCursor;
}

class MealLog {
  const MealLog({
    required this.id,
    required this.mealType,
    required this.loggedAt,
    required this.localDate,
    required this.totalCaloriesKcal,
    this.dishName,
    this.note,
    this.photoAssetId,
    this.totalProteinG = 0,
    this.totalCarbsG = 0,
    this.totalFatG = 0,
    this.totalWaterMl,
    this.items = const [],
    this.analysisStatus,
    this.analysisFeedback,
    this.analysisTimedOut = false,
    this.analysisStartedAt,
    this.itemCount,
  });

  /// One analysis attempt may run this long before every reader treats it as
  /// failed — the same clock the server applies to `meal_ai_analyses`.
  static const Duration analysisTimeout = Duration(minutes: 5);

  final String id;
  final String mealType;
  final int loggedAt;
  final String localDate;
  final double totalCaloriesKcal;

  /// What the model called the dish. Null for hand-typed meals and while the
  /// analysis is still running.
  final String? dishName;

  /// Whatever the user typed alongside the meal. Not shown on the diary, only
  /// on the meal itself.
  final String? note;
  final String? photoAssetId;
  final double totalProteinG;
  final double totalCarbsG;
  final double totalFatG;

  /// Fluid the whole meal carried, summed from its components. Null until the
  /// analysis has something to say — which is not the same as zero.
  final double? totalWaterMl;
  final List<MealItem> items;
  final String? analysisStatus;

  /// The thumb the user gave this analysis: 'up', 'down', or null for no
  /// verdict yet. Kept per analysis, so a re-run starts unvoted.
  final String? analysisFeedback;

  /// The server reports a run that passed the deadline as failed with
  /// `timedOut: true`, so the UI can offer a retry that reads as such.
  final bool analysisTimedOut;

  /// When the latest attempt started (epoch ms), for the client-side half of
  /// the timeout: bounding the wait even if the server's verdict never arrives.
  final int? analysisStartedAt;

  /// Set by the day view, which lists meals without their components.
  final int? itemCount;

  /// Components known for this meal, whether they were sent inline or counted.
  int get componentCount => itemCount ?? items.length;

  bool get isAnalysing =>
      analysisStatus == 'running' || analysisStatus == 'pending';

  /// The fallback clock: still analysing but past the deadline. The server
  /// normally delivers this verdict inside the poll; this covers the answer
  /// being late or lost so the user is never left waiting forever.
  bool timedOutAt(int nowMs) =>
      isAnalysing &&
      analysisStartedAt != null &&
      nowMs - analysisStartedAt! >= analysisTimeout.inMilliseconds;

  /// A meal whose analysis failed holds nothing worth keeping: it is a draft the
  /// user is asked to retry or throw away.
  /// The day view sends a count instead of the components, so ask the count:
  /// a re-analysis that failed on a meal which still has items is not a draft.
  ///
  /// A meal with no analysis at all counts too: the request that would have
  /// started one never landed (no connection, a rejected response), so the row
  /// is just as empty as a failed run — and showing it as a finished 0 kcal
  /// meal would be a lie. Everything logged by voice, by barcode or by hand
  /// arrives with its components already attached, so the count keeps those out.
  bool get isFailedDraft =>
      componentCount == 0 &&
      (analysisStatus == 'failed' || analysisStatus == null);

  /// The draft above, told apart by *why* it is empty: no attempt was ever
  /// recorded, as opposed to one that ran and failed. The two deserve different
  /// words — one is the network, the other is the model.
  bool get analysisNeverRan => analysisStatus == null && componentCount == 0;

  /// The same meal carrying only these components, with the totals re-summed.
  /// The detail screen stages a removal until the user saves, so it has to be
  /// able to show what the meal *would* be without a component.
  MealLog withItems(List<MealItem> keep) {
    double sum(double? Function(MealItem) pick) =>
        keep.fold(0.0, (s, i) => s + (pick(i) ?? 0));
    return MealLog(
      id: id,
      mealType: mealType,
      loggedAt: loggedAt,
      localDate: localDate,
      totalCaloriesKcal: sum((i) => i.caloriesKcal),
      dishName: dishName,
      note: note,
      photoAssetId: photoAssetId,
      totalProteinG: sum((i) => i.proteinG),
      totalCarbsG: sum((i) => i.carbsG),
      totalFatG: sum((i) => i.fatG),
      totalWaterMl: keep.any((i) => i.waterMl != null)
          ? sum((i) => i.waterMl)
          : null,
      items: keep,
      analysisStatus: analysisStatus,
      analysisFeedback: analysisFeedback,
      analysisTimedOut: analysisTimedOut,
      analysisStartedAt: analysisStartedAt,
      itemCount: keep.length,
    );
  }

  factory MealLog.fromJson(Map<String, dynamic> json) {
    final analysis = json['analysis'] is Map
        ? (json['analysis'] as Map).cast<String, dynamic>()
        : null;
    return MealLog(
      id: json['id'] as String,
      mealType: json['mealType'] as String,
      loggedAt: _int(json['loggedAt']),
      localDate: json['localDate'] as String? ?? '',
      totalCaloriesKcal: _dblOr(json['totalCaloriesKcal']),
      dishName: json['dishName'] as String?,
      note: json['note'] as String?,
      photoAssetId: json['photoAssetId'] as String?,
      totalProteinG: _dblOr(json['totalProteinG']),
      totalCarbsG: _dblOr(json['totalCarbsG']),
      totalFatG: _dblOr(json['totalFatG']),
      totalWaterMl: _dbl(json['totalWaterMl']),
      items:
          (json['items'] as List?)
              ?.whereType<Map>()
              .map((e) => MealItem.fromJson(e.cast<String, dynamic>()))
              .toList() ??
          const [],
      analysisStatus: analysis?['status'] as String?,
      analysisFeedback: analysis?['userFeedback'] as String?,
      analysisTimedOut: analysis?['timedOut'] == true,
      analysisStartedAt: _intOrNull(analysis?['createdAt']),
      itemCount: _intOrNull(json['itemCount']),
    );
  }
}

class DailyNutrition {
  const DailyNutrition({
    required this.date,
    required this.consumedKcal,
    this.bmrKcal,
    this.tdeeKcal,
    this.balanceKcal,
    this.proteinG = 0,
    this.carbsG = 0,
    this.fatG = 0,
    this.fiberG = 0,
    this.sugarG = 0,
    this.sodiumMg = 0,
    this.burnedKcal = 0,
    this.meals = const [],
  });

  final String date;
  final double consumedKcal;
  final double? bmrKcal;
  final double? tdeeKcal;
  final double? balanceKcal;
  final double proteinG;
  final double carbsG;
  final double fatG;
  final double fiberG;
  final double sugarG;
  final double sodiumMg;

  /// Workout calories for the day. Already folded into TDEE by the API, but the
  /// home screen shows it on its own line.
  final double burnedKcal;
  final List<MealLog> meals;

  bool get isDeficit => (balanceKcal ?? 0) < 0;

  factory DailyNutrition.fromJson(Map<String, dynamic> json) {
    final summary = (json['summary'] as Map?)?.cast<String, dynamic>();
    final energy = (json['energy'] as Map?)?.cast<String, dynamic>();
    return DailyNutrition(
      date: json['date'] as String? ?? '',
      consumedKcal: _dblOr(summary?['caloriesConsumedKcal']),
      bmrKcal: _dbl(energy?['bmrKcal'] ?? summary?['bmrKcal']),
      tdeeKcal: _dbl(energy?['tdeeKcal'] ?? summary?['tdeeKcal']),
      balanceKcal: _dbl(summary?['calorieBalanceKcal']),
      proteinG: _dblOr(summary?['proteinG']),
      carbsG: _dblOr(summary?['carbsG']),
      fatG: _dblOr(summary?['fatG']),
      fiberG: _dblOr(summary?['fiberG']),
      sugarG: _dblOr(summary?['sugarG']),
      sodiumMg: _dblOr(summary?['sodiumMg']),
      burnedKcal: _dblOr(summary?['caloriesBurnedWorkoutKcal']),
      meals:
          (json['meals'] as List?)
              ?.whereType<Map>()
              .map((e) => MealLog.fromJson(e.cast<String, dynamic>()))
              .toList() ??
          const [],
    );
  }
}

class MealPlan {
  const MealPlan({
    required this.id,
    required this.planDate,
    required this.mealType,
    required this.title,
    required this.status,
    this.description,
    this.rationale,
    this.targetCaloriesKcal,
  });

  final String id;
  final String planDate;
  final String mealType;
  final String title;
  final String status;
  final String? description;
  final String? rationale;
  final double? targetCaloriesKcal;

  factory MealPlan.fromJson(Map<String, dynamic> json) => MealPlan(
    id: json['id'] as String,
    planDate: json['planDate'] as String,
    mealType: json['mealType'] as String,
    title: json['title'] as String,
    status: json['status'] as String? ?? 'suggested',
    description: json['description'] as String?,
    rationale: json['rationale'] as String?,
    targetCaloriesKcal: _dbl(json['targetCaloriesKcal']),
  );
}

class FoodHit {
  const FoodHit({
    required this.id,
    required this.name,
    required this.servingSizeG,
    required this.caloriesKcal,
    this.brand,
    this.isPersonal = false,
    this.proteinG,
    this.carbsG,
    this.fatG,
  });

  final String id;
  final String name;
  final double servingSizeG;
  final double caloriesKcal;
  final String? brand;
  final bool isPersonal;
  final double? proteinG;
  final double? carbsG;
  final double? fatG;

  factory FoodHit.fromJson(
    Map<String, dynamic> json, {
    bool personal = false,
  }) => FoodHit(
    id: json['id'] as String,
    name: json['name'] as String,
    servingSizeG: _dblOr(json['servingSizeG'], 100),
    caloriesKcal: _dblOr(json['caloriesKcal']),
    brand: json['brand'] as String?,
    isPersonal: personal,
    proteinG: _dbl(json['proteinG']),
    carbsG: _dbl(json['carbsG']),
    fatG: _dbl(json['fatG']),
  );
}

/* ----------------------------------------------------------------- training */

class WorkoutSession {
  const WorkoutSession({
    required this.id,
    required this.activityTypeId,
    required this.startedAt,
    required this.localDate,
    this.title,
    this.endedAt,
    this.durationSeconds,
    this.distanceM,
    this.avgHeartRate,
    this.maxHeartRate,
    this.avgPaceSecPerKm,
    this.elevationGainM,
    this.caloriesBurnedKcal,
    this.source = 'in_app',
    this.polyline,
    this.notes,
    this.perceivedExertion,
    this.photoAssetIds = const [],
  });

  final String id;
  final int activityTypeId;
  final int startedAt;
  final String localDate;
  final String? title;
  final int? endedAt;
  final int? durationSeconds;
  final double? distanceM;
  final int? avgHeartRate;
  final int? maxHeartRate;
  final double? avgPaceSecPerKm;
  final double? elevationGainM;
  final double? caloriesBurnedKcal;
  final String source;

  /// Encoded route (Google polyline, precision 5); null when there is no GPS.
  final String? polyline;
  final String? notes;

  /// 1–10, Strava's "perceived exertion".
  final int? perceivedExertion;

  /// Attached photos, in the order the athlete arranged them (max 5).
  final List<String> photoAssetIds;

  double get distanceKm => (distanceM ?? 0) / 1000;

  factory WorkoutSession.fromJson(Map<String, dynamic> json) => WorkoutSession(
    id: json['id'] as String,
    activityTypeId: _int(json['activityTypeId']),
    startedAt: _int(json['startedAt']),
    localDate: json['localDate'] as String? ?? '',
    title: json['title'] as String?,
    endedAt: _intOrNull(json['endedAt']),
    durationSeconds: _intOrNull(json['durationSeconds']),
    distanceM: _dbl(json['distanceM']),
    avgHeartRate: _intOrNull(json['avgHeartRate']),
    maxHeartRate: _intOrNull(json['maxHeartRate']),
    avgPaceSecPerKm: _dbl(json['avgPaceSecPerKm']),
    elevationGainM: _dbl(json['elevationGainM']),
    caloriesBurnedKcal: _dbl(json['caloriesBurnedKcal']),
    source: json['source'] as String? ?? 'in_app',
    polyline: json['polyline'] as String?,
    notes: json['notes'] as String?,
    perceivedExertion: _intOrNull(json['perceivedExertion']),
    photoAssetIds: (json['photoAssetIds'] as List? ?? const [])
        .whereType<String>()
        .toList(),
  );
}

/// One timed GPS point of a recording (`GET /v1/workouts/:id/track`).
class TrackPoint {
  const TrackPoint({
    required this.t,
    required this.lat,
    required this.lng,
    required this.d,
    this.ele,
    this.hr,
  });

  /// Seconds from the first sample.
  final double t;
  final double lat;
  final double lng;

  /// Cumulative metres.
  final double d;
  final double? ele;
  final int? hr;

  factory TrackPoint.fromJson(Map<String, dynamic> json) => TrackPoint(
    t: _dblOr(json['t']),
    lat: _dblOr(json['lat']),
    lng: _dblOr(json['lng']),
    d: _dblOr(json['d']),
    ele: _dbl(json['ele']),
    hr: _intOrNull(json['hr']),
  );
}

class WorkoutSplit {
  const WorkoutSplit({
    required this.splitIndex,
    required this.elapsedSeconds,
    this.avgPaceSecPerKm,
    this.avgHeartRate,
    this.elevationGainM,
  });

  final int splitIndex;
  final int elapsedSeconds;
  final double? avgPaceSecPerKm;
  final int? avgHeartRate;
  final double? elevationGainM;

  factory WorkoutSplit.fromJson(Map<String, dynamic> json) => WorkoutSplit(
    splitIndex: _int(json['splitIndex']),
    elapsedSeconds: _int(json['elapsedSeconds']),
    avgPaceSecPerKm: _dbl(json['avgPaceSecPerKm']),
    avgHeartRate: _intOrNull(json['avgHeartRate']),
    elevationGainM: _dbl(json['elevationGainM']),
  );
}

class ZoneSummary {
  const ZoneSummary({
    required this.zoneNumber,
    required this.secondsInZone,
    this.percentOfSession,
  });

  final int zoneNumber;
  final int secondsInZone;
  final double? percentOfSession;

  factory ZoneSummary.fromJson(Map<String, dynamic> json) => ZoneSummary(
    zoneNumber: _int(json['zoneNumber']),
    secondsInZone: _int(json['secondsInZone']),
    percentOfSession: _dbl(json['percentOfSession']),
  );
}

class PersonalRecord {
  const PersonalRecord({
    required this.id,
    required this.metric,
    required this.value,
    required this.unit,
    required this.achievedAt,
    this.distanceM,
    this.previousValue,
  });

  final String id;
  final String metric;
  final double value;
  final String unit;
  final int achievedAt;
  final double? distanceM;
  final double? previousValue;

  /// Improvement over the record it beat, in the record's own unit.
  double? get delta =>
      previousValue == null ? null : (value - previousValue!).abs();

  factory PersonalRecord.fromJson(Map<String, dynamic> json) => PersonalRecord(
    id: json['id'] as String? ?? '',
    metric: json['metric'] as String? ?? '',
    value: _dblOr(json['value']),
    unit: json['unit'] as String? ?? '',
    achievedAt: _int(json['achievedAt']),
    distanceM: _dbl(json['distanceM']),
    previousValue: _dbl(json['previousValue']),
  );
}

class HrZone {
  const HrZone({
    required this.zoneNumber,
    required this.minBpm,
    required this.maxBpm,
  });

  final int zoneNumber;
  final int minBpm;
  final int maxBpm;

  factory HrZone.fromJson(Map<String, dynamic> json) => HrZone(
    zoneNumber: _int(json['zoneNumber']),
    minBpm: _int(json['minBpm']),
    maxBpm: _int(json['maxBpm']),
  );
}

/* -------------------------------------------------------------------- sleep */

class SleepStageSegment {
  const SleepStageSegment({
    required this.stage,
    required this.startedAt,
    required this.endedAt,
  });

  final String stage;
  final int startedAt;
  final int endedAt;

  int get seconds => ((endedAt - startedAt) / 1000).round();

  Map<String, dynamic> toJson() => {
    'stage': stage,
    'startedAt': startedAt,
    'endedAt': endedAt,
  };

  factory SleepStageSegment.fromJson(Map<String, dynamic> json) =>
      SleepStageSegment(
        stage: json['stage'] as String,
        startedAt: _int(json['startedAt']),
        endedAt: _int(json['endedAt']),
      );
}

class SleepAudioEvent {
  const SleepAudioEvent({
    required this.id,
    required this.eventType,
    required this.occurredAt,
    this.durationMs,
    this.peakDb,
    this.audioAssetId,
    this.transcript,
    this.stageAtEvent,
  });

  final int id;
  final String eventType;
  final int occurredAt;
  final int? durationMs;
  final double? peakDb;
  final String? audioAssetId;
  final String? transcript;
  final String? stageAtEvent;

  factory SleepAudioEvent.fromJson(Map<String, dynamic> json) =>
      SleepAudioEvent(
        id: _int(json['id']),
        eventType: json['eventType'] as String,
        occurredAt: _int(json['occurredAt']),
        durationMs: _intOrNull(json['durationMs']),
        peakDb: _dbl(json['peakDb']),
        audioAssetId: json['audioAssetId'] as String?,
        transcript: json['transcript'] as String?,
        stageAtEvent: json['stageAtEvent'] as String?,
      );
}

class SleepSession {
  const SleepSession({
    required this.id,
    required this.source,
    required this.startedAt,
    required this.localDate,
    this.endedAt,
    this.totalSleepSeconds,
    this.awakeSeconds = 0,
    this.lightSeconds = 0,
    this.deepSeconds = 0,
    this.remSeconds = 0,
    this.sleepScore,
    this.sleepEfficiency,
    this.stagesAreEstimated = false,
    this.stages = const [],
    this.events = const [],
  });

  final String id;
  final String source;
  final int startedAt;
  final String localDate;
  final int? endedAt;
  final int? totalSleepSeconds;
  final int awakeSeconds;
  final int lightSeconds;
  final int deepSeconds;
  final int remSeconds;
  final int? sleepScore;
  final double? sleepEfficiency;
  final bool stagesAreEstimated;
  final List<SleepStageSegment> stages;
  final List<SleepAudioEvent> events;

  factory SleepSession.fromJson(Map<String, dynamic> json) => SleepSession(
    id: json['id'] as String,
    source: json['source'] as String? ?? 'phone_mic',
    startedAt: _int(json['startedAt']),
    localDate: json['localDate'] as String? ?? '',
    endedAt: _intOrNull(json['endedAt']),
    totalSleepSeconds: _intOrNull(json['totalSleepSeconds']),
    awakeSeconds: _int(json['awakeSeconds']),
    lightSeconds: _int(json['lightSeconds']),
    deepSeconds: _int(json['deepSeconds']),
    remSeconds: _int(json['remSeconds']),
    sleepScore: _intOrNull(json['sleepScore']),
    sleepEfficiency: _dbl(json['sleepEfficiency']),
    stagesAreEstimated: _bool(json['stagesAreEstimated']),
    stages:
        (json['stages'] as List?)
            ?.whereType<Map>()
            .map((e) => SleepStageSegment.fromJson(e.cast<String, dynamic>()))
            .toList() ??
        const [],
    events:
        (json['events'] as List?)
            ?.whereType<Map>()
            .map((e) => SleepAudioEvent.fromJson(e.cast<String, dynamic>()))
            .toList() ??
        const [],
  );
}

class SleepDebtDay {
  const SleepDebtDay({
    required this.localDate,
    required this.targetSleepSeconds,
    required this.actualSleepSeconds,
    required this.dailyDiffSeconds,
    required this.hasData,
  });

  final String localDate;
  final int targetSleepSeconds;
  final int actualSleepSeconds;
  final int dailyDiffSeconds;
  final bool hasData;

  factory SleepDebtDay.fromJson(Map<String, dynamic> json) => SleepDebtDay(
    localDate: json['localDate'] as String,
    targetSleepSeconds: _int(json['targetSleepSeconds']),
    actualSleepSeconds: _int(json['actualSleepSeconds']),
    dailyDiffSeconds: _int(json['dailyDiffSeconds']),
    hasData: _bool(json['hasData'], true),
  );
}

class SleepDebt {
  const SleepDebt({
    required this.targetSeconds,
    required this.windowDays,
    required this.rollingDebtSeconds,
    required this.daysRecorded,
    required this.byDay,
  });

  final int targetSeconds;
  final int windowDays;
  final int rollingDebtSeconds;
  final int daysRecorded;
  final List<SleepDebtDay> byDay;

  double get debtHours => rollingDebtSeconds / 3600;

  factory SleepDebt.fromJson(Map<String, dynamic> json) => SleepDebt(
    targetSeconds: _int(json['targetSeconds'], 28800),
    windowDays: _int(json['windowDays'], 14),
    rollingDebtSeconds: _int(json['rollingDebtSeconds']),
    daysRecorded: _int(json['daysRecorded']),
    byDay:
        (json['byDay'] as List?)
            ?.whereType<Map>()
            .map((e) => SleepDebtDay.fromJson(e.cast<String, dynamic>()))
            .toList() ??
        const [],
  );
}

/* -------------------------------------------------------------------- coach */

class CoachMessage {
  const CoachMessage({
    required this.role,
    required this.content,
    this.id,
    this.createdAt,
    this.photoAssetId,
    this.actions = const [],
  });

  final int? id;
  final String role;
  final String content;
  final int? createdAt;

  /// Photo attached to a user message (media asset id). The assistant "sees"
  /// it as a text description server-side; here it renders as the image.
  final String? photoAssetId;

  /// Writes the assistant proposed in this reply; each waits for "Xác nhận".
  final List<CoachAction> actions;

  bool get isUser => role == 'user';

  CoachMessage copyWith({List<CoachAction>? actions}) => CoachMessage(
    id: id,
    role: role,
    content: content,
    createdAt: createdAt,
    photoAssetId: photoAssetId,
    actions: actions ?? this.actions,
  );

  factory CoachMessage.fromJson(Map<String, dynamic> json) => CoachMessage(
    id: _intOrNull(json['id']),
    role: json['role'] as String,
    content: json['content'] as String,
    createdAt: _intOrNull(json['createdAt']),
    photoAssetId: json['photoAssetId'] as String?,
    actions: ((json['actions'] as List?) ?? const [])
        .map((a) => CoachAction.fromJson((a as Map).cast<String, dynamic>()))
        .toList(),
  );
}

/// A create/update/delete the assistant proposed. Nothing is written until the
/// user confirms it; [summary] is composed by the server from the validated
/// arguments, never by the model, so it is what will actually happen.
class CoachAction {
  const CoachAction({
    required this.id,
    required this.tool,
    required this.summary,
    required this.status,
    this.details = const [],
    this.error,
    this.linkType,
    this.linkId,
    this.deleted = false,
  });

  final String id;
  final String tool;
  final String summary;

  /// pending | confirmed | cancelled | failed | expired
  final String status;
  final List<String> details;
  final String? error;

  /// What the confirmed write produced, so the card can open it.
  final String? linkType;
  final String? linkId;

  /// The confirmed target (meal/workout/sleep) was deleted afterwards.
  final bool deleted;

  bool get isPending => status == 'pending';

  factory CoachAction.fromJson(Map<String, dynamic> json) {
    final result = (json['result'] as Map?)?.cast<String, dynamic>();
    final link = (result?['link'] as Map?)?.cast<String, dynamic>();
    return CoachAction(
      id: json['id'] as String,
      tool: json['tool'] as String,
      summary: json['summary'] as String,
      status: json['status'] as String,
      details: ((json['details'] as List?) ?? const []).cast<String>(),
      error: json['error'] as String?,
      linkType: link?['type'] as String?,
      linkId: link?['id'] as String?,
      deleted: json['deleted'] as bool? ?? false,
    );
  }
}

class CoachConversation {
  const CoachConversation({
    required this.id,
    this.title,
    this.lastMessageAt,
    this.messageCount = 0,
  });

  final String id;
  final String? title;
  final int? lastMessageAt;
  final int messageCount;

  factory CoachConversation.fromJson(Map<String, dynamic> json) =>
      CoachConversation(
        id: json['id'] as String,
        title: json['title'] as String?,
        lastMessageAt: _intOrNull(json['lastMessageAt']),
        messageCount: _intOrNull(json['messageCount']) ?? 0,
      );
}

class CoachInsight {
  const CoachInsight({
    required this.id,
    required this.domain,
    required this.title,
    required this.body,
    required this.localDate,
    this.severity,
    this.isRead = false,
  });

  final String id;
  final String domain;
  final String title;
  final String body;
  final String localDate;
  final String? severity;
  final bool isRead;

  factory CoachInsight.fromJson(Map<String, dynamic> json) => CoachInsight(
    id: json['id'] as String,
    domain: json['domain'] as String,
    title: json['title'] as String,
    body: json['body'] as String,
    localDate: json['localDate'] as String? ?? '',
    severity: json['severity'] as String?,
    isRead: _bool(json['isRead']),
  );
}

/* ------------------------------------------------------------------ moments */

class Friend {
  const Friend({
    required this.id,
    this.displayName,
    this.email,
    this.avatarUrl,
  });

  final String id;
  final String? displayName;
  final String? email;
  final String? avatarUrl;

  String get label => displayName ?? email ?? id;

  factory Friend.fromJson(Map<String, dynamic> json) => Friend(
    id: json['id'] as String,
    displayName: json['displayName'] as String?,
    email: json['email'] as String?,
    avatarUrl: json['avatarRemoteUrl'] as String?,
  );
}

/// One direct message between two friends. Answering a photo is an ordinary
/// message that pins the moment it answers, and a reaction is a message too, so
/// everything a friend sends lands in the same conversation.
class DirectMessage {
  const DirectMessage({
    required this.id,
    required this.senderId,
    required this.recipientId,
    required this.body,
    required this.createdAt,
    this.kind = 'text',
    this.momentPostId,
    this.readAt,
    this.senderName,
    this.senderAvatarUrl,
    this.photoAssetId,
    this.momentCaption,
  });

  final String id;
  final String senderId;
  final String recipientId;
  final String body;
  final int createdAt;

  /// `text`, or `reaction` when the body is the emoji someone left on a photo.
  final String kind;

  /// The moment being answered, when there is one. Its photo is pinned above
  /// the bubble the way Instagram shows a story reply.
  final String? momentPostId;
  final int? readAt;
  final String? senderName;
  final String? senderAvatarUrl;
  final String? photoAssetId;
  final String? momentCaption;

  bool get unread => readAt == null;
  bool get isReaction => kind == 'reaction';

  factory DirectMessage.fromJson(Map<String, dynamic> json) => DirectMessage(
    id: json['id'] as String,
    senderId: json['senderId'] as String,
    recipientId: json['recipientId'] as String,
    body: json['body'] as String? ?? '',
    createdAt: _int(json['createdAt']),
    kind: json['kind'] as String? ?? 'text',
    momentPostId: json['momentPostId'] as String?,
    readAt: _intOrNull(json['readAt']),
    senderName: json['senderName'] as String?,
    senderAvatarUrl: json['senderAvatarUrl'] as String?,
    photoAssetId: json['photoAssetId'] as String?,
    momentCaption: json['momentCaption'] as String?,
  );

  /// The same message, read. Flipped locally so a badge clears on the tap
  /// rather than on the round trip.
  DirectMessage read(int at) => DirectMessage(
    id: id,
    senderId: senderId,
    recipientId: recipientId,
    body: body,
    createdAt: createdAt,
    kind: kind,
    momentPostId: momentPostId,
    readAt: at,
    senderName: senderName,
    senderAvatarUrl: senderAvatarUrl,
    photoAssetId: photoAssetId,
    momentCaption: momentCaption,
  );
}

/// One row of the messages list: a friend, what they last said, and how much of
/// it is still unread.
class Conversation {
  const Conversation({
    required this.userId,
    required this.lastMessage,
    this.displayName,
    this.avatarUrl,
    this.unread = 0,
  });

  final String userId;
  final DirectMessage lastMessage;
  final String? displayName;
  final String? avatarUrl;
  final int unread;

  String get label => displayName ?? 'Bạn bè';

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
    userId: json['userId'] as String,
    displayName: json['displayName'] as String?,
    avatarUrl: json['avatarRemoteUrl'] as String?,
    unread: _int(json['unread']),
    lastMessage: DirectMessage.fromJson(
      (json['lastMessage'] as Map).cast<String, dynamic>(),
    ),
  );
}

/// One page of the community feed plus where the next one starts./// One page of the community feed plus where the next one starts.
class MomentPage {
  const MomentPage({required this.items, this.nextCursor});

  final List<Moment> items;
  final String? nextCursor;
}

class Moment {
  const Moment({
    required this.id,
    required this.userId,
    required this.photoAssetId,
    required this.createdAt,
    this.caption,
    this.authorName,
    this.authorAvatarUrl,
    this.viewedAt,
    this.visibility = 'friends',
  });

  final String id;
  final String userId;
  final String photoAssetId;
  final int createdAt;
  final String? caption;
  final String? authorName;

  /// The author's profile picture, straight from their identity provider, so
  /// the feed can show who posted without a second request per author.
  final String? authorAvatarUrl;

  /// When the signed-in viewer opened this moment; null while it is still new
  /// to them. A viewer's own posts never carry a view row, so callers that ask
  /// "is this news?" have to exclude their own moments themselves.
  final int? viewedAt;
  final String visibility;

  bool get seen => viewedAt != null;

  /// The same moment, read. Cheaper than refetching the page a moment sits on
  /// just to flip one flag.
  Moment markedViewed(int at) => Moment(
    id: id,
    userId: userId,
    photoAssetId: photoAssetId,
    createdAt: createdAt,
    caption: caption,
    authorName: authorName,
    authorAvatarUrl: authorAvatarUrl,
    viewedAt: at,
    visibility: visibility,
  );

  factory Moment.fromJson(Map<String, dynamic> json) => Moment(
    id: json['id'] as String,
    userId: json['userId'] as String,
    photoAssetId: json['photoAssetId'] as String,
    createdAt: _int(json['createdAt']),
    caption: json['caption'] as String?,
    authorName: json['authorName'] as String?,
    authorAvatarUrl: json['authorAvatarUrl'] as String?,
    viewedAt: _intOrNull(json['viewedAt']),
    visibility: json['visibility'] as String? ?? 'friends',
  );
}
