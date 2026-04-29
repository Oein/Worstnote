import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/bv41.dart';

void main(List<String> args) {
  final data = File(args[0]).readAsBytesSync();
  final records = PbReader.readLengthPrefixedRecords(data);
  
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
        final uuid = innerOne.asString;
        final body = PbReader(f.asBytes).grouped();
        final b2 = body[2]?.first;
        if (b2 == null || b2.wireType != PbWireType.varint || b2.asInt != 31) continue;
        
        print('=== Schema-31 UUID: ${uuid.substring(0,8)} ===');
        final bodyBytes = f.asBytes;
        
        // Dump all top-level body fields
        for (final bf in PbReader(bodyBytes).readAll()) {
          if (bf.wireType == PbWireType.varint) {
            print('  body[${bf.number}] = varint(${bf.asInt})');
          } else if (bf.wireType == PbWireType.lengthDelim) {
            print('  body[${bf.number}] = bytes(${bf.asBytes.length})');
            if (bf.number == 3) {
              try {
                final sub = bf.asMessage.grouped();
                final flag = sub[1]?.first.asInt ?? -1;
                print('    -> flag = $flag');
              } catch(_) {}
            }
            if (bf.number == 32) {
              try {
                final m32 = bf.asMessage.grouped();
                for (final kv in m32.entries) {
                  for (final sv in kv.value) {
                    if (sv.wireType == PbWireType.varint) print('    body32[${kv.key}] = ${sv.asInt}');
                    else if (sv.wireType == PbWireType.fixed32) print('    body32[${kv.key}] = f32(${sv.asFloat32})');
                    else print('    body32[${kv.key}] = bytes(${sv.asBytes.length})');
                  }
                }
              } catch(_) {}
            }
          } else if (bf.wireType == PbWireType.fixed32) {
            print('  body[${bf.number}] = f32(${bf.asFloat32})');
          }
        }
        
        // Search for bv41
        for (var i = 0; i + 4 <= bodyBytes.length; i++) {
          if (bodyBytes[i] == 0x62 && bodyBytes[i+1] == 0x76 && bodyBytes[i+2] == 0x34 && bodyBytes[i+3] == 0x31) {
            print('  bv41 at offset $i');
            try {
              final inflated = Bv41.decode(bodyBytes, i);
              print('  inflated[${inflated.length}]: ${inflated.sublist(0, inflated.length>20?20:inflated.length).map((b)=>b.toRadixString(16).padLeft(2,'0')).join(' ')}');
              if (inflated.isNotEmpty && inflated[0] == 0x0a) {
                final outer = PbReader(inflated).grouped();
                for (final p in outer[1] ?? []) {
                  if (p.wireType != PbWireType.lengthDelim) continue;
                  final m = p.asMessage.grouped();
                  final text = m[1]?.first.asString ?? '';
                  print('  TEXT: "$text"');
                }
              }
            } catch(e) { print('  bv41 error: $e'); }
          }
        }
      } catch (_) {}
    }
  }
}
