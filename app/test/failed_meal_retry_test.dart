import 'dart:convert';
import 'dart:typed_data';

import 'package:chiphealth/core/models/models.dart';
import 'package:chiphealth/core/providers.dart';
import 'package:chiphealth/core/repositories/repositories.dart';
import 'package:chiphealth/features/nutrition/meal_photo.dart';
import 'package:chiphealth/features/nutrition/meal_timeline.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chiphealth/core/l10n/gen/app_localizations.dart';

class _FakeNutrition implements NutritionRepository {
  _FakeNutrition(this.page);
  final List<MealLog> page;

  @override
  Future<MealPage> meals({
    String? from,
    String? cursor,
    int limit = 30,
  }) async => MealPage(items: page);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CountingMedia implements MediaRepository {
  int fetches = 0;

  // 1x1 transparent PNG, so Image.memory has something real to decode.
  static final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  );

  @override
  Future<Uint8List> bytes(String assetId) async {
    fetches++;
    return Uint8List.fromList(_png); // a fresh buffer per call, like the API
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MealLog _failed(String id, {String? photo}) => MealLog(
  id: id,
  mealType: 'lunch',
  loggedAt: DateTime.now().millisecondsSinceEpoch,
  localDate: '2026-09-18',
  totalCaloriesKcal: 0,
  photoAssetId: photo,
  analysisStatus: 'failed',
  itemCount: 0,
);

void main() {
  test(
    'a failed photo meal stays in the diary; a failed spoken one does not',
    () async {
      final timeline = MealTimeline(
        _FakeNutrition([_failed('photo', photo: 'asset-1'), _failed('spoken')]),
      );
      await Future<void>.delayed(Duration.zero);

      expect(timeline.state.meals.map((m) => m.id), ['photo']);
      expect(timeline.state.meals.single.isFailedDraft, true);
      timeline.dispose();
    },
  );

  testWidgets('the meal photo is fetched once, not on every poll rebuild', (
    tester,
  ) async {
    final media = _CountingMedia();
    late StateSetter rebuild;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [mediaRepositoryProvider.overrideWithValue(media)],
        child: MaterialApp(
          locale: const Locale('vi'),
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              // Not const: a const widget would never actually rebuild.
              // ignore: prefer_const_constructors
              return MealPhotoThumb(assetId: 'asset-1', size: 240);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    final first = tester.widget<Image>(find.byType(Image)).image;

    // The detail screen's 2 s poll: the photo must stay, not blink back to the
    // placeholder while a second fetch runs.
    for (var i = 0; i < 5; i++) {
      rebuild(() {});
      await tester.pump();
      // A new bytes buffer means a new MemoryImage, which decodes from
      // scratch and paints nothing meanwhile — that was the blink.
      expect(tester.widget<Image>(find.byType(Image)).image, first);
    }
    expect(media.fetches, 1);
  });
}
