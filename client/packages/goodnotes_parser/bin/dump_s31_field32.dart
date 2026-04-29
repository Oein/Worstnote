import 'dart:io';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/bv41.dart';
import 'dart:typed_data';

Future<void> main(List<String> args) async {
  final path = args[0];
  final tmpDir = Directory.systemTemp.createTempSync('s31f32_');
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
        
        // Check field[2] full content
        final f2full = inner[2]?.first;
        if (f2full != null) {
          final b2 = f2full.asBytes;
          print('field[2] total bytes: ${b2.length}');
          // Find all bv41 markers within field[2]
          for (var i = 0; i < b2.length - 4; i++) {
            if (b2[i]==0x62&&b2[i+1]==0x76&&b2[i+2]==0x34&&b2[i+3]==0x31) {
              print('  bv41 at pos $i in field[2]');
            }
          }
          // Print full hex
          print('  hex: ${b2.map((x) => x.toRadixString(16).padLeft(2,'0')).join('')}');
        }
        
        // Check field[9] in more detail - look at ALL sub-fields
        final f9 = inner[9]?.first;
        if (f9 != null) {
          print('field[9] bytes: ${f9.asBytes.length} hex: ${f9.asBytes.map((x) => x.toRadixString(16).padLeft(2,'0')).join('')}');
          // Try to find bv41 within f9
          final b9 = f9.asBytes;
          for (var i = 0; i + 4 <= b9.length; i++) {
            if (b9[i]==0x62&&b9[i+1]==0x76&&b9[i+2]==0x34&&b9[i+3]==0x31) {
              print('  bv41 at pos $i in field[9]');
            }
          }
        }
        
        // Check ALL body bytes for bv41 markers
        final allBv41 = <int>[];
        for (var i = 0; i + 4 <= bytes.length; i++) {
          if (bytes[i]==0x62&&bytes[i+1]==0x76&&bytes[i+2]==0x34&&bytes[i+3]==0x31) {
            allBv41.add(i);
          }
        }
        print('All bv41 positions in body: $allBv41');
        print('Body length: ${bytes.length}');
        
        found++;
        if (found >= 1) { tmpDir.deleteSync(recursive: true); return; }
      }
    }
  }
  tmpDir.deleteSync(recursive: true);
}
