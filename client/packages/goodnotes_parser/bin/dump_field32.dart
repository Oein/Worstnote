// Dump body[32].#1 raw bytes for a text element
import 'dart:typed_data';
import 'dart:io';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/bv41.dart';

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
          final body = of.asMessage.grouped();
          // Dump all float values from #20 group (searching for more points)
          print('body[20] raw bytes:');
          final f20 = body[20]?.first;
          if (f20 != null) {
            final b = f20.asBytes;
            print('  hex: ${b.map((x) => x.toRadixString(16).padLeft(2,"0")).join(" ")}');
            // Try to read all fields, including extras
            try {
              final all = PbReader(b).readAll();
              for (final f in all) {
                if (f.wireType == PbWireType.fixed32) print('  #${f.number} f32=${f.asFloat32}');
                else if (f.wireType == PbWireType.varint) print('  #${f.number} varint=${f.asInt}');
                else if (f.wireType == PbWireType.lengthDelim) {
                  final sb = f.asBytes;
                  print('  #${f.number} bytes[${sb.length}]');
                  try {
                    final all2 = PbReader(sb).readAll();
                    for (final f2 in all2) {
                      if (f2.wireType == PbWireType.fixed32) print('    #${f2.number} f32=${f2.asFloat32}');
                      else if (f2.wireType == PbWireType.varint) print('    #${f2.number} varint=${f2.asInt}');
                      else if (f2.wireType == PbWireType.lengthDelim) {
                        print('    #${f2.number} bytes[${f2.asBytes.length}]');
                        final all3 = PbReader(f2.asBytes).readAll();
                        for (final f3 in all3) {
                          if (f3.wireType == PbWireType.fixed32) print('      #${f3.number} f32=${f3.asFloat32}');
                          else if (f3.wireType == PbWireType.varint) print('      #${f3.number} varint=${f3.asInt}');
                        }
                      }
                    }
                  } catch(_) {}
                }
              }
            } catch (e) { print('  error: $e'); }
          }
          // Also dump body[33] if present
          final f33 = body[33]?.first;
          if (f33 != null) {
            print('\nbody[33] raw bytes:');
            final b = f33.asBytes;
            print('  hex: ${b.map((x) => x.toRadixString(16).padLeft(2,"0")).join(" ")}');
            try {
              final all = PbReader(b).readAll();
              for (final f in all) {
                if (f.wireType == PbWireType.fixed32) print('  #${f.number} f32=${f.asFloat32}');
                else if (f.wireType == PbWireType.lengthDelim) {
                  final sb = f.asBytes;
                  print('  #${f.number} bytes[${sb.length}]');
                  try {
                    final all2 = PbReader(sb).readAll();
                    for (final f2 in all2) {
                      if (f2.wireType == PbWireType.fixed32) print('    #${f2.number} f32=${f2.asFloat32}');
                      else if (f2.wireType == PbWireType.varint) print('    #${f2.number} varint=${f2.asInt}');
                    }
                  } catch(_) {}
                }
              }
            } catch (e) { print('  error: $e'); }
          }
          // Also dump body[32].#1 raw bytes (NSCoding data)
          final f32 = body[32]?.first;
          if (f32 != null) {
            final m32 = f32.asMessage.grouped();
            final sub1 = m32[1]?.first;
            if (sub1 != null) {
              print('\nbody[32].#1 raw bytes[${sub1.asBytes.length}]:');
              final b = sub1.asBytes;
              // scan for float32 values
              print('  All f32 values at aligned offsets:');
              final bd = ByteData.sublistView(b);
              for (var i = 0; i + 4 <= b.length; i += 4) {
                final v = bd.getFloat32(i, Endian.little);
                if (v.isFinite && v.abs() < 2000 && v.abs() > 0.01) {
                  print('    offset=$i  f32=$v');
                }
              }
            }
          }
          return;
        } catch (_) {}
      }
    }
  }
  print('Not found');
}
