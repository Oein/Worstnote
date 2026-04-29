import 'dart:io';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/bv41.dart';
import 'dart:typed_data';

// Dump outer LP record for a WORKING stroke (body[20] has coords)
Future<void> main(List<String> args) async {
  final path = args[0];
  final tmpDir = Directory.systemTemp.createTempSync('owork_');
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
      
      // Find a body record that has body[20] with actual point data
      for (final f2 in outer.values.expand((x) => x)) {
        if (f2.wireType != PbWireType.lengthDelim) continue;
        Map<int, List<PbField>> inner;
        try { inner = f2.asMessage.grouped(); } catch (_) { continue; }
        
        // Check for UUID
        final uuid = inner[1]?.first;
        if (uuid == null || uuid.wireType != PbWireType.lengthDelim || uuid.asBytes.length != 36) continue;
        
        // Check for body[20] with non-trivial content
        final f20 = inner[20]?.first;
        if (f20 == null || f20.wireType != PbWireType.lengthDelim) continue;
        if (f20.asBytes.length < 10) continue;  // need substantial data
        
        // Found a working body! Dump outer record
        print('=== OUTER LP RECORD for working body ===');
        print('Total=${rec.length} bytes, outer fields=${outer.keys.toList()..sort()}');
        for (final fn in (outer.keys.toList()..sort())) {
          for (final f3 in outer[fn]!) {
            if (f3.wireType == PbWireType.varint) {
              print('  [$fn] varint=${f3.asInt}');
            } else if (f3.wireType == PbWireType.lengthDelim) {
              final b = f3.asBytes;
              print('  [$fn] len=${b.length} hex=${b.take(20).map((x) => x.toRadixString(16).padLeft(2,'0')).join('')}');
            }
          }
        }
        
        // Also dump the body inner fields
        print('  Inner body fields: ${inner.keys.toList()..sort()}');
        final b20 = f20.asBytes;
        print('  body[20] len=${b20.length} hex=${b20.take(30).map((x) => x.toRadixString(16).padLeft(2,'0')).join('')}');
        
        found++;
        if (found >= 2) { tmpDir.deleteSync(recursive: true); return; }
        break;
      }
    }
  }
  tmpDir.deleteSync(recursive: true);
}
