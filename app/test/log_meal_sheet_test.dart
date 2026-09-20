import 'package:chiphealth/features/nutrition/log_meal_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The "+" on the nutrition screen is the only way in for every kind of entry,
/// water included, so what the sheet hands back is worth pinning down.
void main() {
  Future<LogMealMethod?> open(WidgetTester tester, String tap) async {
    LogMealMethod? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async => picked = await showLogMealSheet(context),
                child: const Text('+'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('+'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(tap));
    await tester.pumpAndSettle();
    return picked;
  }

  testWidgets('the sheet offers water alongside the meal entry points', (
    tester,
  ) async {
    expect(await open(tester, 'Nước'), LogMealMethod.water);
  });

  testWidgets('photo, typing and dictation are one entry', (tester) async {
    expect(await open(tester, 'Ghi bữa ăn'), LogMealMethod.meal);
  });

  testWidgets('the barcode scanner keeps its own entry', (tester) async {
    expect(await open(tester, 'Quét mã vạch'), LogMealMethod.barcode);
  });
}
