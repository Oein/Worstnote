// AssetService — content-addressed local store for imported PDF/image
// originals. Files are saved at `<docs>/notee-assets/<sha256>` and
// referenced by SHA-256 in PageBackground objects.

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AssetRef {
  AssetRef({required this.id, required this.file, required this.mime});
  final String id; // sha256 hex
  final File file;
  final String mime;
}

class AssetService {
  Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(docs.path, 'notee-assets'));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<AssetRef> putBytes(Uint8List bytes, {required String mime}) async {
    final id = sha256.convert(bytes).toString();
    final d = await _dir();
    final f = File(p.join(d.path, id));
    if (!await f.exists()) await f.writeAsBytes(bytes, flush: true);
    return AssetRef(id: id, file: f, mime: mime);
  }

  Future<File?> fileFor(String id) async {
    final d = await _dir();
    final f = File(p.join(d.path, id));
    return await f.exists() ? f : null;
  }

  /// Returns the expected local path for [id] (does not check existence).
  Future<String> assetPath(String id) async {
    final d = await _dir();
    return p.join(d.path, id);
  }

  /// Sweeps the asset directory for leftover `*.partial` files from
  /// downloads that were interrupted by a process kill. Called once at
  /// app launch — those bytes are useless and would only confuse a later
  /// resume attempt. Also deletes any 0-byte final files that signal a
  /// cleanly-failed download whose error path didn't run.
  Future<void> cleanupPartialDownloads() async {
    try {
      final d = await _dir();
      await for (final ent in d.list()) {
        if (ent is! File) continue;
        try {
          if (ent.path.endsWith('.partial')) {
            await ent.delete();
            continue;
          }
          if (await ent.length() == 0) {
            await ent.delete();
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Deletes the asset file for [id]. Used when a corrupt PDF is detected
  /// so the next sync can re-download a clean copy.
  Future<void> invalidate(String id) async {
    try {
      final d = await _dir();
      final f = File(p.join(d.path, id));
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
