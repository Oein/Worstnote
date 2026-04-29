// Find ALL HEAD records for a given UUID (to detect create+update+delete)
import 'dart:typed_data';
import 'dart:io';
import 'package:goodnotes_parser/src/protobuf.dart';

Future<void> main(List<String> args) async {
  final dir = args[0];
  final targetUuid = args[1];
  final notesDir = Directory('$dir/notes');
  for (final file in notesDir.listSync().whereType<File>()) {
    final data = file.readAsBytesSync();
    List<Uint8List> records;
    try { records = PbReader.readLengthPrefixedRecords(data); } catch (_) { continue; }
    for (final rec in records) {
      List<PbField> fields;
      try { fields = PbReader(rec).readAll(); } catch (_) { continue; }
      final id = fields.where((f) => f.number == 1 && f.wireType == PbWireType.lengthDelim).firstOrNull?.asString;
      if (id != targetUuid) continue;
      final l = fields.where((f) => f.number == 9 && f.wireType == PbWireType.varint).firstOrNull?.asInt;
      final opTypeField = fields.where((f) => f.number == 2 && f.wireType == PbWireType.lengthDelim).firstOrNull;
      int? opType;
      if (opTypeField != null) {
        final m = opTypeField.asMessage.grouped();
        opType = m[1]?.first.asInt;
      }
      print('  lamport=$l opType=$opType');
    }
  }
}
