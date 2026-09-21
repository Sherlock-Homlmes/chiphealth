import 'dart:convert';
import 'dart:typed_data';

import 'package:chiphealth/core/providers.dart';
import 'package:chiphealth/features/nutrition/moment_compose_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chiphealth/core/l10n/gen/app_localizations.dart';

// 1x1 transparent PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// Opens the dialog from a button; [onClosed] gets what it returned.
Future<void> _open(
  WidgetTester tester, {
  required void Function(String?) onClosed,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        mediaBytesProvider.overrideWith(
          (ref, id) async => Uint8List.fromList(_png),
        ),
      ],
      child: MaterialApp(
        locale: const Locale('vi'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async => onClosed(
                await showMomentComposeDialog(
                  context,
                  photoAssetId: 'asset-1',
                  initialCaption: 'Bún riêu cua · 582 kcal',
                ),
              ),
              child: const Text('share'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('share'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the photo and a pre-filled caption', (tester) async {
    await _open(tester, onClosed: (_) {});

    expect(find.text('Đăng lên Khoảnh khắc'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Bún riêu cua · 582 kcal'), findsOneWidget);
  });

  testWidgets('"Đăng" hands back what the user wrote', (tester) async {
    String? posted;
    await _open(tester, onClosed: (c) => posted = c);

    await tester.enterText(find.byType(TextField), '  Trưa nay ngon quá  ');
    await tester.tap(find.text('Đăng'));
    await tester.pumpAndSettle();

    expect(posted, 'Trưa nay ngon quá');
    expect(find.text('Đăng lên Khoảnh khắc'), findsNothing);
  });

  testWidgets('"Hủy" posts nothing', (tester) async {
    String? posted = 'untouched';
    await _open(tester, onClosed: (c) => posted = c);

    await tester.tap(find.text('Hủy'));
    await tester.pumpAndSettle();

    expect(posted, isNull);
    expect(find.text('Đăng lên Khoảnh khắc'), findsNothing);
  });
}
