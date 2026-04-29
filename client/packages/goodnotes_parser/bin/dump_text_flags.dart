import 'dart:io';
import 'dart:typed_data';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/parsers.dart';
import 'package:goodnotes_parser/src/model.dart';
import 'package:goodnotes_parser/src/bv41.dart';

void main(List<String> args) {
  final data = File(args[0]).readAsBytesSync();
  final page = parseNotePage(pageId: 'x', data: data);
  // Build body lookup
  final bodyByUuid = <String, Uint8List>{};
  for (final rec in PbReader.readLengthPrefixedRecords(data)) {
    for (final f in PbReader(rec).readAll()) {
      if (f.wireType != PbWireType.lengthDelim) continue;
      try {
        final inner = f.asMessage.grouped();
        final innerOne = inner[1]?.first;
        if (innerOne == null) continue;
        final s = innerOne.asString;
        if (s.length == 36 && s.contains('-')) bodyByUuid[s] = f.asBytes;
      } catch(_) {}
    }
  }
  
  for (var i = 0; i < page.elements.length; i++) {
    final el = page.elements[i];
    if (el is! TextElement) continue;
    final body = bodyByUuid[el.id];
    if (body == null) continue;
    final br = PbReader(body);
    int flag = 0; int bodyField6count = 0;
    bool hasBodyField6 = false;
    while (true) {
      final f = br.next(); if (f == null) break;
      if (f.number == 3 && f.wireType == PbWireType.lengthDelim) {
        try {
          final m = f.asMessage.grouped();
          flag = m[1]?.first.asInt ?? 0;
        } catch(_) {}
      }
      if (f.number == 6 && f.wireType == PbWireType.lengthDelim) {
        hasBodyField6 = true;
      }
    }
    final txt = el.text.replaceAll('\n', '\\n');
    print('[$i] TEXT op=${el.opType} lam=${el.lamport} flag=$flag body6=$hasBodyField6 bbox=${el.bbox?.minX.round()},${el.bbox?.minY.round()} text="${txt.length>30?txt.substring(0,30):txt}"');
  }
}
