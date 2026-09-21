import 'dart:typed_data';

import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../models/models.dart';
import '../storage/uuid.dart';

List<Map<String, dynamic>> _items(dynamic data) =>
    ((data as Map?)?['items'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();

/* ------------------------------------------------------------------ profile */

class ProfileRepository {
  ProfileRepository(this._api);
  final ApiClient _api;

  Future<Map<String, dynamic>> me() async =>
      (await _api.get<dynamic>('/v1/me') as Map).cast<String, dynamic>();

  Future<void> updateProfile(UserProfile profile) =>
      _api.put<dynamic>('/v1/me/profile', body: profile.toJson());

  /// The account's language. One value drives three things: the app's own
  /// strings, what the speech recogniser listens for, and the language the
  /// assistant answers in — so it is stored on the account, not on the device.
  Future<void> setLocale(String locale) =>
      _api.patch<dynamic>('/v1/me', body: {'locale': locale});

  /// Writes only the given fields; the server leaves every other one alone.
  Future<void> patchProfile(Map<String, dynamic> fields) =>
      _api.put<dynamic>('/v1/me/profile', body: fields);

  /// Today's BMR/TDEE together with every input behind them.
  Future<Map<String, dynamic>> tdee() async =>
      (await _api.get<dynamic>('/v1/me/tdee') as Map).cast<String, dynamic>();

  /// `limit` maxes out at 200 server-side; the default page of 50 is too short
  /// for a year of weigh-ins on the progress screen.
  Future<List<BodyMetric>> bodyMetrics({
    String? from,
    String? to,
    int? limit,
  }) async {
    final data = await _api.get<dynamic>(
      '/v1/me/body-metrics',
      query: {'from': from, 'to': to, 'limit': limit?.toString()},
    );
    return _items(data).map(BodyMetric.fromJson).toList();
  }

  Future<void> addBodyMetric({
    double? weightKg,
    double? heightCm,
    double? bodyFatPercent,
  }) => _api.post<dynamic>(
    '/v1/me/body-metrics',
    body: {
      'recordedAt': DateTime.now().millisecondsSinceEpoch,
      'weightKg': weightKg,
      'heightCm': heightCm,
      'bodyFatPercent': bodyFatPercent,
    },
  );

  Future<List<Goal>> goals() async => _items(
    await _api.get<dynamic>('/v1/me/goals'),
  ).map(Goal.fromJson).toList();

  Future<Goal> addGoal({
    required String goalType,
    double? targetValue,
    String? targetUnit,
    String? deadline,
    // Only used when the server has no baseline of its own for the type.
    double? startValue,
  }) async {
    final data = await _api.post<dynamic>(
      '/v1/me/goals',
      body: {
        'goalType': goalType,
        'targetValue': targetValue,
        'targetUnit': targetUnit,
        'deadline': deadline,
        'startValue': ?startValue,
      },
    );
    return Goal.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<void> deleteGoal(String id) =>
      _api.delete<dynamic>('/v1/me/goals/$id');

  Future<List<ChronicCondition>> conditions() async => _items(
    await _api.get<dynamic>('/v1/me/conditions'),
  ).map(ChronicCondition.fromJson).toList();

  Future<void> addCondition(String description) => _api.post<dynamic>(
    '/v1/me/conditions',
    body: {'description': description},
  );

  Future<void> deleteCondition(String id) =>
      _api.delete<dynamic>('/v1/me/conditions/$id');

  Future<List<ActivityType>> activityTypes(String locale) async => _items(
    await _api.get<dynamic>(
      '/v1/catalog/activity-types',
      query: {'locale': locale},
    ),
  ).map(ActivityType.fromJson).toList();
}

/* ---------------------------------------------------------------- media/R2 */

class MediaRepository {
  MediaRepository(this._api);
  final ApiClient _api;

  /// Two steps by design: reserve the asset row, PUT the bytes, then confirm.
  /// The server only marks the asset as used once the object is really in R2.
  ///
  /// Takes bytes rather than a File so the same code path works on web, where
  /// `dart:io` does not exist and `XFile` only offers `readAsBytes()`.
  Future<String> upload(
    Uint8List bytes, {
    required String kind,
    required String mimeType,
  }) async {
    final reservation =
        (await _api.post<dynamic>(
                  '/v1/media/upload-url',
                  body: {
                    'kind': kind,
                    'mimeType': mimeType,
                    'byteSize': bytes.length,
                  },
                )
                as Map)
            .cast<String, dynamic>();

    final assetId = reservation['assetId'] as String;

    // The reservation has already written a row; from here on a failure would
    // leave it pointing at an object that never arrived. Drop it so a retry
    // starts clean instead of adding one more orphan for the sweeper.
    try {
      await _api.putBytes<dynamic>(
        '/v1/media/$assetId/content',
        bytes,
        contentType: mimeType,
      );
      await _api.post<dynamic>('/v1/media/$assetId/complete');
    } catch (_) {
      try {
        await _api.delete<dynamic>('/v1/media/$assetId');
      } catch (_) {
        // Best effort — the orphan sweeper collects it either way.
      }
      rethrow;
    }
    return assetId;
  }

  /// The object itself. Meal photos are private, so they come through the API
  /// with the bearer token rather than from a public R2 URL.
  Future<Uint8List> bytes(String assetId) async {
    final data = Uint8List.fromList(await _api.getBytes('/v1/media/$assetId'));

    // Anything that is neither an image nor an audio clip here is an error page
    // that answered 200 — a redirect to a bucket that does not hold the object,
    // say. Failing now keeps it inside the future, where the tile can offer a
    // retry; handing it to Image.memory throws during painting instead. Audio
    // matters as much as photos: snore / sleep-talk clips are WAV assets fetched
    // by the same provider the play button reads.
    if (!_isMedia(data)) {
      throw ApiException(
        statusCode: 200,
        code: 'BAD_MEDIA',
        message: 'Tệp media không đọc được.',
      );
    }
    return data;
  }

  static bool _isMedia(Uint8List b) => _isImage(b) || _isAudio(b);

  static bool _isImage(Uint8List b) {
    bool at(int start, List<int> signature) {
      if (b.length < start + signature.length) return false;
      for (var i = 0; i < signature.length; i++) {
        if (b[start + i] != signature[i]) return false;
      }
      return true;
    }

    const jpeg = [0xFF, 0xD8, 0xFF];
    const png = [0x89, 0x50, 0x4E, 0x47];
    const gif = [0x47, 0x49, 0x46];
    const riff = [0x52, 0x49, 0x46, 0x46]; // 'RIFF'
    const webp = [0x57, 0x45, 0x42, 0x50]; // 'WEBP', 8 bytes in
    const ftyp = [0x66, 0x74, 0x79, 0x70]; // 'ftyp', heic/heif box

    return at(0, jpeg) ||
        at(0, png) ||
        at(0, gif) ||
        (at(0, riff) && at(8, webp)) ||
        at(4, ftyp);
  }

  /// WAV only: it is the one audio format the app itself uploads
  /// (night-analyzer clips, `audio/wav`). The server's audio whitelist is
  /// wider, but nothing in this client produces those formats, and a loose
  /// check here would wave through JSON/HTML error bodies as "audio".
  static bool _isAudio(Uint8List b) {
    if (b.length < 12) return false;
    const riff = [0x52, 0x49, 0x46, 0x46]; // 'RIFF'
    const wave = [0x57, 0x41, 0x56, 0x45]; // 'WAVE', 8 bytes in
    bool at(int start, List<int> signature) {
      for (var i = 0; i < signature.length; i++) {
        if (b[start + i] != signature[i]) return false;
      }
      return true;
    }

    return at(0, riff) && at(8, wave);
  }
}

/* ---------------------------------------------------------------- nutrition */

class NutritionRepository {
  NutritionRepository(this._api);
  final ApiClient _api;

  /// [loggedAt] is when the meal was *eaten*, which is not always when it is
  /// typed up — a breakfast entered at noon still belongs to breakfast time.
  /// Defaults to now, which is what every caller that does not ask means.
  Future<MealLog> createMeal({
    required String mealType,
    String? photoAssetId,
    String? note,
    String? id,
    int? loggedAt,
  }) async {
    final data = await _api.post<dynamic>(
      '/v1/meals',
      body: {
        // Client-minted so the meal survives being logged with no connection.
        'id': id ?? uuidV7(),
        'mealType': mealType,
        'photoAssetId': photoAssetId,
        'loggedAt': loggedAt ?? DateTime.now().millisecondsSinceEpoch,
        'note': note,
      },
    );
    return MealLog.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<void> analyze(String mealId) =>
      _api.post<dynamic>('/v1/meals/$mealId/analyze');

  /// Spoken or typed meal. The clip is not stored anywhere: the server
  /// transcribes it, extracts the components and throws the audio away.
  Future<void> logSpoken(
    String mealId, {
    Uint8List? audio,
    String? mimeType,
    String? transcript,
  }) => audio != null
      ? _api.postBytes<dynamic>(
          '/v1/meals/$mealId/voice',
          audio,
          contentType: mimeType ?? 'audio/mp4',
        )
      : _api.post<dynamic>(
          '/v1/meals/$mealId/voice',
          body: {'transcript': transcript},
        );

  /// Dictation for the typed box: the clip comes back as text, no meal made.
  Future<String> transcribeClip(Uint8List audio, {String? mimeType}) async {
    final data =
        (await _api.postBytes<dynamic>(
                  '/v1/meals/transcribe',
                  audio,
                  contentType: mimeType ?? 'audio/mp4',
                )
                as Map)
            .cast<String, dynamic>();
    return data['transcript'] as String? ?? '';
  }

  /// A meal the user threw away, or one whose analysis failed and was discarded.
  Future<void> deleteMeal(String mealId) =>
      _api.delete<dynamic>('/v1/meals/$mealId');

  Future<MealLog> meal(String id) async => MealLog.fromJson(
    (await _api.get<dynamic>('/v1/meals/$id') as Map).cast<String, dynamic>(),
  );

  /// Correcting an item keeps the original AI values server-side; `learn` also
  /// teaches the caller's personal food base so the same dish matches next time.
  Future<void> correctItem(
    String mealId,
    int itemId,
    MealItem item, {
    bool learn = true,
  }) => _api.patch<dynamic>(
    '/v1/meals/$mealId/items/$itemId?learn=$learn',
    body: item.toJson(),
  );

  Future<void> addItem(String mealId, MealItem item) =>
      _api.post<dynamic>('/v1/meals/$mealId/items', body: item.toJson());

  Future<void> deleteItem(String mealId, int itemId) =>
      _api.delete<dynamic>('/v1/meals/$mealId/items/$itemId');

  /// The meal itself rather than its components: the dish name the model
  /// guessed, which meal it counts as, when it was eaten. Only the fields
  /// passed are touched.
  Future<MealLog> updateMeal(
    String mealId, {
    String? mealType,
    String? dishName,
    String? note,
    int? loggedAt,
  }) async {
    final data = await _api.patch<dynamic>(
      '/v1/meals/$mealId',
      body: {
        if (mealType != null) 'mealType': mealType,
        if (dishName != null) 'dishName': dishName,
        if (note != null) 'note': note,
        if (loggedAt != null) 'loggedAt': loggedAt,
      },
    );
    return MealLog.fromJson((data as Map).cast<String, dynamic>());
  }

  /// The thumb under the analysis. `vote` is 'up', 'down', or null to clear it,
  /// which is what tapping the lit thumb again means.
  Future<void> voteAnalysis(String mealId, String? vote) =>
      _api.post<dynamic>('/v1/meals/$mealId/feedback', body: {'vote': vote});

  /// One page of the meal diary, newest first. `from` bounds the first page to
  /// a date window (the screen opens on the last week); every page after it is
  /// pure cursor paging, so scrolling back never refetches what is on screen.
  Future<MealPage> meals({String? from, String? cursor, int limit = 30}) async {
    final data = await _api.get<dynamic>(
      '/v1/meals',
      query: {'from': from, 'cursor': cursor, 'limit': '$limit'},
    );
    return MealPage(
      items: _items(data).map(MealLog.fromJson).toList(),
      nextCursor: (data as Map)['nextCursor'] as String?,
    );
  }

  Future<DailyNutrition> daily([String? date]) async {
    final data = await _api.get<dynamic>(
      '/v1/nutrition/daily',
      query: {'date': date},
    );
    return DailyNutrition.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<List<DailyNutrition>> range(String from, String to) async {
    final data = await _api.get<dynamic>(
      '/v1/nutrition/range',
      query: {'from': from, 'to': to},
    );
    return _items(data)
        .map(
          (e) =>
              DailyNutrition.fromJson({'summary': e, 'date': e['localDate']}),
        )
        .toList();
  }

  /// Barcodes are admin-entered only: a miss is not an error, it is a "chưa có
  /// dữ liệu" state, and the scan is recorded so an admin can add the product.
  Future<FoodHit?> barcode(String code) async {
    try {
      final data = await _api.get<dynamic>('/v1/foods/barcode/$code');
      return FoodHit.fromJson((data as Map).cast<String, dynamic>());
    } on Object catch (err) {
      if (err.toString().contains('BARCODE_NOT_FOUND')) return null;
      rethrow;
    }
  }

  /// Attaches what the user knows about an unknown barcode. This is what turns
  /// the admin queue from bare numbers into something enterable without owning
  /// the product.
  Future<void> reportBarcode(
    String code, {
    String? productNameHint,
    String? photoAssetId,
  }) => _api.post<dynamic>(
    '/v1/foods/barcode/$code/report',
    body: {'productNameHint': productNameHint, 'photoAssetId': photoAssetId},
  );

  Future<List<FoodHit>> search(String query) async {
    final data =
        (await _api.get<dynamic>('/v1/foods/search', query: {'q': query})
                as Map)
            .cast<String, dynamic>();
    final personal = (data['personal'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (e) => FoodHit.fromJson(e.cast<String, dynamic>(), personal: true),
        );
    final global = (data['global'] as List? ?? const []).whereType<Map>().map(
      (e) => FoodHit.fromJson(e.cast<String, dynamic>()),
    );
    // Personal rows first: the same dish differs between households.
    return [...personal, ...global];
  }

  Future<List<MealPlan>> plans([String? date]) async => _items(
    await _api.get<dynamic>('/v1/meal-plans', query: {'date': date}),
  ).map(MealPlan.fromJson).toList();

  Future<List<MealPlan>> generatePlan(String date) async {
    final data = await _api.post<dynamic>(
      '/v1/meal-plans/generate',
      body: {'date': date},
    );
    return _items(data).map(MealPlan.fromJson).toList();
  }

  Future<void> setPlanStatus(String id, String status) =>
      _api.patch<dynamic>('/v1/meal-plans/$id', body: {'status': status});
}

/* ----------------------------------------------------------------- training */

class TrainingRepository {
  TrainingRepository(this._api);
  final ApiClient _api;

  Future<WorkoutSession> saveSession({
    required String id,
    required int activityTypeId,
    required int startedAt,
    int? endedAt,
    int? durationSeconds,
    int? movingSeconds,
    double? distanceM,
    double? elevationGainM,
    int? avgHeartRate,
    int? maxHeartRate,
    String? title,
    String? notes,
    int? perceivedExertion,
    double? caloriesBurnedKcal,
    String source = 'in_app',
    List<String>? photoAssetIds,
  }) async {
    final data = await _api.post<dynamic>(
      '/v1/workouts',
      body: {
        'id': id,
        'activityTypeId': activityTypeId,
        'source': source,
        if (caloriesBurnedKcal != null) ...{
          'caloriesBurnedKcal': caloriesBurnedKcal,
          'caloriesAreEstimated': false,
        },
        'startedAt': startedAt,
        'endedAt': endedAt,
        'durationSeconds': durationSeconds,
        'movingSeconds': movingSeconds,
        'distanceM': distanceM,
        'elevationGainM': elevationGainM,
        'avgHeartRate': avgHeartRate,
        'maxHeartRate': maxHeartRate,
        'title': title,
        'notes': notes,
        'perceivedExertion': perceivedExertion,
        if (photoAssetIds != null) 'photoAssetIds': photoAssetIds,
      },
    );
    return WorkoutSession.fromJson((data as Map).cast<String, dynamic>());
  }

  /// Server-side kcal preview: the sport's MET from the catalogue times the
  /// latest logged weight; a distance alone is turned into time first.
  Future<Map<String, dynamic>> estimate({
    required int activityTypeId,
    int? durationSeconds,
    double? distanceM,
  }) async =>
      (await _api.get<dynamic>(
                '/v1/workouts/estimate',
                query: {
                  'activityTypeId': '$activityTypeId',
                  if (durationSeconds != null)
                    'durationSeconds': '$durationSeconds',
                  if (distanceM != null) 'distanceM': '$distanceM',
                },
              )
              as Map)
          .cast<String, dynamic>();

  /// Edit what the athlete typed; the numbers come from the stream. Photos are
  /// full-replace server-side, so this always sends the complete ordered list.
  Future<WorkoutSession> update(
    String id, {
    required int activityTypeId,
    String? title,
    String? notes,
    int? perceivedExertion,
    List<String>? photoAssetIds,
  }) async {
    final data = await _api.patch<dynamic>(
      '/v1/workouts/$id',
      body: {
        'activityTypeId': activityTypeId,
        'title': title,
        'notes': notes,
        'perceivedExertion': perceivedExertion,
        if (photoAssetIds != null) 'photoAssetIds': photoAssetIds,
      },
    );
    return WorkoutSession.fromJson((data as Map).cast<String, dynamic>());
  }

  /// Gone for good, like deleting a meal: the session, its stream and splits,
  /// and any personal record it set.
  Future<void> delete(String id) => _api.delete<dynamic>('/v1/workouts/$id');

  /// Timed GPS points for replay and crop.
  Future<List<TrackPoint>> track(String id) async => _items(
    await _api.get<dynamic>('/v1/workouts/$id/track'),
  ).map(TrackPoint.fromJson).toList();

  /// Keeps [fromS]..[toS] seconds of the recording and re-derives the rest.
  Future<void> crop(String id, double fromS, double toS) => _api.post<dynamic>(
    '/v1/workouts/$id/crop',
    body: {'fromS': fromS, 'toS': toS},
  );

  /// Uploads the raw sample stream; the server derives polyline, splits,
  /// time-in-zone and PRs from it, so no per-point rows are ever sent.
  Future<List<PersonalRecord>> uploadStream(
    String sessionId,
    String assetId,
  ) async {
    final data =
        (await _api.put<dynamic>(
                  '/v1/workouts/$sessionId/stream',
                  body: {'assetId': assetId},
                )
                as Map)
            .cast<String, dynamic>();
    return (data['newRecords'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => PersonalRecord.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  Future<List<WorkoutSession>> feed({String? from, String? to}) async => _items(
    await _api.get<dynamic>('/v1/workouts', query: {'from': from, 'to': to}),
  ).map(WorkoutSession.fromJson).toList();

  Future<Map<String, dynamic>> detail(String id) async =>
      (await _api.get<dynamic>('/v1/workouts/$id') as Map)
          .cast<String, dynamic>();

  Future<void> saveSets(String sessionId, List<Map<String, dynamic>> sets) =>
      _api.put<dynamic>('/v1/workouts/$sessionId/sets', body: {'sets': sets});

  Future<List<PersonalRecord>> records() async => _items(
    await _api.get<dynamic>('/v1/training/records'),
  ).map(PersonalRecord.fromJson).toList();

  Future<List<HrZone>> zones() async {
    final data = (await _api.get<dynamic>('/v1/training/zones') as Map)
        .cast<String, dynamic>();
    return (data['zones'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => HrZone.fromJson(e.cast<String, dynamic>()))
        .toList();
  }
}

/* -------------------------------------------------------------------- sleep */

class SleepRepository {
  SleepRepository(this._api);
  final ApiClient _api;

  Future<SleepSession> upload({
    required String source,
    required int startedAt,
    required int endedAt,
    required List<SleepStageSegment> stages,
    List<Map<String, dynamic>> events = const [],
    bool audioRecordingEnabled = false,
    int? sleepLatencySeconds,
  }) async {
    final data = await _api.post<dynamic>(
      '/v1/sleep/sessions',
      body: {
        'id': uuidV7(),
        'source': source,
        'startedAt': startedAt,
        'endedAt': endedAt,
        'stages': stages.map((s) => s.toJson()).toList(),
        'events': events,
        'audioRecordingEnabled': audioRecordingEnabled,
        if (sleepLatencySeconds != null)
          'sleepLatencySeconds': sleepLatencySeconds,
      },
    );
    return SleepSession.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<List<SleepSession>> sessions({String? from, String? to}) async =>
      _items(
        await _api.get<dynamic>(
          '/v1/sleep/sessions',
          query: {'from': from, 'to': to},
        ),
      ).map(SleepSession.fromJson).toList();

  Future<SleepSession> session(String id) async => SleepSession.fromJson(
    (await _api.get<dynamic>('/v1/sleep/sessions/$id') as Map)
        .cast<String, dynamic>(),
  );

  /// Moves bedtime / wake-up; whatever falls outside is cut from the night.
  /// Also carries what the morning review collected — the name, the note and
  /// the photos — since all of it lands on the same row.
  Future<void> updateSession(
    String id, {
    required int startedAt,
    required int endedAt,
    String? title,
    String? notes,
    List<String>? photoAssetIds,
  }) => _api.patch<dynamic>(
    '/v1/sleep/sessions/$id',
    body: {
      'startedAt': startedAt,
      'endedAt': endedAt,
      if (title != null) 'title': title,
      if (notes != null) 'notes': notes,
      if (photoAssetIds != null) 'photoAssetIds': photoAssetIds,
    },
  );

  Future<void> deleteSession(String id) =>
      _api.delete<dynamic>('/v1/sleep/sessions/$id');

  /// Hides one snore / sleep-talk event. Soft on the server: the row and its
  /// clip stay, they just stop being listed.
  Future<void> hideAudioEvent(int eventId) =>
      _api.delete<dynamic>('/v1/sleep/events/$eventId');

  Future<SleepDebt> debt([String? date]) async {
    final data = await _api.get<dynamic>(
      '/v1/sleep/debt',
      query: {'date': date},
    );
    return SleepDebt.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<String> transcribe(int eventId) async {
    final data =
        (await _api.post<dynamic>('/v1/sleep/events/$eventId/transcribe')
                as Map)
            .cast<String, dynamic>();
    return data['transcript'] as String? ?? '';
  }

  Future<List<Map<String, dynamic>>> reminders() async =>
      _items(await _api.get<dynamic>('/v1/sleep/reminders'));

  Future<void> addReminder({
    required String type,
    required String remindAtLocal,
    required String daysOfWeek,
  }) => _api.post<dynamic>(
    '/v1/sleep/reminders',
    body: {
      'reminderType': type,
      'remindAtLocal': remindAtLocal,
      'daysOfWeek': daysOfWeek,
    },
  );
}

/* -------------------------------------------------------------------- coach */

class CoachRepository {
  CoachRepository(this._api);
  final ApiClient _api;

  Future<String> startConversation() async {
    final data =
        (await _api.post<dynamic>(
                  '/v1/coach/conversations',
                  // Every field is optional server-side, but the body itself must be
                  // JSON: an empty POST would be rejected with "Body must be valid JSON".
                  body: <String, dynamic>{},
                )
                as Map)
            .cast<String, dynamic>();
    return data['id'] as String;
  }

  Future<List<CoachConversation>> conversations() async => _items(
    await _api.get<dynamic>('/v1/coach/conversations'),
  ).map(CoachConversation.fromJson).toList();

  Future<void> deleteConversation(String id) =>
      _api.delete<dynamic>('/v1/coach/conversations/$id');

  Future<List<CoachMessage>> messages(String conversationId) async => _items(
    await _api.get<dynamic>('/v1/coach/conversations/$conversationId/messages'),
  ).map(CoachMessage.fromJson).toList();

  /// One assistant turn. The agent may look things up several times before it
  /// answers, so this waits far longer than an ordinary request. [photoAssetId]
  /// is a media asset the user attached; the server describes it with the
  /// vision model before the agent runs.
  Future<CoachMessage> send(
    String conversationId,
    String content, {
    String? photoAssetId,
    int? waterMlToday,
    int? waterTargetMl,
  }) async {
    final data =
        (await _api.post<dynamic>(
                  '/v1/coach/conversations/$conversationId/messages',
                  body: {
                    'content': content,
                    if (photoAssetId != null) 'photo_asset_id': photoAssetId,
                    'device': {
                      if (waterMlToday != null) 'waterMlToday': waterMlToday,
                      if (waterTargetMl != null) 'waterTargetMl': waterTargetMl,
                    },
                  },
                  receiveTimeout: const Duration(seconds: 120),
                )
                as Map)
            .cast<String, dynamic>();
    return CoachMessage.fromJson(data);
  }

  /// Runs a proposed write. [CoachActionOutcome.waterMl] is set when the write
  /// is one the app applies itself (water lives on the device).
  Future<CoachActionOutcome> confirmAction(String actionId) async =>
      CoachActionOutcome.fromJson(
        (await _api.post<dynamic>(
                  '/v1/coach/actions/$actionId/confirm',
                  receiveTimeout: const Duration(seconds: 60),
                )
                as Map)
            .cast<String, dynamic>(),
      );

  Future<CoachActionOutcome> cancelAction(String actionId) async =>
      CoachActionOutcome.fromJson(
        (await _api.post<dynamic>('/v1/coach/actions/$actionId/cancel') as Map)
            .cast<String, dynamic>(),
      );

  Future<List<CoachInsight>> insights({String? from, String? to}) async =>
      _items(
        await _api.get<dynamic>(
          '/v1/coach/insights',
          query: {'from': from, 'to': to},
        ),
      ).map(CoachInsight.fromJson).toList();

  Future<void> markRead(String id) =>
      _api.post<dynamic>('/v1/coach/insights/$id/read');
}

class CoachActionOutcome {
  const CoachActionOutcome({
    required this.action,
    required this.message,
    this.waterDate,
    this.waterMl,
  });

  final CoachAction action;

  /// The "Đã thực hiện: …" line the server appended to the thread.
  final CoachMessage message;
  final String? waterDate;
  final int? waterMl;

  factory CoachActionOutcome.fromJson(Map<String, dynamic> json) {
    final effect = (json['clientEffect'] as Map?)?.cast<String, dynamic>();
    final isWater = effect?['type'] == 'water_add';
    return CoachActionOutcome(
      action: CoachAction.fromJson(
        (json['action'] as Map).cast<String, dynamic>(),
      ),
      message: CoachMessage.fromJson(
        (json['message'] as Map).cast<String, dynamic>(),
      ),
      waterDate: isWater ? effect!['date'] as String : null,
      waterMl: isWater ? (effect!['ml'] as num).toInt() : null,
    );
  }
}

/* ------------------------------------------------------------------ moments */

class MomentsRepository {
  MomentsRepository(this._api);
  final ApiClient _api;

  Future<List<Friend>> friends() async => _items(
    await _api.get<dynamic>('/v1/friends'),
  ).map(Friend.fromJson).toList();

  Future<void> requestFriend(String email) =>
      _api.post<dynamic>('/v1/friends/requests', body: {'email': email});

  Future<Map<String, dynamic>> pendingRequests() async =>
      (await _api.get<dynamic>('/v1/friends/requests') as Map)
          .cast<String, dynamic>();

  Future<void> acceptRequest(String id) =>
      _api.post<dynamic>('/v1/friends/requests/$id/accept');

  Future<Moment> post({
    required String photoAssetId,
    String? caption,
    String visibility = 'friends',
    String? linkedMealLogId,
  }) async {
    final data = await _api.post<dynamic>(
      '/v1/moments',
      body: {
        'photoAssetId': photoAssetId,
        'caption': caption,
        'visibility': visibility,
        'linkedMealLogId': linkedMealLogId,
      },
    );
    return Moment.fromJson((data as Map).cast<String, dynamic>());
  }

  Future<MomentPage> feed({String? cursor, int limit = 30}) async {
    final data = await _api.get<dynamic>(
      '/v1/moments/feed',
      query: {'cursor': cursor, 'limit': '$limit'},
    );
    return MomentPage(
      items: _items(data).map(Moment.fromJson).toList(),
      nextCursor: (data as Map)['nextCursor'] as String?,
    );
  }

  /// Payload for the home-screen widget: newest unseen moment per friend.
  Future<List<Moment>> widget() async => _items(
    await _api.get<dynamic>('/v1/moments/widget'),
  ).map(Moment.fromJson).toList();

  Future<void> markViewed(String id) =>
      _api.post<dynamic>('/v1/moments/$id/view');

  Future<void> react(String id, String emoji) =>
      _api.post<dynamic>('/v1/moments/$id/react', body: {'emoji': emoji});

  /// Answering a photo: a direct message that pins the moment it answers.
  Future<DirectMessage> replyToMoment(String momentId, String body) async =>
      DirectMessage.fromJson(
        (await _api.post<dynamic>(
                  '/v1/moments/$momentId/messages',
                  body: {'body': body},
                )
                as Map)
            .cast<String, dynamic>(),
      );

  /// The messages list: one row per friend, newest activity first.
  Future<List<Conversation>> conversations() async => _items(
    await _api.get<dynamic>('/v1/messages'),
  ).map(Conversation.fromJson).toList();

  /// One conversation, oldest first.
  Future<List<DirectMessage>> messages(
    String userId, {
    int limit = 100,
  }) async => _items(
    await _api.get<dynamic>('/v1/messages/$userId', query: {'limit': '$limit'}),
  ).map(DirectMessage.fromJson).toList();

  Future<DirectMessage> sendMessage(
    String userId,
    String body, {
    String? momentPostId,
  }) async => DirectMessage.fromJson(
    (await _api.post<dynamic>(
              '/v1/messages/$userId',
              body: {'body': body, 'momentPostId': momentPostId},
            )
            as Map)
        .cast<String, dynamic>(),
  );

  Future<void> deleteMoment(String id) =>
      _api.delete<dynamic>('/v1/moments/$id');

  Future<void> markConversationRead(String userId) =>
      _api.post<dynamic>('/v1/messages/$userId/read');
}
