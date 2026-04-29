import 'dart:io';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/bv41.dart';

void main(List<String> args) {
  final data = File(args[0]).readAsBytesSync();
  final recs = PbReader.readLengthPrefixedRecords(data);
  for (final rec in recs) {
    final r = PbReader(rec);
    int? op; int? lam;
    final fields = <int, List<PbField>>{};
    while (true) {
      final f = r.next(); if (f == null) break;
      fields.putIfAbsent(f.number, () => []).add(f);
      if (f.number == 4 && f.wireType == PbWireType.varint) op = f.asInt;
      if (f.number == 3 && f.wireType == PbWireType.varint) lam = f.asInt;
    }
    if (op == 192) {
      print('=== op=192 lam=$lam ===');
      // parse body
      final bodyField = fields[5]?.first;
      if (bodyField == null) { print('no body'); continue; }
      final bodyBytes = bodyField.asBytes;
      // scan for bv41
      for (var i = 0; i + 4 <= bodyBytes.length; i++) {
        if (bodyBytes[i]==0x62 && bodyBytes[i+1]==0x76 &&
            bodyBytes[i+2]==0x34 && bodyBytes[i+3]==0x31) {
          try {
            final dec = Bv41.decode(bodyBytes, i);
            print('  bv41 at $i: ${String.fromCharCodes(dec.where((c)=>c>=0x20 && c<0x7f))} (len=${dec.length})');
            // Show hex of first 32 bytes
            print('  hex: ${dec.take(32).map((b)=>b.toRadixString(16).padLeft(2,'0')).join(' ')}');
          } catch(e) { print('  bv41 err at $i: $e'); }
        }
      }
      // print body outer fields
      final br = PbReader(bodyBytes);
      while (true) {
        final f = br.next(); if (f == null) break;
        if (f.wireType == PbWireType.lengthDelim) {
          try {
            final s = f.asString;
            if (s.isNotEmpty) print('  body[${f.number}] string: "$s"');
          } catch(_) {}
        }
      }
    }
  }
}
