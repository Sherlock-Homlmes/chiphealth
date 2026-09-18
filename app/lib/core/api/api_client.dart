import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../auth/token_store.dart';
import '../config/env.dart';
import 'api_exception.dart';

/// Dio client for the ChipHealth API (see api_design.md).
///
/// Owns the two things every call needs: the bearer header, and a single-flight
/// refresh on 401 — N parallel 401s must trigger exactly one refresh, or token
/// rotation invalidates the token the other callers are still holding.
class ApiClient {
  ApiClient({required this.tokens, Dio? dio})
    : _dio = dio ?? Dio(BaseOptions(baseUrl: Env.apiBaseUrl)) {
    _dio.options
      ..connectTimeout = const Duration(seconds: 10)
      ..receiveTimeout = const Duration(seconds: 30)
      ..headers['Content-Type'] = 'application/json'
      ..validateStatus = (status) => status != null && status < 500;
  }

  final TokenStore tokens;
  final Dio _dio;

  Future<void> Function()? onSessionExpired;

  /// Asked for a replacement refresh token when the stored one is refused,
  /// before giving up on the session. Dev builds wire this to the dev-session
  /// endpoint; in release builds nothing sets it and a refusal signs the user
  /// out as before.
  Future<String?> Function()? recoverSession;

  Completer<String?>? _refreshInFlight;

  Future<T> get<T>(String path, {Map<String, dynamic>? query}) =>
      _send<T>('GET', path, query: query);

  /// [receiveTimeout] overrides the client-wide 30 s for the few calls that
  /// legitimately run long — an assistant turn makes several model calls.
  Future<T> post<T>(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Duration? receiveTimeout,
  }) => _send<T>(
    'POST',
    path,
    body: body,
    query: query,
    receiveTimeout: receiveTimeout,
  );

  Future<T> put<T>(String path, {Object? body, Map<String, dynamic>? query}) =>
      _send<T>('PUT', path, body: body, query: query);

  /// Bytes back rather than JSON — image and audio endpoints answer with the
  /// object itself.
  Future<List<int>> getBytes(String path) async =>
      _send<List<int>>('GET', path, responseType: ResponseType.bytes);

  /// Raw bytes with their own content type — used where the payload is the body
  /// itself rather than a JSON field, e.g. a voice clip for meal logging.
  Future<T> postBytes<T>(
    String path,
    List<int> bytes, {
    required String contentType,
  }) => _send<T>('POST', path, body: _raw(bytes), contentType: contentType);

  /// The same for an upload target that expects PUT — the media endpoint.
  Future<T> putBytes<T>(
    String path,
    List<int> bytes, {
    required String contentType,
  }) => _send<T>('PUT', path, body: _raw(bytes), contentType: contentType);

  /// Dio hands a body to the adapter untouched only when it is exactly a
  /// [Uint8List]; any other `List<int>` goes through the transformer, which
  /// stringifies it — the server would store "[255, 216, ...]" instead of the
  /// file. Copying here is cheaper than debugging that twice.
  static Uint8List _raw(List<int> bytes) =>
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

  /// A token good enough to open a stream with, refreshing first when the one
  /// in hand is spent. The SSE endpoint takes its token in the query string —
  /// EventSource cannot set headers — so there is no 401-then-retry to fall
  /// back on the way [_send] has.
  Future<String?> streamToken() async {
    if (tokens.isAccessTokenFresh) return tokens.accessToken;
    return await _refreshAccessToken() ?? tokens.accessToken;
  }

  /// Absolute URL for a streaming endpoint, token included.
  Future<Uri?> streamUri(
    String path, {
    Map<String, String> query = const {},
  }) async {
    final token = await streamToken();
    if (token == null || token.isEmpty) return null;
    return Uri.parse(
      '${Env.apiBaseUrl}$path',
    ).replace(queryParameters: {...query, 'access_token': token});
  }

  Future<T> patch<T>(String path, {Object? body}) =>
      _send<T>('PATCH', path, body: body);

  Future<T> delete<T>(String path) => _send<T>('DELETE', path);

  Future<T> _send<T>(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    bool allowRetry = true,
    bool anonymous = false,
    String? contentType,
    ResponseType? responseType,
    Duration? receiveTimeout,
  }) async {
    final headers = <String, dynamic>{};
    final accessToken = tokens.accessToken;
    if (!anonymous && accessToken != null && accessToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $accessToken';
    }
    if (contentType != null) headers['Content-Type'] = contentType;

    Response<dynamic> res;
    try {
      res = await _dio.request<dynamic>(
        path,
        data: body,
        queryParameters: query?..removeWhere((_, v) => v == null),
        options: Options(
          method: method,
          headers: headers,
          responseType: responseType,
          receiveTimeout: receiveTimeout,
        ),
      );
    } on DioException catch (err) {
      throw ApiException(
        statusCode: 0,
        code: 'NETWORK_ERROR',
        message: 'Không kết nối được máy chủ (${err.type.name}).',
      );
    }

    if (res.statusCode == 401 && allowRetry && !anonymous) {
      final token = await _refreshAccessToken();
      if (token != null) {
        return _send<T>(
          method,
          path,
          body: body,
          query: query,
          allowRetry: false,
          contentType: contentType,
          responseType: responseType,
          receiveTimeout: receiveTimeout,
        );
      }
    }

    if (res.statusCode != null && res.statusCode! >= 400) {
      throw _toException(res);
    }
    return res.data as T;
  }

  ApiException _toException(Response<dynamic> res) {
    final data = res.data;
    if (data is Map && data['error'] is Map) {
      final error = (data['error'] as Map).cast<String, dynamic>();
      final details = error['details'];
      final rawIssues = details is Map ? details['issues'] : null;
      return ApiException(
        statusCode: res.statusCode ?? 0,
        code: error['code'] as String? ?? 'INTERNAL',
        message: error['message'] as String? ?? 'Có lỗi xảy ra',
        issues: rawIssues is List
            ? rawIssues
                  .whereType<Map>()
                  .map((e) => ApiIssue.fromJson(e.cast<String, dynamic>()))
                  .toList()
            : const [],
      );
    }
    return ApiException(
      statusCode: res.statusCode ?? 0,
      code: 'INTERNAL',
      message: 'Máy chủ trả về lỗi ${res.statusCode}',
    );
  }

  Future<String?> _refreshAccessToken() async {
    final existing = _refreshInFlight;
    if (existing != null) return existing.future;

    final completer = Completer<String?>();
    _refreshInFlight = completer;

    try {
      var token = await tokens.readRefreshToken();
      if (token == null) {
        completer.complete(null);
        return null;
      }

      var access = await _exchange(token);

      // The server refused the stored token. In a dev build that usually means
      // the token belongs to a session the database no longer has — a browser
      // left open across a reset holds one, and it is refused exactly once.
      // Asking for a fresh dev session here rather than at boot heals every
      // request already in flight, not just the one that noticed.
      if (access == null) {
        await tokens.clear();
        token = await recoverSession?.call();
        if (token != null) access = await _exchange(token);
      }

      if (access == null) {
        await tokens.clear();
        await onSessionExpired?.call();
      }
      completer.complete(access);
      return access;
    } catch (_) {
      // Network failure: the refresh token may still be valid, so keep it and
      // let the caller surface a connection error instead of signing out.
      completer.complete(null);
      return null;
    } finally {
      _refreshInFlight = null;
    }
  }

  /// One refresh round trip. Null means the server refused the token; a network
  /// failure throws, so the caller can tell the two apart.
  Future<String?> _exchange(String refreshToken) async {
    final res = await _dio.post<dynamic>(
      '/v1/auth/refresh',
      data: {'refreshToken': refreshToken},
    );
    if (res.statusCode != 200 || res.data is! Map) return null;

    final data = (res.data as Map).cast<String, dynamic>();
    await tokens.save(
      accessToken: data['accessToken'] as String,
      refreshToken: data['refreshToken'] as String,
      expiresAt: (data['expiresAt'] as num).toInt(),
    );
    return data['accessToken'] as String;
  }

  /// Auth endpoints must not carry (or refresh) a bearer token.
  Future<T> postAnonymous<T>(String path, {Object? body}) =>
      _send<T>('POST', path, body: body, anonymous: true, allowRetry: false);

  Future<T> getAnonymous<T>(String path) =>
      _send<T>('GET', path, anonymous: true, allowRetry: false);
}
