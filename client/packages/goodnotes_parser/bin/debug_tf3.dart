import 'dart:io';
import 'dart:typed_data';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/bv41.dart';
import 'package:goodnotes_parser/src/tpl.dart';
import 'package:archive/archive.dart';

void main() {
  final bytes = File('/Users/oein/Downloads/notes/TF3.goodnotes').readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(bytes);
  for (final f in archive.files) {
    if (!f.isFile || !f.name.startsWith('notes/')) continue;
    final content = f.content as Uint8List;
    if (content.isEmpty) continue;
    for (final rec in PbReader.readLengthPrefixedRecords(content)) {
      try {
        final msg = PbReader(rec).grouped();
        for (final entry in msg.entries) {
          for (final field in entry.value) {
            if (field.wireType != PbWireType.lengthDelim) continue;
            final b = field.asBytes;
            int connSegs = 0;
            for (var i = 0; i < b.length - 4; i++) {
              if (b[i]==0x62 && b[i+1]==0x76 && b[i+2]==0x34 && b[i+3]==0x31) {
                try {
                  final infl = Bv41.decode(b, i);
                  if (TplPayload.isContainer(infl)) {
                    final p = TplPayload.decode(infl);
                    if (p.strokeType == 2 && p.segments.isNotEmpty) { connSegs = p.segments.length; break; }
                  }
                } catch(_){}
              }
            }
            if (connSegs == 0) continue;
            final bodyMsg = PbReader(b).grouped();
            final f15 = bodyMsg[15]?.first;
            int? v1;
            if (f15 != null && f15.wireType == PbWireType.lengthDelim) {
              try { v1 = f15.asMessage.grouped()[1]?.first.asInt; } catch(_) {}
            }
            print('segs=$connSegs f15.1=$v1');
          }
        }
      } catch(_) {}
    }
  }
}
