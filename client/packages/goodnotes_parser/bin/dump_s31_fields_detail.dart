import 'dart:io';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/bv41.dart';
import 'dart:typed_data';

Future<void> main(List<String> args) async {
  final path = args[0];
  final tmpDir = Directory.systemTemp.createTempSync('s31d_');
  Process.runSync('unzip', ['-o', path, 'notes/*', '-d', tmpDir.path]);
  
  final notesDir = Directory('${tmpDir.path}/notes');
  for (final f in notesDir.listSync().whereType<File>()) {
    final data = f.readAsBytesSync();
    _analyze(data);
  }
  tmpDir.deleteSync(recursive: true);
}

void _analyze(Uint8List data) {
  // Read LP records
  int pos = 0;
  while (pos < data.length - 4) {
    var len = 0; var shift = 0;
    while (pos < data.length) {
      final b = data[pos++]; len |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) break; shift += 7;
    }
    if (len <= 0 || pos + len > data.length) break;
    final rec = Uint8List.sublistView(data, pos, pos + len);
    pos += len;
    
    Map<int, List<PbField>> outer;
    try { outer = PbReader(rec).grouped(); } catch (_) { continue; }
    
    for (final f in outer.values.expand((x) => x)) {
      if (f.wireType != PbWireType.lengthDelim) continue;
      Map<int, List<PbField>> inner;
      try { inner = f.asMessage.grouped(); } catch (_) { continue; }
      
      // Check for schema-31 bv41
      bool isSchema31 = false;
      for (var i = 0; i + 12 <= f.asBytes.length; i++) {
        final b = f.asBytes;
        if (b[i]==0x62&&b[i+1]==0x76&&b[i+2]==0x34&&b[i+3]==0x31) {
          try {
            final dec = Bv41.decode(b, i);
            if (dec.length > 8) {
              var k = 8;
              const allowed = 'vufiSAd()';
              while(k < dec.length && allowed.contains(String.fromCharCode(dec[k]))) k++;
              final schema = String.fromCharCodes(dec.sublist(8, k));
              if (schema.startsWith('vA(v)A(u)A(u)')) { isSchema31 = true; break; }
            }
          } catch(_) {}
        }
      }
      if (!isSchema31) continue;
      
      // Dump field[6], field[7], field[9], field[14] in detail
      print('--- schema31 body ---');
      for (final fn in [3, 4, 6, 7, 9, 14, 15, 20, 21]) {
        final v = inner[fn]?.first;
        if (v == null) continue;
        if (v.wireType == PbWireType.varint) {
          print('  [$fn] varint=${v.asInt}');
        } else if (v.wireType == PbWireType.lengthDelim) {
          final bytes = v.asBytes;
          print('  [$fn] len=${bytes.length} hex=${bytes.take(20).map((x) => x.toRadixString(16).padLeft(2,'0')).join('')}');
          // If bytes looks like UUID (36 bytes, dashes at 8,13,18,23)
          if (bytes.length == 36 && bytes[8] == 0x2d) {
            print('    UUID: ${String.fromCharCodes(bytes)}');
          }
          // Try to parse as sub-message
          try {
            final sm = v.asMessage.grouped();
            print('    sub-fields: ${sm.keys.toList()..sort()}');
          } catch(_) {}
        } else if (v.wireType == PbWireType.fixed32) {
          print('  [$fn] f32=${v.asFloat32}');
        }
      }
      return; // just first one
    }
  }
}
// Already defined above - this is just a note
