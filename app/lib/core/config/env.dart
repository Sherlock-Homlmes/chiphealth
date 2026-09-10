import 'package:flutter/foundation.dart';

/// Build-time configuration. Pass with --dart-define, e.g.
///   flutter run --dart-define=API_BASE_URL=https://api.chiphealth.app
class Env {
  const Env._();

  static const _apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8787', // Android emulator -> host machine
  );

  /// On web, an empty API_BASE_URL means "same origin as the page". That lets a
  /// dev build be served behind a proxy that forwards /v1 to the Worker, which
  /// sidesteps CORS entirely and works from whatever host the browser used.
  static String get apiBaseUrl {
    if (_apiBaseUrl.isNotEmpty) return _apiBaseUrl;
    return kIsWeb ? Uri.base.origin : 'http://10.0.2.2:8787';
  }

  /// Google OAuth client ids. iOS needs its own; Android reads from google-services.
  static const googleServerClientId =
      String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');
  static const googleIosClientId =
      String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');

  /// Debug-only shortcut for testing without a Google OAuth client: a refresh
  /// token minted by `backend/npm run dev:session` is seeded into the token
  /// store at boot. Ignored in release builds, and empty unless explicitly
  /// passed on the command line — there is no way to reach it from the UI.
  static const devRefreshToken = String.fromEnvironment('DEV_REFRESH_TOKEN');

  static bool get hasDevSession => kDebugMode && devRefreshToken.isNotEmpty;

  /// App Group / shared preference key the home-screen widget reads.
  static const widgetGroupId = 'group.vn.chiphealth.moments';
  static const widgetName = 'MomentsWidget';
}
