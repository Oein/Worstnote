import 'dart:io';
import 'package:goodnotes_parser/src/protobuf.dart';

void main(List<String> args) {
  final data = File(args[0]).readAsBytesSync();
  final targetUuid = args[1];
  for (final rec in PbReader.readLengthPrefixedRecords(data)) {
    final fields = PbReader(rec).readAll();
    final f1 = fields.where((f) => f.number == 1 && f.wireType == PbWireType.lengthDelim).firstOrNull;
    if (f1 == null) continue;
    try { if (!f1.asString.startsWith(targetUuid.substring(0,8))) continue; }
    catch(_) { continue; }
    final f9 = fields.where((f) => f.number == 9).firstOrNull;
    if (f9 == null) continue; // Must be HEAD (has lamport)
    print('HEAD uuid=${f1.asString}');
    for (final f in fields) {
      if (f.number == 2 && f.wireType == PbWireType.lengthDelim) {
        final m = f.asMessage.grouped();
        print('  op=${m[1]?.first.asInt}');
      }
      if (f.number == 6 && f.wireType == PbWireType.lengthDelim) {
        try { print('  parent=${f.asString}'); } catch(_) {}
      }
      if (f.number == 7 && f.wireType == PbWireType.lengthDelim) {
        try { print('  ref=${f.asString}'); } catch(_) {}
      }
    }
  }
}
