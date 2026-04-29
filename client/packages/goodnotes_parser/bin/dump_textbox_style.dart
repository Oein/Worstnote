import 'dart:io';
import 'dart:typed_data';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/bv41.dart';

void main(List<String> args) {
  final data = File(args[0]).readAsBytesSync();
  final records = PbReader.readLengthPrefixedRecords(data);
  int count = 0;
  for (final rec in records) {
    List<PbField> fields;
    try { fields = PbReader(rec).readAll(); } catch (_) { continue; }
    for (final f in fields) {
      if (f.wireType != PbWireType.lengthDelim) continue;
      try {
        final inner = f.asMessage.grouped();
        final innerOne = inner[1]?.first;
        if (innerOne == null || innerOne.wireType != PbWireType.lengthDelim) continue;
        if (innerOne.asBytes.length != 36) continue;
        final body = PbReader(f.asBytes).grouped();
        final b2 = body[2]?.first;
        if (b2 == null || b2.wireType != PbWireType.varint || b2.asInt != 31) continue;
        // Only look at text boxes (have bv41)
        final bodyBytes = f.asBytes;
        String text = '';
        for (var i = 0; i + 4 <= bodyBytes.length; i++) {
          if (bodyBytes[i] == 0x62 && bodyBytes[i+1] == 0x76 && bodyBytes[i+2] == 0x34 && bodyBytes[i+3] == 0x31) {
            try {
              final inflated = Bv41.decode(bodyBytes, i);
              if (inflated.isNotEmpty && inflated[0] == 0x0a) {
                final outer = PbReader(inflated).grouped();
                for (final p in outer[1] ?? []) {
                  if (p.wireType != PbWireType.lengthDelim) continue;
                  final m = p.asMessage.grouped();
                  text += m[1]?.first.asString ?? '';
                }
              }
            } catch (_) {}
            break;
          }
        }
        if (text.isEmpty) continue;
        if (count++ >= 5) return; // show first 5 text boxes with style
        
        print('=== "$text" ===');
        // Dump body[30], body[31], body[33]
        for (final fn in [30, 31, 33]) {
          final bf = body[fn]?.first;
          if (bf == null) continue;
          print('body[$fn]: ${bf.asBytes.length} bytes: ${bf.asBytes.map((b)=>b.toRadixString(16).padLeft(2,'0')).join(' ')}');
          try {
            final m = bf.asMessage.grouped();
            for (final kv in m.entries) {
              for (final sv in kv.value) {
                if (sv.wireType == PbWireType.varint) print('  [$fn][${kv.key}] = varint(${sv.asInt})');
                else if (sv.wireType == PbWireType.fixed32) print('  [$fn][${kv.key}] = f32(${sv.asFloat32})');
                else {
                  print('  [$fn][${kv.key}] = bytes(${sv.asBytes.length}): ${sv.asBytes.sublist(0,sv.asBytes.length>12?12:sv.asBytes.length).map((b)=>b.toRadixString(16).padLeft(2,'0')).join(' ')}');
                  if (sv.wireType == PbWireType.lengthDelim) {
                    try {
                      final sub = sv.asMessage.grouped();
                      for (final skv in sub.entries) {
                        for (final ssv in skv.value) {
                          if (ssv.wireType == PbWireType.fixed32) print('    [$fn][${kv.key}][${skv.key}] = f32(${ssv.asFloat32})');
                          else if (ssv.wireType == PbWireType.varint) print('    [$fn][${kv.key}][${skv.key}] = ${ssv.asInt}');
                        }
                      }
                    } catch(_) {}
                  }
                }
              }
            }
          } catch(_) {}
        }
      } catch (_) {}
    }
  }
}
