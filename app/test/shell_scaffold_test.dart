import 'package:chiphealth/features/home/home_widgets.dart';
import 'package:chiphealth/features/home/shell_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:chiphealth/core/l10n/gen/app_localizations.dart';

/// The tab bar is a bottomNavigationBar, and a bottomNavigationBar takes
/// whatever height its child asks for. A height-unconstrained child (a Center,
/// an Align without heightFactor) therefore eats the whole screen and leaves
/// the body with zero pixels — the screen renders empty with the bar floating
/// in the middle. This test pins the bar to its real height.
void main() {
  testWidgets('the nav bar leaves the body its screen', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final router = GoRouter(
      initialLocation: '/',
      routes: [
        ShellRoute(
          builder: (_, __, child) => ShellScaffold(child: child),
          routes: [
            GoRoute(
              path: '/',
              builder: (_, __) => const ColoredBox(
                color: Colors.amber,
                child: SizedBox.expand(child: Text('body')),
              ),
            ),
          ],
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        locale: const Locale('vi'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
      ),
    );
    await tester.pumpAndSettle();

    final body = tester.getSize(find.byType(ColoredBox).first);
    expect(body.height, greaterThan(700));

    // And the bar sits at the bottom, not in the middle of the screen.
    expect(tester.getCenter(find.byType(ShellScaffold)).dy, 422);
    expect(tester.getTopLeft(find.byIcon(Icons.home)).dy, greaterThan(700));
  });

  // The community is not a tab any more — the home feed carries it — so the "+"
  // is the only way into it from the bar. If that entry goes missing the screen
  // becomes unreachable outside a deep link.
  testWidgets('the "+" opens the way into the community', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final router = GoRouter(
      initialLocation: '/',
      routes: [
        ShellRoute(
          builder: (_, __, child) => ShellScaffold(child: child),
          routes: [
            GoRoute(path: '/', builder: (_, __) => const Text('home')),
            GoRoute(path: '/moments', builder: (_, __) => const Text('feed')),
          ],
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        locale: const Locale('vi'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AddButton), findsOneWidget);

    await tester.tap(find.byType(AddButton));
    await tester.pumpAndSettle();
    expect(find.text('Bữa ăn'), findsOneWidget);

    await tester.tap(find.text('Cộng đồng'));
    await tester.pumpAndSettle();
    expect(find.text('feed'), findsOneWidget);
  });
}
