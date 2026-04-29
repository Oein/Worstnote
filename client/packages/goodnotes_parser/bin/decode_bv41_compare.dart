import 'dart:io';
import 'dart:typed_data';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/bv41.dart';
import 'package:goodnotes_parser/src/parsers.dart';

void dumpBv41Inner(String label, List<int> bytes) {
  print('\n--- $label ---');
  final br = PbReader(Uint8List.fromList(bytes));
  while (true) {
    final f = br.next(); if (f == null) break;
    if (f.wireType == PbWireType.varint) {
      print('  [${f.number}] varint=${f.asInt}');
    } else if (f.wireType == PbWireType.lengthDelim) {
      final bytes2 = f.asBytes;
      try {
        final s = f.asString;
        if (s.isNotEmpty) print('  [${f.number}] str(${bytes2.length})="${s.substring(0, s.length.clamp(0, 80))}"');
      } catch(_) {}
      print('  [${f.number}] len=${bytes2.length} hex=${bytes2.take(24).map((b)=>b.toRadixString(16).padLeft(2,'0')).join(' ')}');
    }
  }
}

void main(List<String> args) {
  final data = File(args[0]).readAsBytesSync();
  final page = parseNotePage(pageId: 'x', data: data);
  final idxList = args.sublist(1).map(int.parse).toList();
  
  for (final idx in idxList) {
    final el = page.elements[idx];
    print('\n==== Element[$idx] op=${el.opType} lam=${el.lamport} ====');
    // Find body
    for (final rec in PbReader.readLengthPrefixedRecords(data)) {
      for (final f in PbReader(rec).readAll()) {
        if (f.wireType != PbWireType.lengthDelim) continue;
        try {
          final inner = f.asMessage.grouped();
          final innerOne = inner[1]?.first;
          if (innerOne == null) continue;
          if (!innerOne.asString.startsWith(el.id.substring(0,8))) continue;
          final body = f.asBytes;
          // Scan bv41
          for (var i = 0; i + 4 <= body.length; i++) {
            if (body[i]==0x62&&body[i+1]==0x76&&body[i+2]==0x34&&body[i+3]==0x31) {
              try {
                final dec = Bv41.decode(body, i);
                dumpBv41Inner('bv41@$i el[$idx] op=${el.opType}', dec);
              } catch(e) {}
            }
          }
        } catch(_) {}
      }
    }
  }
}
