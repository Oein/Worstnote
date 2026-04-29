import 'package:goodnotes_parser/src/protobuf.dart';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';

bool _looksLikeUuid(Uint8List b) {
  if (b.length != 36) return false;
  return b[8] == 0x2d && b[13] == 0x2d && b[18] == 0x2d && b[23] == 0x2d;
}

Future<void> main() async {
  // Target UUIDs (full)
  const targets = {
    '75EA7C4C-DF66-4042-9022-F8C934EA26C1': '땐(op3)',
    'A603A6CC-D710-40DF-B85D-A378FB665969': '땐(op5)',
    '7C8D1AB5-CB63-4C6C-BA96-98CDD617D1A4': '채집(op3)',
    '3B1A2D87-8F25-4D3B-B9B8-AFDB424B05A4': '무리(op3)',
  };
  
  for (final file in Directory('/tmp/tf1_extracted/notes').listSync().whereType<File>()) {
    final data = file.readAsBytesSync();
    List<Uint8List> records;
    try { records = PbReader.readLengthPrefixedRecords(data); } catch (_) { continue; }
    
    int recordIdx = 0;
    for (final rec in records) {
      recordIdx++;
      List<PbField> fields;
      try { fields = PbReader(rec).readAll(); } catch (_) { continue; }
      
      for (final f in fields) {
        if (f.number != 1 || f.wireType != PbWireType.lengthDelim) continue;
        if (!_looksLikeUuid(f.asBytes)) continue;
        
        final uuid = f.asString;
        if (!targets.containsKey(uuid)) continue;
        
        final label = targets[uuid]!;
        final lamport = fields.where((x) => x.number == 9 && x.wireType == PbWireType.varint).firstOrNull?.asInt;
        final has2 = fields.any((x) => x.number == 2 && x.wireType == PbWireType.lengthDelim);
        final has9 = lamport != null;
        
        if (has2 && has9) {
          // This is a HEAD record
          final opTypeField = fields.where((x) => x.number == 2 && x.wireType == PbWireType.lengthDelim).firstOrNull;
          int? opType;
          try { opType = opTypeField!.asMessage.grouped()[1]?.first.asInt; } catch (_) {}
          final allNums = fields.map((x) => '#${x.number}(${x.wireType.name})').join(', ');
          print('HEAD[$recordIdx] $label lam=$lamport op=$opType fields=[$allNums]');
        }
        break;
      }
    }
  }
}
