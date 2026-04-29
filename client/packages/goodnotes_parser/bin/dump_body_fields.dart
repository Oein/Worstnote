import 'dart:io';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/bv41.dart';
import 'package:goodnotes_parser/src/parsers.dart';

void main(List<String> args) {
  final data = File(args[0]).readAsBytesSync();
  final page = parseNotePage(pageId: 'x', data: data);
  // Find the element at index given by args[1]
  final idx = int.parse(args[1]);
  final el = page.elements[idx];
  print('id=${el.id}  op=${el.opType}  lam=${el.lamport}  bbox=${el.bbox}');

  // Reparse raw bytes from the notes file to find this element's body
  final recs = PbReader.readLengthPrefixedRecords(data);
  for (final rec in recs) {
    for (final f in PbReader(rec).readAll()) {
      if (f.wireType != PbWireType.lengthDelim) continue;
      try {
        final inner = f.asMessage.grouped();
        final innerOne = inner[1]?.first;
        if (innerOne == null) continue;
        if (!innerOne.asString.startsWith(el.id.substring(0,8))) continue;
        final body = f.asBytes;
        print('body len=${body.length}');
        // Print outer fields
        final br = PbReader(body);
        while (true) {
          final bf = br.next(); if (bf == null) break;
          if (bf.wireType == PbWireType.varint) {
            print('  [${bf.number}] varint=${bf.asInt}');
          } else if (bf.wireType == PbWireType.fixed32) {
            print('  [${bf.number}] fixed32');
          } else if (bf.wireType == PbWireType.lengthDelim) {
            final bs = bf.asBytes;
            // Try string
            try {
              final s = bf.asString;
              if (s.length > 0 && s.length < 200) print('  [${bf.number}] str="$s"');
            } catch(_) {}
            print('  [${bf.number}] len=${bs.length} hex=${bs.take(16).map((b)=>b.toRadixString(16).padLeft(2,'0')).join(' ')}');
          }
        }
        // Scan for bv41
        for (var i = 0; i + 4 <= body.length; i++) {
          if (body[i]==0x62&&body[i+1]==0x76&&body[i+2]==0x34&&body[i+3]==0x31) {
            try {
              final dec = Bv41.decode(body, i);
              print('  bv41@$i len=${dec.length} hex=${dec.take(32).map((b)=>b.toRadixString(16).padLeft(2,'0')).join(' ')}');
            } catch(e) { print('  bv41@$i err=$e'); }
          }
        }
      } catch(_) {}
    }
  }
}
