import 'dart:io';
import 'package:goodnotes_parser/src/protobuf.dart';

void main(List<String> args) {
  final data = File(args[0]).readAsBytesSync();
  final target = args[1];
  final recs = PbReader.readLengthPrefixedRecords(data);
  for (var i = 0; i < recs.length; i++) {
    final rec = recs[i];
    try {
      final fields = PbReader(rec).readAll();
      // Check if this record is HEAD or BODY for target
      final f1 = fields.where((f) => f.number == 1 && f.wireType == PbWireType.lengthDelim).firstOrNull;
      if (f1 != null) {
        try {
          if (f1.asString.startsWith(target.substring(0, 8))) {
            print('Record $i len=${rec.length} UUID=${f1.asString}');
            for (final f in fields) {
              if (f.wireType == PbWireType.varint) print('  [${f.number}] varint=${f.asInt}');
              else if (f.wireType == PbWireType.lengthDelim) {
                try { final s = f.asString; if (s.length > 1 && s.length < 200) print('  [${f.number}] str="$s"'); }
                catch(_) { print('  [${f.number}] len=${f.asBytes.length}'); }
              }
            }
          }
        } catch(_) {}
      }
      // Also check if target UUID appears in sub-message field 1
      for (final f in fields) {
        if (f.wireType != PbWireType.lengthDelim) continue;
        try {
          final inner = f.asMessage.grouped();
          final innerOne = inner[1]?.first;
          if (innerOne != null && innerOne.asString.startsWith(target.substring(0, 8))) {
            print('Record $i (BODY wrapper) for ${innerOne.asString}');
            // Print outer body inner fields
            final body = f.asBytes;
            final br = PbReader(body);
            while(true) {
              final bf = br.next(); if (bf == null) break;
              if (bf.wireType == PbWireType.varint) print('  body[${bf.number}] varint=${bf.asInt}');
              else if (bf.wireType == PbWireType.lengthDelim) {
                try { final s = bf.asString; if (s.length > 1 && s.length < 100) print('  body[${bf.number}] str="$s"'); }
                catch(_) { print('  body[${bf.number}] len=${bf.asBytes.length}'); }
              }
            }
          }
        } catch(_) {}
      }
    } catch(_) {}
  }
}
