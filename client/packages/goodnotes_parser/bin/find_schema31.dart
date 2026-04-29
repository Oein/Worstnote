import 'dart:io';
import 'package:goodnotes_parser/src/protobuf.dart';

Future<void> main(List<String> args) async {
  final data = File(args[0]).readAsBytesSync();
  final records = PbReader.readLengthPrefixedRecords(data);
  
  int count = 0;
  for (final rec in records) {
    try {
      final outer = PbReader(rec).readAll();
      for (final of in outer) {
        if (of.wireType != PbWireType.lengthDelim) continue;
        try {
          final inner = PbReader(of.asBytes).readAll();
          final grouped = <int, List<PbField>>{};
          for (final f in inner) { grouped.putIfAbsent(f.number, () => []).add(f); }
          
          final f2 = grouped[2]?.first;
          if (f2 != null && f2.wireType == PbWireType.varint && f2.asInt == 31) {
            int? lam;
            for (final f in inner) {
              if (f.number == 9 && f.wireType == PbWireType.varint) { lam = f.asInt; break; }
            }
            final f3 = grouped[3]?.first;
            int flag = 1;
            if (f3 != null && f3.wireType == PbWireType.lengthDelim) {
              try { flag = f3.asMessage.grouped()[1]?.first.asInt ?? 1; } catch(_) {}
            }
            
            // Check body[9] for shape type
            final f9 = grouped[9]?.first;
            int? shapeType;
            if (f9 != null && f9.wireType == PbWireType.lengthDelim) {
              try {
                final m9 = f9.asMessage.grouped();
                shapeType = m9[5]?.first.asInt;
              } catch(_) {}
            }
            print('Schema-31 lam=$lam flag=$flag shapeType=$shapeType');
            count++;
          }
        } catch(_) {}
      }
    } catch(_) {}
  }
  print('Total schema-31: $count');
}
