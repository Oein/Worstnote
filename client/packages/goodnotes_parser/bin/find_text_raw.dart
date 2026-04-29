import 'dart:typed_data';
import 'dart:io';
import 'dart:convert';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/bv41.dart';

void findStrings(Uint8List bytes, String target, String ctx, {int depth = 0}) {
  if (depth > 6) return;
  try {
    final fields = PbReader(bytes).readAll();
    for (final f in fields) {
      if (f.wireType == PbWireType.lengthDelim) {
        final bs = f.asBytes;
        try {
          final s = const Utf8Codec(allowMalformed: true).decode(bs);
          if (s.contains(target)) print('$ctx [${f.number}] "$s"');
        } catch (_) {}
        findStrings(bs, target, '$ctx.[${f.number}]', depth: depth + 1);
        // Try bv41
        for (var i = 0; i + 4 <= bs.length; i++) {
          if (bs[i]==0x62&&bs[i+1]==0x76&&bs[i+2]==0x34&&bs[i+3]==0x31) {
            try {
              final dec = Bv41.decode(bs, i);
              findStrings(Uint8List.fromList(dec), target, '$ctx.[${f.number}]@bv41', depth: depth + 1);
            } catch(_) {}
          }
        }
      }
    }
  } catch (_) {}
}

void main() {
  final dir = "/Users/oein/Downloads/notes/Copy of Copy of 8. 고려의 성립(학생용).pdf";
  final notesDir = Directory('$dir/notes');
  for (final file in notesDir.listSync().whereType<File>()) {
    final data = file.readAsBytesSync();
    List<Uint8List> records;
    try { records = PbReader.readLengthPrefixedRecords(data); } catch (_) { continue; }
    for (final rec in records) {
      final id = PbReader(rec).readAll()
          .where((f) => f.number == 1 && f.wireType == PbWireType.lengthDelim)
          .firstOrNull?.asString ?? '?';
      findStrings(rec, '수도', 'rec[$id]');
    }
  }
}
