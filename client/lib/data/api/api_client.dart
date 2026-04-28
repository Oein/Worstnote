// HTTP client for the Notee API. Wraps dio with auto refresh-on-401.
//
// Wire format mirrors `shared/docs/SYNC.md`. The push/pull payloads are
// untyped Map<String, dynamic> so the server schema can evolve without
// requiring code regeneration here.

import 'package:dio/dio.dart';

class AuthTokens {
  AuthTokens({
    required this.userId,
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });
  final String userId;
  String accessToken;
  String refreshToken;
  DateTime expiresAt;
}

typedef OnTokens = void Function(AuthTokens tokens);

class ApiClient {
  ApiClient({
    required this.baseUrl,
    required this.deviceId,
    AuthTokens? tokens,
    this.onTokens,
  })  : _tokens = tokens,
        _dio = Dio(BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 30),
          contentType: 'application/json',
        ));

  final String baseUrl;
  final String deviceId;
  final OnTokens? onTokens;
  final Dio _dio;
  AuthTokens? _tokens;

  AuthTokens? get tokens => _tokens;
  bool get isAuthenticated => _tokens != null;

  void setTokens(AuthTokens? t) {
    _tokens = t;
    if (t != null) onTokens?.call(t);
  }

  // ── Auth ───────────────────────────────────────────────────────────
  Future<AuthTokens> signup(String email, String password) async {
    final r = await _dio.post<Map<String, dynamic>>('/v1/auth/signup', data: {
      'email': email,
      'password': password,
      'deviceId': deviceId,
    });
    return _decodeTokens(r.data as Map<String, dynamic>);
  }

  Future<AuthTokens> login(String email, String password) async {
    final r = await _dio.post<Map<String, dynamic>>('/v1/auth/login', data: {
      'email': email,
      'password': password,
      'deviceId': deviceId,
    });
    return _decodeTokens(r.data as Map<String, dynamic>);
  }

  Future<AuthTokens> refresh() async {
    final t = _tokens;
    if (t == null) throw StateError('not authenticated');
    final r = await _dio.post<Map<String, dynamic>>('/v1/auth/refresh', data: {
      'refreshToken': t.refreshToken,
      'deviceId': deviceId,
    });
    return _decodeTokens(r.data as Map<String, dynamic>);
  }

  Future<void> logout() async {
    if (_tokens == null) return;
    try {
      await _dio.post<Map<String, dynamic>>('/v1/auth/logout', options: _bearerOpts());
    } catch (_) {/* ignore network errors on logout */}
    setTokens(null);
  }

  // ── Sync ───────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> syncPush(
      String noteId, Map<String, dynamic> body) async {
    final r = await _withAuthRetry(() => _dio.post(
          '/v1/sync/$noteId/push',
          data: body,
          options: _bearerOpts(),
        ));
    return r.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> syncPull(String noteId, int since) async {
    final r = await _withAuthRetry(() => _dio.get(
          '/v1/sync/$noteId/pull',
          queryParameters: {'since': since},
          options: _bearerOpts(),
        ));
    return r.data as Map<String, dynamic>;
  }

  // ── History ────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> historyList(String noteId) async {
    final r = await _withAuthRetry(() => _dio.get(
          '/v1/sync/$noteId/history',
          options: _bearerOpts(),
        ));
    return r.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> historySnapshot(
      String noteId, String commitId) async {
    final r = await _withAuthRetry(() => _dio.get(
          '/v1/sync/$noteId/history/$commitId',
          options: _bearerOpts(),
        ));
    return r.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> historyRestore(
      String noteId, String commitId) async {
    final r = await _withAuthRetry(() => _dio.post(
          '/v1/sync/$noteId/history/$commitId/restore',
          options: _bearerOpts(),
        ));
    return r.data as Map<String, dynamic>;
  }

  // ── Conflicts ──────────────────────────────────────────────────────
  Future<Map<String, dynamic>> conflictGet(
      String noteId, String sid) async {
    final r = await _withAuthRetry(() => _dio.get(
          '/v1/sync/$noteId/conflicts/$sid',
          options: _bearerOpts(),
        ));
    return r.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> conflictResolve(
      String noteId, String sid, List<Map<String, dynamic>> resolutions) async {
    final r = await _withAuthRetry(() => _dio.post(
          '/v1/sync/$noteId/conflicts/$sid/resolve',
          data: {'resolutions': resolutions},
          options: _bearerOpts(),
        ));
    return r.data as Map<String, dynamic>;
  }

  // ── Internals ──────────────────────────────────────────────────────
  Options _bearerOpts() {
    final t = _tokens;
    return Options(headers: {
      if (t != null) 'authorization': 'Bearer ${t.accessToken}',
    });
  }

  AuthTokens _decodeTokens(Map<String, dynamic> json) {
    final t = AuthTokens(
      userId: json['userId'] as String,
      accessToken: json['accessToken'] as String,
      refreshToken: json['refreshToken'] as String,
      expiresAt: DateTime.now().toUtc().add(
            Duration(seconds: (json['expiresIn'] as num).toInt()),
          ),
    );
    setTokens(t);
    return t;
  }

  Future<Response<dynamic>> _withAuthRetry(
      Future<Response<dynamic>> Function() fn) async {
    try {
      return await fn();
    } on DioException catch (e) {
      if (e.response?.statusCode == 401 && _tokens != null) {
        await refresh();
        return await fn();
      }
      rethrow;
    }
  }
}
