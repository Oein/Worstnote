// HTTP client for the Notee API.
//
// Wire format mirrors `shared/docs/SYNC.md`. The push/pull payloads are
// untyped Map<String, dynamic> so the server schema can evolve without
// requiring code regeneration here.

import 'dart:io';

import 'package:dio/dio.dart';

class AuthTokens {
  AuthTokens({
    required this.userId,
    required this.accessToken,
    required this.expiresAt,
  });
  final String userId;
  String accessToken;
  DateTime expiresAt;
}

typedef OnTokens = void Function(AuthTokens tokens);

/// Called on 401 — the token is invalid or expired. The caller should clear
/// auth state so the user is prompted to re-login.
typedef OnLogout = void Function();

class ApiClient {
  ApiClient({
    required this.baseUrl,
    required this.deviceId,
    AuthTokens? tokens,
    this.onTokens,
    this.onLogout,
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
  final OnLogout? onLogout;
  final Dio _dio;
  AuthTokens? _tokens;

  AuthTokens? get tokens => _tokens;
  bool get isAuthenticated => _tokens != null;

  void setTokens(AuthTokens? t) {
    _tokens = t;
    if (t != null) onTokens?.call(t);
  }

  // ── Auth ───────────────────────────────────────────────────────────
  /// Server-driven captcha config. Returns `{enabled, sitekey, provider}`.
  /// Client should fetch this before showing the signup form.
  Future<Map<String, dynamic>> captchaConfig() async {
    final r = await _dio.get<Map<String, dynamic>>('/v1/auth/captcha');
    return r.data as Map<String, dynamic>;
  }

  Future<AuthTokens> signup(String email, String password,
      {String? captchaToken}) async {
    final r = await _dio.post<Map<String, dynamic>>('/v1/auth/signup', data: {
      'email': email,
      'password': password,
      'deviceId': deviceId,
      if (captchaToken != null) 'captchaToken': captchaToken,
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

  Future<void> logout() async {
    if (_tokens == null) return;
    try {
      await _dio.post<Map<String, dynamic>>('/v1/auth/logout', options: _bearerOpts());
    } catch (_) {/* ignore network errors on logout */}
    setTokens(null);
  }

  // ── Health ─────────────────────────────────────────────────────────
  Future<void> healthCheck() async {
    await _dio.get<dynamic>('/v1/health');
  }

  // ── Sync ───────────────────────────────────────────────────────────
  Future<List<Map<String, dynamic>>> listNotes() async {
    final r = await _withAuthRetry(() => _dio.get(
          '/v1/sync/notes',
          options: _bearerOpts(),
        ));
    final data = r.data as Map<String, dynamic>;
    return List<Map<String, dynamic>>.from(data['notes'] as List? ?? const []);
  }

  Future<Map<String, dynamic>> syncPush(
      String noteId, Map<String, dynamic> body) async {
    final r = await _withAuthRetry(() => _dio.post(
          '/v1/sync/$noteId/push',
          data: body,
          options: _bearerOpts(),
        ));
    return r.data as Map<String, dynamic>;
  }

  /// Deletes [noteId] on the server (cascades pages/layers/objects/history).
  /// Idempotent — returns normally even when the note is already gone.
  Future<void> deleteNote(String noteId) async {
    await _withAuthRetry(() => _dio.delete(
          '/v1/sync/$noteId',
          options: _bearerOpts(),
        ));
  }

  Future<Map<String, dynamic>> syncPull(String noteId, int since) async {
    final r = await _withAuthRetry(() => _dio.get(
          '/v1/sync/$noteId/pull',
          queryParameters: {'since': since},
          options: _bearerOpts(),
        ));
    return r.data as Map<String, dynamic>;
  }

  // ── Assets (PDF/image files) ───────────────────────────────────────

  /// Returns true when [assetId] already exists on the server.
  Future<bool> assetExists(String assetId) async {
    try {
      await _withAuthRetry(() => _dio.head(
            '/v1/assets/$assetId',
            options: _bearerOpts(),
          ));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Uploads [file] for [assetId] as a streaming PUT (no full-memory copy).
  /// Calls [onProgress] periodically with (bytesSent, totalBytes).
  Future<void> uploadAsset(
    String assetId,
    File file, {
    void Function(int sent, int total)? onProgress,
  }) async {
    final length = await file.length();
    await _withAuthRetry(() => _dio.put(
          '/v1/assets/$assetId',
          data: file.openRead(),
          options: Options(
            sendTimeout: const Duration(minutes: 10),
            headers: {
              'Content-Type': 'application/octet-stream',
              'Content-Length': length,
              if (_tokens != null)
                'authorization': 'Bearer ${_tokens!.accessToken}',
            },
            responseType: ResponseType.bytes,
          ),
          onSendProgress: onProgress,
        ));
  }

  /// Downloads [assetId] directly to [savePath] (streaming, no memory copy).
  /// Returns false if not found or on error.
  ///
  /// Atomic-write pattern: download into "$savePath.partial" first and
  /// rename only after the body has fully landed. If the process is killed
  /// mid-download, the .partial sticks around (cleaned up on next launch by
  /// AssetService.cleanupPartialDownloads) but [savePath] never contains a
  /// corrupt half-file that would crash the PDF renderer next time.
  Future<bool> downloadAssetToFile(
    String assetId,
    String savePath, {
    void Function(int received, int total)? onProgress,
  }) async {
    final tempPath = '$savePath.partial';
    try {
      // Drop any stale temp file from a prior interrupted attempt.
      try { File(tempPath).deleteSync(); } catch (_) {}
      await _withAuthRetry(() => _dio.download(
            '/v1/assets/$assetId',
            tempPath,
            options: Options(
              receiveTimeout: const Duration(minutes: 10),
              headers: _tokens != null
                  ? {'authorization': 'Bearer ${_tokens!.accessToken}'}
                  : null,
            ),
            onReceiveProgress: onProgress,
          ));
      // Promote temp → final atomically on success.
      await File(tempPath).rename(savePath);
      return true;
    } catch (_) {
      // Clean up partial file on failure.
      try { File(tempPath).deleteSync(); } catch (_) {}
      try { File(savePath).deleteSync(); } catch (_) {}
      return false;
    }
  }

  // ── History ────────────────────────────────────────────────────────
  /// Asks the server to seal all uncommitted revisions into a new commit.
  /// No-op if there are no uncommitted revisions (returns committed:false).
  Future<Map<String, dynamic>> commitNote(String noteId, {String? message}) async {
    final r = await _withAuthRetry(() => _dio.post(
          '/v1/sync/$noteId/commit',
          data: message != null ? {'message': message} : null,
          options: _bearerOpts(),
        ));
    return r.data as Map<String, dynamic>;
  }

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
        setTokens(null);
        onLogout?.call();
      }
      rethrow;
    }
  }
}
