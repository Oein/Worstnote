// Auth state — currently authenticated user + tokens, plus the configured
// server URL. Tokens are persisted via flutter_secure_storage so they
// survive app restarts.

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../data/api/api_client.dart';
import '../../data/secure_kv.dart';

const _storeKeyTokens = 'notee.auth.tokens';
const _storeKeyServer = 'notee.auth.server';
const _storeKeyDevice = 'notee.auth.device';
const _defaultServer = 'http://localhost:8080';

class AuthState {
  AuthState({
    required this.serverUrl,
    required this.deviceId,
    this.tokens,
  });
  final String serverUrl;
  final String deviceId;
  final AuthTokens? tokens;

  bool get isLoggedIn => tokens != null;
}

class AuthController extends AsyncNotifier<AuthState> {
  static final SecureKv _storage = FileSecureKv();

  @override
  Future<AuthState> build() async {
    final serverUrl = await _storage.read(_storeKeyServer) ?? _defaultServer;
    final deviceId = await _ensureDeviceId();
    final raw = await _storage.read(_storeKeyTokens);
    AuthTokens? tokens;
    if (raw != null) {
      tokens = _decodeTokens(raw);
    }
    return AuthState(serverUrl: serverUrl, deviceId: deviceId, tokens: tokens);
  }

  ApiClient _newClient(AuthState s) => ApiClient(
        baseUrl: s.serverUrl,
        deviceId: s.deviceId,
        tokens: s.tokens,
        onTokens: (t) => _persistTokens(t),
      );

  Future<void> setServerUrl(String url) async {
    await _storage.write(_storeKeyServer, url);
    final cur = state.value ?? await build();
    state = AsyncData(AuthState(
      serverUrl: url,
      deviceId: cur.deviceId,
      tokens: cur.tokens,
    ));
  }

  Future<void> signup(String email, String password) async {
    final s = state.value ?? await build();
    final api = _newClient(s);
    await api.signup(email, password);
    await _persistTokens(api.tokens);
    state = AsyncData(AuthState(
      serverUrl: s.serverUrl,
      deviceId: s.deviceId,
      tokens: api.tokens,
    ));
  }

  Future<void> login(String email, String password) async {
    final s = state.value ?? await build();
    final api = _newClient(s);
    await api.login(email, password);
    await _persistTokens(api.tokens);
    state = AsyncData(AuthState(
      serverUrl: s.serverUrl,
      deviceId: s.deviceId,
      tokens: api.tokens,
    ));
  }

  Future<void> logout() async {
    final s = state.value;
    if (s == null) return;
    final api = _newClient(s);
    await api.logout();
    await _storage.delete(_storeKeyTokens);
    state = AsyncData(AuthState(
      serverUrl: s.serverUrl,
      deviceId: s.deviceId,
      tokens: null,
    ));
  }

  /// Clears local auth tokens without a server call. Used when the server
  /// reports that the refresh token is invalid — the session is already dead,
  /// so we just need to clean up local state and prompt re-login.
  Future<void> clearTokens() async {
    await _storage.delete(_storeKeyTokens);
    final cur = state.value;
    if (cur != null) {
      state = AsyncData(AuthState(
        serverUrl: cur.serverUrl,
        deviceId: cur.deviceId,
        tokens: null,
      ));
    }
  }

  /// Called by external API clients when they refresh the token so the new
  /// tokens are persisted and the auth state stays up-to-date.
  Future<void> updateTokens(AuthTokens t) async {
    await _persistTokens(t);
    final cur = state.value;
    if (cur != null) {
      state = AsyncData(AuthState(
        serverUrl: cur.serverUrl,
        deviceId: cur.deviceId,
        tokens: t,
      ));
    }
  }

  Future<void> _persistTokens(AuthTokens? t) async {
    if (t == null) {
      await _storage.delete(_storeKeyTokens);
      return;
    }
    final raw =
        '${t.userId}|${t.accessToken}|${t.refreshToken}|${t.expiresAt.toIso8601String()}';
    await _storage.write(_storeKeyTokens, raw);
  }

  AuthTokens? _decodeTokens(String raw) {
    final parts = raw.split('|');
    if (parts.length != 4) return null;
    return AuthTokens(
      userId: parts[0],
      accessToken: parts[1],
      refreshToken: parts[2],
      expiresAt: DateTime.tryParse(parts[3]) ?? DateTime.now(),
    );
  }

  Future<String> _ensureDeviceId() async {
    var id = await _storage.read(_storeKeyDevice);
    if (id == null) {
      final platformTag = kIsWeb
          ? 'web'
          : (Platform.isMacOS
              ? 'mac'
              : (Platform.isIOS ? 'ios' : (Platform.isAndroid ? 'and' : 'oth')));
      id = '$platformTag-${newId()}';
      await _storage.write(_storeKeyDevice, id);
    }
    return id;
  }
}

final authProvider =
    AsyncNotifierProvider<AuthController, AuthState>(AuthController.new);

/// Convenience: build an [ApiClient] for use in sync code. Throws if the
/// auth state isn't loaded yet.
///
/// Pass [onTokens] to persist refreshed tokens back to the auth state so that
/// rotated refresh tokens are not lost between requests.
/// Pass [onLogout] to clear auth state when the refresh token itself is invalid
/// (so the user is prompted to re-login instead of seeing repeated 401 errors).
ApiClient apiFor(AuthState s, {OnTokens? onTokens, OnLogout? onLogout}) => ApiClient(
      baseUrl: s.serverUrl,
      deviceId: s.deviceId,
      tokens: s.tokens,
      onTokens: onTokens,
      onLogout: onLogout,
    );
