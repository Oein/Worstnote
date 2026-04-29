// Show HEAD record for elements by lamport
import 'dart:typed_data';
import 'dart:io';
import 'package:goodnotes_parser/src/protobuf.dart';

Future<void> main(List<String> args) async {
  final dir = args[0];
  final lamports = args.skip(1).map(int.parse).toList();
  final notesDir = Directory('$dir/notes');
  for (final file in notesDir.listSync().whereType<File>()) {
    final data = file.readAsBytesSync();
    List<Uint8List> records;
    try { records = PbReader.readLengthPrefixedRecords(data); } catch (_) { continue; }
    for (final rec in records) {
      List<PbField> fields;
      try { fields = PbReader(rec).readAll(); } catch (_) { continue; }
      final l = fields.where((f) => f.number == 9 && f.wireType == PbWireType.varint).firstOrNull?.asInt;
      if (l == null || !lamports.contains(l)) continue;
      final id = fields.where((f) => f.number == 1 && f.wireType == PbWireType.lengthDelim).firstOrNull?.asString;
      final opTypeField = fields.where((f) => f.number == 2 && f.wireType == PbWireType.lengthDelim).firstOrNull;
      int? opType, hash;
      if (opTypeField != null) {
        final m = opTypeField.asMessage.grouped();
        opType = m[1]?.first.asInt;
        hash = m[2]?.first.asInt;
      }
      final ref = fields.where((f) => f.number == 7 && f.wireType == PbWireType.lengthDelim).firstOrNull?.asString;
      final schema = fields.where((f) => f.number == 16 && f.wireType == PbWireType.varint).firstOrNull?.asInt;
      print('lamport=$l id=$id opType=$opType hash=$hash ref=$ref schema=$schema');
    }
  }
}
