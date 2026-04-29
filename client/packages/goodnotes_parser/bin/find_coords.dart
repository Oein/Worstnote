// Scan all float32 values in a body for potential coordinates
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
          final bodyBytes = of.asBytes;
          print('Scanning all bytes for coordinate-range floats (10..1600):');
          final bd = ByteData.sublistView(bodyBytes);
          for (var i = 0; i + 4 <= bodyBytes.length; i++) {
            final v = bd.getFloat32(i, Endian.little);
            if (v.isFinite && v >= 10.0 && v <= 1600.0) {
              print('  offset=$i f32=$v');
            }
          }
          return;
        } catch (_) {}
      }
    }
  }
  print('Not found');
}
