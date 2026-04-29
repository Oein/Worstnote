// Dump all top-level protobuf fields from a text element's body
import 'dart:typed_data';
import 'dart:io';
import 'package:goodnotes_parser/src/protobuf.dart';

void dumpFields(Uint8List b, {String prefix = '', int maxDepth = 4, int depth = 0}) {
  if (depth > maxDepth) { print('${prefix}...'); return; }
  List<PbField> fields;
  try { fields = PbReader(b).readAll(); } catch (e) { print('${prefix}<error: $e>'); return; }
  for (final f in fields) {
    if (f.wireType == PbWireType.varint) {
      print('$prefix#${f.number} varint=${f.asInt}');
    } else if (f.wireType == PbWireType.fixed32) {
      print('$prefix#${f.number} f32=${f.asFloat32}');
    } else if (f.wireType == PbWireType.lengthDelim) {
      final bytes = f.asBytes;
      print('$prefix#${f.number} bytes[${bytes.length}]');
      if (depth < maxDepth) dumpFields(bytes, prefix: '$prefix  ', maxDepth: maxDepth, depth: depth+1);
    }
  }
}

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
          print('=== OUTER BODY fields for lamport=$targetLamport ===');
          // Print the inner body (strip the outer wrapper)
          dumpFields(of.asBytes, maxDepth: 5);
          return;
        } catch (_) {}
      }
    }
  }
  print('Not found');
}
