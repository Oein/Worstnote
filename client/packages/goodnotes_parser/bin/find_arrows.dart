import 'dart:io';
import 'dart:typed_data';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/bv41.dart';

Future<void> main(List<String> args) async {
  final data = File(args[0]).readAsBytesSync();
  final records = PbReader.readLengthPrefixedRecords(data);
  
  for (final rec in records) {
    List<PbField> outerFields;
    try { outerFields = PbReader(rec).readAll(); } catch (_) { continue; }
    for (final of in outerFields) {
      if (of.wireType != PbWireType.lengthDelim) continue;
      try {
        final inner = PbReader(of.asBytes).readAll();
        final grouped = <int, List<PbField>>{};
        for (final f in inner) {
          grouped.putIfAbsent(f.number, () => []).add(f);
        }
        
        // Check for body[32]
        if (grouped.containsKey(32)) {
          final lam = grouped[9]?.first.asInt ?? grouped[9]?.first.asInt;
          // Get lamport from f9 (varint)
          int? lamport;
          for (final f in inner) {
            if (f.number == 9 && f.wireType == PbWireType.varint) {
              lamport = f.asInt; break;
            }
          }
          final opField = grouped[2]?.first;
          int opType = 0;
          if (opField != null && opField.wireType == PbWireType.lengthDelim) {
            try {
              opType = opField.asMessage.grouped()[1]?.first.asInt ?? 0;
            } catch(_) {}
          } else if (opField != null && opField.wireType == PbWireType.varint) {
            // maybe bv41 - skip
          }
          print('lam=$lamport opType=$opType has body[32]');
          
          // Decode body[32]
          final f32 = grouped[32]!.first;
          if (f32.wireType == PbWireType.lengthDelim) {
            try {
              final m = f32.asMessage.grouped();
              print('  body[32] subfields: ${m.keys.toList()..sort()}');
              for (final k in (m.keys.toList()..sort())) {
                final sv = m[k]!.first;
                if (sv.wireType == PbWireType.varint) {
                  print('  body[32][$k] = ${sv.asInt}');
                } else if (sv.wireType == PbWireType.lengthDelim) {
                  try {
                    final m2 = sv.asMessage.grouped();
                    print('  body[32][$k] → ${m2.keys.toList()..sort()}');
                    for (final k2 in (m2.keys.toList()..sort())) {
                      final sv2 = m2[k2]!.first;
                      if (sv2.wireType == PbWireType.varint) {
                        print('    body[32][$k][$k2] = ${sv2.asInt}');
                      } else if (sv2.wireType == PbWireType.fixed32) {
                        print('    body[32][$k][$k2] = ${sv2.asFloat32}');
                      }
                    }
                  } catch(_) {}
                }
              }
            } catch(_) {}
          }
        }
      } catch (_) { continue; }
    }
  }
}
