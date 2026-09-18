import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'tokens.dart';

/// One ThemeData for the whole app. shadcn_ui components inherit from the
/// Material theme, so styling here rather than per-widget keeps the retro look
/// consistent instead of drifting screen by screen.
ThemeData buildRetroTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: RetroTokens.paper,
    colorScheme: const ColorScheme.light(
      primary: RetroTokens.accent,
      onPrimary: Colors.white,
      secondary: RetroTokens.info,
      surface: RetroTokens.paperRaised,
      onSurface: RetroTokens.ink,
      error: RetroTokens.accent,
    ),
  );

  final display = GoogleFonts.spaceGroteskTextTheme(base.textTheme);
  final mono = GoogleFonts.ibmPlexMono();

  return base.copyWith(
    textTheme: display
        .apply(bodyColor: RetroTokens.ink, displayColor: RetroTokens.ink)
        .copyWith(
          // Numbers are read as data, so they always get the monospace face.
          titleLarge: mono.copyWith(
            fontSize: 28,
            fontWeight: FontWeight.w600,
            color: RetroTokens.ink,
          ),
          labelSmall: mono.copyWith(fontSize: 11, color: RetroTokens.inkFaint),
        ),
    appBarTheme: AppBarTheme(
      backgroundColor: RetroTokens.paper,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: display.titleMedium?.copyWith(
        fontWeight: FontWeight.w700,
        color: RetroTokens.ink,
      ),
      iconTheme: const IconThemeData(color: RetroTokens.ink),
    ),
    dividerTheme: const DividerThemeData(
      color: RetroTokens.paperSunk,
      thickness: 1,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: RetroTokens.paperRaised,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: _inputBorder(RetroTokens.ink),
      enabledBorder: _inputBorder(RetroTokens.ink),
      focusedBorder: _inputBorder(RetroTokens.accent),
      errorBorder: _inputBorder(RetroTokens.accent),
      // Resting inside an empty field the label doubles as a placeholder, so
      // it is faint there and only takes full ink once it floats.
      labelStyle: const TextStyle(color: RetroTokens.inkFaint),
      floatingLabelStyle: const TextStyle(color: RetroTokens.inkSoft),
      // Placeholders have to read as "example", not as typed text.
      hintStyle: TextStyle(
        color: RetroTokens.inkFaint.withValues(alpha: 0.55),
        fontWeight: FontWeight.w400,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: RetroTokens.accent,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: _buttonShape(),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        textStyle: display.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: RetroTokens.ink,
        backgroundColor: RetroTokens.paperRaised,
        side: const BorderSide(
          color: RetroTokens.ink,
          width: RetroTokens.border,
        ),
        shape: _buttonShape(),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: RetroTokens.paperRaised,
      surfaceTintColor: Colors.transparent,
      indicatorColor: RetroTokens.accentSoft,
      indicatorShape: _buttonShape(),
      labelTextStyle: WidgetStatePropertyAll(
        display.labelSmall?.copyWith(color: RetroTokens.inkSoft),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: RetroTokens.ink,
      contentTextStyle: const TextStyle(color: RetroTokens.paper),
      shape: _buttonShape(),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

// The same soft radius as the cards, so fields and buttons read as part of
// the rounded surface language instead of square outliers.
OutlineInputBorder _inputBorder(Color color) => OutlineInputBorder(
  borderRadius: BorderRadius.circular(RetroTokens.radiusLg),
  borderSide: BorderSide(color: color, width: RetroTokens.border),
);

RoundedRectangleBorder _buttonShape() => RoundedRectangleBorder(
  borderRadius: BorderRadius.circular(RetroTokens.radiusLg),
  side: const BorderSide(color: RetroTokens.ink, width: RetroTokens.border),
);
