// Sample elements with specific opType
import 'dart:typed_data';
import 'dart:io';
import 'package:goodnotes_parser/goodnotes_parser.dart';
import 'package:goodnotes_parser/src/model.dart';
import 'package:goodnotes_parser/src/protobuf.dart';

Future<void> main(List<String> args) async {
  final dir = args[0];
  final targetOpType = int.parse(args[1]);
  final notesDir = Directory('$dir/notes');
  for (final file in notesDir.listSync().whereType<File>()) {
    final data = file.readAsBytesSync();
    List<Uint8List> records;
    try { records = PbReader.readLengthPrefixedRecords(data); } catch (_) { continue; }
    var count = 0;
    for (final rec in records) {
      List<PbField> fields;
      try { fields = PbReader(rec).readAll(); } catch (_) { continue; }
      final has1 = fields.any((f) => f.number == 1 && f.wireType == PbWireType.lengthDelim);
      final has9 = fields.any((f) => f.number == 9 && f.wireType == PbWireType.varint);
      if (!has1 || !has9) continue;
      final opTypeField = fields.where((f) => f.number == 2 && f.wireType == PbWireType.lengthDelim).firstOrNull;
      if (opTypeField == null) continue;
      final m = opTypeField.asMessage.grouped();
      final opType = m[1]?.first.asInt ?? -1;
      if (opType != targetOpType) continue;
      final id = fields.where((f) => f.number == 1 && f.wireType == PbWireType.lengthDelim).firstOrNull?.asString;
      final l = fields.where((f) => f.number == 9 && f.wireType == PbWireType.varint).firstOrNull?.asInt;
      print('  id=$id lamport=$l');
      if (++count >= 5) break;
    }
    if (count > 0) break;
  }
}
