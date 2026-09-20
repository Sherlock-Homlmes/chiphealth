import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../api/api_client.dart';
import '../config/env.dart';
import '../models/models.dart';
import '../providers.dart';

class AuthState {
  const AuthState({
    this.user,
    this.loading = false,
    this.error,
    this.booted = false,
  });

  final AppUser? user;
  final bool loading;
  final String? error;
  final bool booted;

  bool get isSignedIn => user != null;

  AuthState copyWith({
    AppUser? user,
    bool? loading,
    String? error,
    bool? booted,
    bool clearUser = false,
  }) => AuthState(
    user: clearUser ? null : (user ?? this.user),
    loading: loading ?? this.loading,
    error: error,
    booted: booted ?? this.booted,
  );
}

/// Google is the only sign-in method. The app exchanges the Google **id_token**
/// for our own access/refresh pair; nothing Google-specific is stored after that.
class AuthController extends StateNotifier<AuthState> {
  AuthController(this._ref) : super(const AuthState());

  final Ref _ref;

  ApiClient get _api => _ref.read(apiClientProvider);

  Future<void> restore() async {
    final store = _ref.read(tokenStoreProvider);

    if (!await store.hasSession()) await seedDevSession();

    if (!await store.hasSession()) {
      state = state.copyWith(booted: true);
      return;
    }
    try {
      final data = (await _api.get<dynamic>('/v1/me') as Map)
          .cast<String, dynamic>();
      state = state.copyWith(
        user: AppUser.fromJson((data['user'] as Map).cast<String, dynamic>()),
        booted: true,
      );
    } catch (_) {
      state = state.copyWith(booted: true, clearUser: true);
    }
  }

  /// Changes the account's language and keeps the session in step, so the app
  /// re-renders in it without a round trip through /v1/me.
  Future<void> setLocale(String locale) async {
    final user = state.user;
    if (user == null || user.locale == locale) return;
    await _ref.read(profileRepositoryProvider).setLocale(locale);
    state = state.copyWith(user: user.copyWith(locale: locale));
  }

  /// Debug builds can be handed a refresh token (--dart-define) or, on web, ask
  /// the dev proxy for one. Refresh tokens rotate on first use, so a baked-in
  /// token would only ever log in one browser once — the endpoint hands each
  /// browser its own. Both paths are compiled out of release builds.
  ///
  /// Also called by the API client when the stored token turns out to be one the
  /// server has already retired, which is what a browser left open across a
  /// database reset is holding.
  Future<String?> seedDevSession() async {
    final devToken = Env.hasDevSession
        ? Env.devRefreshToken
        : await _fetchDevSessionToken();
    if (devToken == null) return null;
    await _ref
        .read(tokenStoreProvider)
        .save(accessToken: '', refreshToken: devToken, expiresAt: 0);
    return devToken;
  }

  Future<String?> _fetchDevSessionToken() async {
    if (!kDebugMode || !kIsWeb) return null;
    try {
      final res = await _api.getAnonymous<dynamic>('/__dev/session');
      return (res as Map)['refreshToken'] as String?;
    } catch (_) {
      // No dev proxy in front of us; fall through to the normal login screen.
      return null;
    }
  }

  Future<void> signInWithGoogle() async {
    state = state.copyWith(loading: true, error: null);
    try {
      final google = GoogleSignIn(
        scopes: const ['email', 'profile'],
        serverClientId: Env.googleServerClientId.isEmpty
            ? null
            : Env.googleServerClientId,
        clientId: Env.googleIosClientId.isEmpty ? null : Env.googleIosClientId,
      );
      final account = await google.signIn();
      if (account == null) {
        state = state.copyWith(loading: false);
        return; // user dismissed the sheet
      }
      final auth = await account.authentication;
      final idToken = auth.idToken;
      if (idToken == null) {
        state = state.copyWith(
          loading: false,
          error: 'Google không trả về id_token',
        );
        return;
      }

      final data =
          (await _api.postAnonymous<dynamic>(
                    '/v1/auth/google',
                    body: {'idToken': idToken, 'platform': 'mobile'},
                  )
                  as Map)
              .cast<String, dynamic>();

      await _ref
          .read(tokenStoreProvider)
          .save(
            accessToken: data['accessToken'] as String,
            refreshToken: data['refreshToken'] as String,
            expiresAt: (data['expiresAt'] as num).toInt(),
          );

      state = AuthState(
        user: AppUser.fromJson((data['user'] as Map).cast<String, dynamic>()),
        booted: true,
      );
    } catch (err) {
      state = state.copyWith(loading: false, error: '$err');
    }
  }

  Future<void> signOut() async {
    await _ref.read(tokenStoreProvider).clear();
    state = const AuthState(booted: true);
  }
}

final authControllerProvider = StateNotifierProvider<AuthController, AuthState>(
  (ref) => AuthController(ref),
);
