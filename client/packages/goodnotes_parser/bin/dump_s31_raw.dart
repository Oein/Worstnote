import 'dart:io';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/bv41.dart';
import 'dart:typed_data';

// Read the notes file directly and find schema-31 bodies
Future<void> main(List<String> args) async {
  final path = args[0];
  
  // Read zip
  final bytes = File(path).readAsBytesSync();
  // We need to use Dart's archive or just use the document API
  // Let's use the document API to find the raw notes path
  
  // Actually let's just use the zip via Archive
  // For now, let's instrument the parser by modifying it temporarily
  // Instead: scan raw bytes of each notes file via zip
  
  // Use the Archive package if available, else use unzip
  final tmpDir = Directory.systemTemp.createTempSync('s31_');
  final result = Process.runSync('unzip', ['-o', path, 'notes/*', '-d', tmpDir.path]);
  
  final notesDir = Directory('${tmpDir.path}/notes');
  for (final f in notesDir.listSync().whereType<File>()) {
    print('=== ${f.path.split('/').last} ===');
    final data = f.readAsBytesSync();
    _analyzeBody(data);
  }
  
  tmpDir.deleteSync(recursive: true);
}

void _analyzeBody(Uint8List data) {
  // Read LP records
  int pos = 0;
  int count = 0;
  while (pos < data.length - 4) {
    final startPos = pos;
    var len = 0;
    var shift = 0;
    while (pos < data.length) {
      final b = data[pos++];
      len |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) break;
      shift += 7;
    }
    if (len <= 0 || pos + len > data.length) break;
    final rec = Uint8List.sublistView(data, pos, pos + len);
    pos += len;
    
    _analyzeRecord(rec);
    if (count++ > 500) break;
  }
}

void _analyzeRecord(Uint8List rec) {
  Map<int, List<PbField>> outer;
  try { outer = PbReader(rec).grouped(); } catch (_) { return; }
  
  // Body records have a length-delimited field that wraps the element
  for (final f in outer.values.expand((x) => x)) {
    if (f.wireType != PbWireType.lengthDelim) continue;
    Map<int, List<PbField>> inner;
    try { inner = f.asMessage.grouped(); } catch (_) { continue; }
    
    // Check if this body has a bv41 with schema-31
    bool isSchema31 = false;
    final innerBytes = f.asBytes;
    for (var i = 0; i + 12 <= innerBytes.length; i++) {
      if (innerBytes[i] == 0x62 && innerBytes[i+1] == 0x76 &&
          innerBytes[i+2] == 0x34 && innerBytes[i+3] == 0x31) {
        try {
          final dec = Bv41.decode(innerBytes, i);
          if (dec.length > 8) {
            var k = 8;
            const allowed = 'vufiSAd()';
            while (k < dec.length && allowed.contains(String.fromCharCode(dec[k]))) k++;
            final schema = String.fromCharCodes(dec.sublist(8, k));
            if (schema.startsWith('vA(v)A(u)A(u)')) {
              isSchema31 = true;
              break;
            }
          }
        } catch (_) {}
      }
    }
    
    if (isSchema31) {
      // Dump ALL field numbers in this inner body
      final fields = inner.keys.toList()..sort();
      print('  schema31 body fields: $fields');
      
      // Check specific fields of interest
      for (final fn in [9, 20, 21, 32, 33, 40, 41, 42, 43, 44, 45, 50, 60, 70]) {
        final v = inner[fn]?.first;
        if (v != null) {
          print('    field[$fn] wireType=${v.wireType} bytes=${v.wireType == PbWireType.lengthDelim ? v.asBytes.length : "n/a"}');
        }
      }
      return; // one per run
    }
  }
}
