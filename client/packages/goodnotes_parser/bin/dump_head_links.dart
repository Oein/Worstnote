import 'dart:io';
import 'package:goodnotes_parser/src/protobuf.dart';

void main(List<String> args) {
  final data = File(args[0]).readAsBytesSync();
  final recs = PbReader.readLengthPrefixedRecords(data);
  for (final rec in recs) {
    final fields = PbReader(rec).readAll();
    // Check if HEAD
    final f1 = fields.where((f) => f.number == 1 && f.wireType == PbWireType.lengthDelim).firstOrNull;
    if (f1 == null) continue;
    final idBytes = f1.asBytes;
    if (idBytes.length != 36) continue; // UUID is 36 chars
    
    // Get opType from field #2
    final f2 = fields.where((f) => f.number == 2 && f.wireType == PbWireType.lengthDelim).firstOrNull;
    if (f2 == null) continue;
    final m2 = f2.asMessage.grouped();
    final opType = m2[1]?.first.asInt ?? -1;
    
    // Only care about op=192
    if (opType != 192) continue;
    
    final lam = fields.where((f) => f.number == 9).firstOrNull?.asInt ?? -1;
    print('HEAD uuid=${f1.asString} op=$opType lam=$lam');
    
    // Check parent (field 6) and ref (field 7)
    for (final f in fields) {
      if (f.number == 6 && f.wireType == PbWireType.lengthDelim) {
        try { print('  parent=${f.asString}'); } catch(_) { 
          print('  parent(bytes)=${f.asBytes.take(16).map((b)=>b.toRadixString(16).padLeft(2,'0')).join(' ')}');
        }
      }
      if (f.number == 7 && f.wireType == PbWireType.lengthDelim) {
        try { print('  ref=${f.asString}'); } catch(_) {
          print('  ref(bytes)=${f.asBytes.take(16).map((b)=>b.toRadixString(16).padLeft(2,'0')).join(' ')}');
        }
      }
    }
  }
}
