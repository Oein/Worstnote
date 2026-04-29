import 'dart:io';
import 'dart:typed_data';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/bv41.dart';

Future<void> main(List<String> args) async {
  final data = File(args[0]).readAsBytesSync();
  final targetLamport = int.parse(args[1]);
  final records = PbReader.readLengthPrefixedRecords(data);

  String? targetUuid;
  for (final rec in records) {
    try {
      final fields = PbReader(rec).readAll();
      final lam = fields.where((f) => f.number == 9 && f.wireType == PbWireType.varint).firstOrNull?.asInt;
      if (lam != targetLamport) continue;
      targetUuid = fields.where((f) => f.number == 1 && f.wireType == PbWireType.lengthDelim).firstOrNull?.asString;
      break;
    } catch (_) {}
  }
  if (targetUuid == null) { print('not found'); return; }

  for (final rec in records) {
    try {
      for (final of in PbReader(rec).readAll()) {
        if (of.wireType != PbWireType.lengthDelim) continue;
        final inner = of.asMessage.grouped();
        if (inner[1]?.first.asString != targetUuid) continue;
        final bodyBytes = of.asBytes;
        // Find bv41 magic
        for (var i = 0; i + 4 <= bodyBytes.length; i++) {
          if (bodyBytes[i]==0x62 && bodyBytes[i+1]==0x76 && bodyBytes[i+2]==0x34 && bodyBytes[i+3]==0x31) {
            final inf = Bv41.decode(bodyBytes, i);
            // Find schema
            var k = 8;
            while (k < inf.length && 'vufiSAd()'.codeUnits.contains(inf[k])) k++;
            final schema = String.fromCharCodes(inf.sublist(8, k));
            final dataStart = k + 1;
            print('Schema: $schema');
            print('Data offset: $dataStart, data length: ${inf.length - dataStart}');
            final bytes = inf.sublist(dataStart);
            print('All data bytes:');
            final bd = ByteData.sublistView(bytes);
            for (var j = 0; j < bytes.length; j += 16) {
              final end = (j + 16 < bytes.length) ? j + 16 : bytes.length;
              final hex = List.generate(end - j, (k) => bytes[j+k].toRadixString(16).padLeft(2,'0')).join(' ');
              print('  [${j.toString().padLeft(3)}] $hex');
            }
          }
        }
        return;
      }
    } catch(_) {}
  }
}
