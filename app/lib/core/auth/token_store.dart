import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Access token stays in memory (it dies with the process); the refresh token is
/// the only thing persisted, in the platform keystore rather than plain prefs.
class TokenStore {
  TokenStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _refreshKey = 'chiphealth.refreshToken';

  final FlutterSecureStorage _storage;

  String? _accessToken;
  int _expiresAt = 0;

  String? get accessToken => _accessToken;
  bool get isAccessTokenFresh =>
      _accessToken != null &&
      _expiresAt > DateTime.now().millisecondsSinceEpoch + 30000;

  Future<String?> readRefreshToken() => _storage.read(key: _refreshKey);

  Future<void> save({
    required String accessToken,
    required String refreshToken,
    required int expiresAt,
  }) async {
    _accessToken = accessToken;
    _expiresAt = expiresAt;
    await _storage.write(key: _refreshKey, value: refreshToken);
  }

  Future<void> clear() async {
    _accessToken = null;
    _expiresAt = 0;
    await _storage.delete(key: _refreshKey);
  }

  Future<bool> hasSession() async =>
      _accessToken != null || (await readRefreshToken()) != null;
}
