// Tiny key/value store for small secrets (auth tokens, server URL, device id).
//
// Why not flutter_secure_storage? On macOS the keychain backend needs the
// `keychain-access-groups` entitlement, which requires a paid Apple Dev
// account team prefix — debug builds without one fail to launch. We get
// the same practical isolation by writing a single JSON file inside the
// app's sandboxed Documents directory (mode 0600 on macOS/Linux).
//
// If the user needs hardware-backed keychain storage later, swap this
// implementation; the call sites use a tiny interface.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

abstract class SecureKv {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FileSecureKv implements SecureKv {
  Map<String, String>? _cache;
  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) await dir.create(recursive: true);
    return File(p.join(dir.path, 'notee-secrets.json'));
  }

  Future<Map<String, String>> _load() async {
    if (_cache != null) return _cache!;
    final f = await _file();
    if (!await f.exists()) {
      _cache = {};
      return _cache!;
    }
    try {
      final raw = await f.readAsString();
      final m = jsonDecode(raw) as Map<String, dynamic>;
      _cache = m.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      _cache = {};
    }
    return _cache!;
  }

  Future<void> _persist() async {
    final f = await _file();
    await f.writeAsString(jsonEncode(_cache ?? const {}), flush: true);
    if (!Platform.isWindows) {
      try {
        await Process.run('chmod', ['600', f.path]);
      } catch (_) {/* best-effort */}
    }
  }

  @override
  Future<String?> read(String key) async => (await _load())[key];

  @override
  Future<void> write(String key, String value) async {
    await _load();
    _cache![key] = value;
    await _persist();
  }

  @override
  Future<void> delete(String key) async {
    await _load();
    _cache!.remove(key);
    await _persist();
  }
}
