// Count orphan opType=3 elements (opType=3 only, no prior create)
import 'dart:typed_data';
import 'dart:io';
import 'package:goodnotes_parser/src/protobuf.dart';

bool _looksLikeUuid(Uint8List b) {
  if (b.length != 36) return false;
  return b[8] == 0x2d && b[13] == 0x2d && b[18] == 0x2d && b[23] == 0x2d;
}

Future<void> main(List<String> args) async {
  final dir = args[0];
  final notesDir = Directory('$dir/notes');
  final allOps = <String, Set<int>>{};
  for (final file in notesDir.listSync().whereType<File>()) {
    final data = file.readAsBytesSync();
    List<Uint8List> records;
    try { records = PbReader.readLengthPrefixedRecords(data); } catch (_) { continue; }
    for (final rec in records) {
      List<PbField> fields;
      try { fields = PbReader(rec).readAll(); } catch (_) { continue; }
      final idF = fields.where((f) => f.number == 1 && f.wireType == PbWireType.lengthDelim).firstOrNull;
      if (idF == null || !_looksLikeUuid(idF.asBytes)) continue;
      final opF = fields.where((f) => f.number == 2 && f.wireType == PbWireType.lengthDelim).firstOrNull;
      if (opF == null) continue;
      final m = opF.asMessage.grouped();
      final opType = m[1]?.first.asInt ?? -1;
      final id = idF.asString;
      allOps[id] = (allOps[id] ?? {})..add(opType);
    }
  }
  final orphans = allOps.entries.where((e) => e.value.every((op) => op == 3)).toList();
  print('Total UUIDs: ${allOps.length}');
  print('Orphan opType=3-only: ${orphans.length}');
  for (final o in orphans) {
    print('  ${o.key} opTypes=${o.value}');
  }
}
