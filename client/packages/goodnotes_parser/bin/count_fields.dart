// Count repeated occurrences of specific fields in element body
import 'dart:typed_data';
import 'dart:io';
import 'package:goodnotes_parser/src/protobuf.dart';

Future<void> main(List<String> args) async {
  final dir = args[0];
  final targetLamport = int.parse(args[1]);
  final notesDir = Directory('$dir/notes');
  for (final file in notesDir.listSync().whereType<File>()) {
    final data = file.readAsBytesSync();
    List<Uint8List> records;
    try { records = PbReader.readLengthPrefixedRecords(data); } catch (_) { continue; }
    String? uuid;
    for (final rec in records) {
      List<PbField> fields;
      try { fields = PbReader(rec).readAll(); } catch (_) { continue; }
      final lamport = fields.where((f) => f.number == 9 && f.wireType == PbWireType.varint).firstOrNull?.asInt;
      if (lamport != targetLamport) continue;
      uuid = fields.where((f) => f.number == 1 && f.wireType == PbWireType.lengthDelim).firstOrNull?.asString;
      break;
    }
    if (uuid == null) continue;
    for (final rec in records) {
      List<PbField> outerFields;
      try { outerFields = PbReader(rec).readAll(); } catch (_) { continue; }
      for (final of in outerFields) {
        if (of.wireType != PbWireType.lengthDelim) continue;
        try {
          final inner = of.asMessage.grouped();
          final uField = inner[1]?.first;
          if (uField == null || uField.wireType != PbWireType.lengthDelim) continue;
          if (uField.asString != uuid) continue;
          // Read ALL fields including repeated ones
          final allFields = PbReader(of.asBytes).readAll();
          final fieldCounts = <int, int>{};
          for (final f in allFields) {
            fieldCounts[f.number] = (fieldCounts[f.number] ?? 0) + 1;
          }
          print('Field counts: $fieldCounts');
          // Show all #20 instances
          final f20s = allFields.where((f) => f.number == 20).toList();
          for (var i = 0; i < f20s.length; i++) {
            final bytes = f20s[i].asBytes;
            try {
              final m = PbReader(bytes).grouped();
              final pt = m[1]?.first;
              if (pt != null) {
                final pm = PbReader(pt.asBytes).grouped();
                final x = pm[1]?.first.asFloat32;
                final y = pm[2]?.first.asFloat32;
                print('  body[20][$i]: x=$x y=$y');
              }
            } catch(_) {}
          }
          return;
        } catch (_) {}
      }
    }
  }
  print('Not found');
}
