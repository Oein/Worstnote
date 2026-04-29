import 'dart:io';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/bv41.dart';
import 'dart:typed_data';

// Dump ALL fields of the outer LP record that wraps a schema-31 stroke
Future<void> main(List<String> args) async {
  final path = args[0];
  final tmpDir = Directory.systemTemp.createTempSync('outer_');
  Process.runSync('unzip', ['-o', path, 'notes/*', '-d', tmpDir.path]);
  
  final notesDir = Directory('${tmpDir.path}/notes');
  int found = 0;
  for (final f in notesDir.listSync().whereType<File>()) {
    final data = f.readAsBytesSync();
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
      
      // Check if this is a BODY record for a schema-31 stroke
      Map<int, List<PbField>> outer;
      try { outer = PbReader(rec).grouped(); } catch (_) { continue; }
      
      bool isS31Body = false;
      for (final f2 in outer.values.expand((x) => x)) {
        if (f2.wireType != PbWireType.lengthDelim) continue;
        final bytes = f2.asBytes;
        for (var i = 0; i + 12 <= bytes.length; i++) {
          if (bytes[i]==0x62&&bytes[i+1]==0x76&&bytes[i+2]==0x34&&bytes[i+3]==0x31) {
            try {
              final dec = Bv41.decode(bytes, i);
              if (dec.length > 8) {
                var k = 8;
                const allowed = 'vufiSAd()';
                while(k < dec.length && allowed.contains(String.fromCharCode(dec[k]))) k++;
                if (String.fromCharCodes(dec.sublist(8, k)).startsWith('vA(v)A(u)A(u)')) {
                  isS31Body = true; break;
                }
              }
            } catch(_) {}
          }
          if (isS31Body) break;
        }
        if (isS31Body) break;
      }
      
      if (!isS31Body) continue;
      
      // Dump ALL outer fields
      print('=== OUTER LP RECORD for schema-31 body (total=${rec.length} bytes) ===');
      final outerKeys = outer.keys.toList()..sort();
      print('Outer field numbers: $outerKeys');
      for (final fn in outerKeys) {
        for (final f2 in outer[fn]!) {
          if (f2.wireType == PbWireType.varint) {
            print('  [$fn] varint=${f2.asInt}');
          } else if (f2.wireType == PbWireType.fixed32) {
            print('  [$fn] f32=${f2.asFloat32}');
          } else if (f2.wireType == PbWireType.lengthDelim) {
            final b = f2.asBytes;
            print('  [$fn] len=${b.length} hex=${b.take(20).map((x) => x.toRadixString(16).padLeft(2,'0')).join('')}');
          }
        }
      }
      
      found++;
      if (found >= 1) { tmpDir.deleteSync(recursive: true); return; }
    }
  }
  tmpDir.deleteSync(recursive: true);
}
