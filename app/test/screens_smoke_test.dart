import 'package:chiphealth/core/auth/auth_controller.dart';
import 'package:chiphealth/core/format/date_range.dart';
import 'package:chiphealth/core/models/models.dart';
import 'package:chiphealth/core/providers.dart';
import 'package:chiphealth/features/home/home_screen.dart';
import 'package:chiphealth/features/home/water_controller.dart';
import 'package:chiphealth/features/progress/progress_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chiphealth/core/l10n/gen/app_localizations.dart';

/// Renders the two dashboard screens at phone size with canned data. They are
/// dense stacks of rows and charts, so the thing worth guarding is that nothing
/// overflows or throws — a RenderFlex overflow fails the test.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('vi');
  });

  setUp(() {
    // Keyed on today, not on a fixed date: the water card reads the key for the
    // day it is rendering, so a hard-coded one stops matching at midnight and
    // the test starts failing on its own.
    final today = DateRange.iso(DateTime.now());
    SharedPreferences.setMockInitialValues({'water.ml.$today': 750});
  });

  const daily = DailyNutrition(
    date: '2026-09-09',
    consumedKcal: 1420,
    tdeeKcal: 2100,
    balanceKcal: -680,
    proteinG: 88,
    carbsG: 190,
    fatG: 52,
    fiberG: 18,
    sugarG: 44,
    sodiumMg: 2600,
    burnedKcal: 320,
  );

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    List<Override> overrides = const [],
  }) async {
    // Both screens hold their requests until the session is restored, so a
    // signed-in auth state is part of the fixture.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith((ref) => _SignedInAuth(ref)),
          ...overrides,
        ],
        child: MaterialApp(
          locale: const Locale('vi'),
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: child,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('home renders the day without overflowing', (tester) async {
    await pump(
      tester,
      const HomeScreen(),
      overrides: [
        dailyNutritionProvider.overrideWith((ref, arg) async => daily),
      ],
    );

    expect(find.text('Chiphealth'), findsOneWidget);
    expect(find.textContaining('Mục tiêu:'), findsWidgets);
    // Carbs eaten against the 50%-of-2100 kcal target.
    expect(find.text('190/263 g'), findsOneWidget);
  });

  testWidgets('the water "+" asks for millilitres and logs them', (
    tester,
  ) async {
    await pump(
      tester,
      const HomeScreen(),
      overrides: [
        dailyNutritionProvider.overrideWith((ref, arg) async => daily),
      ],
    );

    // The blue "+" on the water card, not the green ones on meals/activity.
    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pumpAndSettle();
    expect(find.text('Thêm nước'), findsOneWidget);

    await tester.tap(find.text('330 ml'));
    await tester.pumpAndSettle();
    // 750 ml was already stored for the day by setUp.
    expect(find.text('1,080 ml'), findsOneWidget);
  });

  testWidgets('progress renders every card without overflowing', (
    tester,
  ) async {
    final metrics = [
      const BodyMetric(
        recordedAt: 1,
        localDate: '2026-09-07',
        weightKg: 68,
        heightCm: 172,
      ),
      const BodyMetric(recordedAt: 2, localDate: '2026-09-09', weightKg: 66.8),
    ];

    await pump(
      tester,
      const ProgressScreen(),
      overrides: [
        nutritionRangeProvider.overrideWith((ref, arg) async => [daily]),
        bodyMetricsRangeProvider.overrideWith((ref, arg) async => metrics),
        allBodyMetricsProvider.overrideWith((ref) async => metrics),
        goalsProvider.overrideWith(
          (ref) async => [
            const Goal(
              id: 'g1',
              goalType: 'lose_weight',
              startValue: 68,
              status: 'active',
              targetValue: 62,
              targetUnit: 'kg',
            ),
          ],
        ),
        waterRangeProvider.overrideWith(
          (ref, DateRange arg) async => {'2026-09-09': 750},
        ),
      ],
    );

    expect(find.text('Tiến trình'), findsOneWidget);
    expect(find.text('Tuần này'), findsOneWidget);
    expect(find.text('Theo dõi calo'), findsOneWidget);
    // 68 → 66.8 of a 68 → 62 goal is a fifth of the way.
    expect(find.text('ĐÃ ĐẠT ĐƯỢC 20% MỤC TIÊU'), findsOneWidget);

    // The BMI card is below the fold; scrolling to it also exercises every
    // chart in between.
    await tester.dragUntilVisible(
      find.text('Chỉ số BMI của bạn'),
      find.byType(ListView),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    expect(find.text('Chỉ số BMI của bạn'), findsOneWidget);
    // 66.8 kg at 1.72 m.
    expect(find.text('22.6'), findsOneWidget);
    expect(find.text('Khỏe mạnh'), findsOneWidget);
  });
}

/// Auth that is already restored, so the screens fetch instead of waiting.
class _SignedInAuth extends AuthController {
  _SignedInAuth(super.ref) {
    state = const AuthState(
      user: AppUser(id: 'u1', email: 'test@example.com', displayName: 'Chi'),
      booted: true,
    );
  }
}
