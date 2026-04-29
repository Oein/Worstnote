import 'dart:io';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/bv41.dart';
import 'dart:typed_data';

// Scan all LP records and for schema-31 bodies, dump ALL field numbers and their content
Future<void> main(List<String> args) async {
  final path = args[0];
  final tmpDir = Directory.systemTemp.createTempSync('baf_');
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
      
      Map<int, List<PbField>> outer;
      try { outer = PbReader(rec).grouped(); } catch (_) { continue; }
      
      for (final f2 in outer.values.expand((x) => x)) {
        if (f2.wireType != PbWireType.lengthDelim) continue;
        bool isS31 = false;
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
                  isS31 = true; break;
                }
              }
            } catch(_) {}
          }
        }
        if (!isS31) continue;
        
        Map<int, List<PbField>> inner;
        try { inner = f2.asMessage.grouped(); } catch (_) { continue; }
        
        final keys = inner.keys.toList()..sort();
        print('BODY fields=${keys}');
        for (final fn in keys) {
          final v = inner[fn]!.first;
          if (v.wireType == PbWireType.varint) {
            print('  [$fn] varint=${v.asInt}');
          } else if (v.wireType == PbWireType.fixed32) {
            print('  [$fn] f32=${v.asFloat32}');
          } else if (v.wireType == PbWireType.lengthDelim) {
            final b = v.asBytes;
            final hex = b.take(32).map((x) => x.toRadixString(16).padLeft(2,'0')).join('');
            print('  [$fn] len=${b.length} hex=$hex');
          }
        }
        
        if (found++ >= 0) return;  // just first one
      }
    }
  }
  tmpDir.deleteSync(recursive: true);
}
