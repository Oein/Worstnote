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
}
