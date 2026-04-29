import 'dart:typed_data';
import 'dart:io';
import 'dart:convert';
import 'package:archive/archive_io.dart';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/bv41.dart';

void findStrings(Uint8List bytes, String target, String ctx, {int depth = 0}) {
  if (depth > 5) return;
  try {
    final fields = PbReader(bytes).readAll();
    for (final f in fields) {
      if (f.wireType == PbWireType.lengthDelim) {
        final bs = f.asBytes;
        try {
          final s = const Utf8Codec(allowMalformed: true).decode(bs);
          if (s.contains(target)) print('$ctx.[${f.number}] "$s"');
        } catch (_) {}
        findStrings(bs, target, '$ctx.[${f.number}]', depth: depth + 1);
        for (var i = 0; i + 4 <= bs.length; i++) {
          if (bs[i]==0x62&&bs[i+1]==0x76&&bs[i+2]==0x34&&bs[i+3]==0x31) {
            try {
              final dec = Bv41.decode(bs, i);
              findStrings(Uint8List.fromList(dec), target, '$ctx.[${f.number}]@bv41', depth: depth+1);
            } catch(_) {}
          }
        }
      }
    }
  } catch (_) {}
}

Future<void> main(List<String> args) async {
  final path = args[0];
  final target = args[1];
  final f = File(path);
  if (f.existsSync()) {
    // zip-based goodnotes
    final archive = ZipDecoder().decodeBytes(f.readAsBytesSync());
    for (final entry in archive) {
      if (!entry.isFile) continue;
      if (!entry.name.startsWith('notes/')) continue;
      final data = Uint8List.fromList(entry.content as List<int>);
      List<Uint8List> records;
      try { records = PbReader.readLengthPrefixedRecords(data); } catch(_) { continue; }
      for (final rec in records) {
        findStrings(rec, target, entry.name);
      }
    }
  } else {
    // directory-based
    final notesDir = Directory('$path/notes');
    for (final file in notesDir.listSync().whereType<File>()) {
      final data = file.readAsBytesSync();
      List<Uint8List> records;
      try { records = PbReader.readLengthPrefixedRecords(data); } catch(_) { continue; }
      for (final rec in records) {
        findStrings(rec, target, file.path.split('/').last);
      }
    }
  }
}
