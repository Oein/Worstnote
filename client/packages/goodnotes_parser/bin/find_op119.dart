import 'dart:typed_data';
import 'dart:io';
import 'package:goodnotes_parser/src/protobuf.dart';

void main() {
  final dir = "/Users/oein/Downloads/notes/Copy of Copy of 8. 고려의 성립(학생용).pdf";
  final notesDir = Directory('$dir/notes');
  for (final file in notesDir.listSync().whereType<File>()) {
    final data = file.readAsBytesSync();
    List<Uint8List> records;
    try { records = PbReader.readLengthPrefixedRecords(data); } catch (_) { continue; }
    for (final rec in records) {
      List<PbField> fields;
      try { fields = PbReader(rec).readAll(); } catch (_) { continue; }
      final id = fields.where((f) => f.number == 1 && f.wireType == PbWireType.lengthDelim).firstOrNull?.asString;
      final opTypeField = fields.where((f) => f.number == 2 && f.wireType == PbWireType.lengthDelim).firstOrNull;
      if (opTypeField == null) continue;
      final m = opTypeField.asMessage.grouped();
      final opType = m[1]?.first.asInt ?? -1;
      if (opType == 119) {
        print('Found opType 119: id=$id');
        final bodyField = fields.where((f) => f.number == 3 && f.wireType == PbWireType.lengthDelim).firstOrNull;
        if (bodyField != null) {
          print('Body len=${bodyField.asBytes.length}');
          final bodyFields = PbReader(bodyField.asBytes).readAll();
          for (final bf in bodyFields) {
            if (bf.wireType == PbWireType.varint) print('  [${bf.number}] v=${bf.asInt}');
            else if (bf.wireType == PbWireType.lengthDelim) {
              final bs = bf.asBytes;
              String str = '';
              try { str = bf.asString; } catch(_) {}
              print('  [${bf.number}] len=${bs.length} str="${str.substring(0, str.length.clamp(0,60))}" hex=${bs.take(16).map((b)=>b.toRadixString(16).padLeft(2,"0")).join(" ")}');
            }
          }
        }
      }
    }
  }
}
