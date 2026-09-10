import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/auth/auth_controller.dart';
import 'core/theme/retro_theme.dart';
import 'router.dart';

class ChipHealthApp extends ConsumerStatefulWidget {
  const ChipHealthApp({super.key});

  @override
  ConsumerState<ChipHealthApp> createState() => _ChipHealthAppState();
}

class _ChipHealthAppState extends ConsumerState<ChipHealthApp> {
  @override
  void initState() {
    super.initState();
    // A stored refresh token should survive an app restart.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => ref.read(authControllerProvider.notifier).restore(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'ChipHealth',
      debugShowCheckedModeBanner: false,
      theme: buildRetroTheme(),
      routerConfig: router,
      locale: const Locale('vi'),
      supportedLocales: const [Locale('vi'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
    );
  }
}
