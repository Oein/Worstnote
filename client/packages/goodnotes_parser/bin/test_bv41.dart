// Try to decode bv41 inside unknown bodies and see what we get.
import 'dart:typed_data';
import 'package:goodnotes_parser/goodnotes_parser.dart';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/model.dart';
import 'package:goodnotes_parser/src/bv41.dart';
import 'package:goodnotes_parser/src/tpl.dart';

String hex(Uint8List b, [int n = 64]) {
  final sb = StringBuffer();
  for (var i = 0; i < n && i < b.length; i++) {
    sb.write(b[i].toRadixString(16).padLeft(2, '0'));
    sb.write(' ');
  }
  return sb.toString();
}

List<int> findBv41(Uint8List b) {
  final out = <int>[];
  for (var i = 0; i + 4 <= b.length; i++) {
    if (b[i] == 0x62 && b[i+1] == 0x76 && b[i+2] == 0x34 && b[i+3] == 0x31) {
      out.add(i);
    }
  }
  return out;
}

Future<void> main(List<String> args) async {
  final doc = await GoodNotesDocument.openDirectory(args[0]);
  for (final p in doc.pages) {
    for (final u in p.elements.whereType<UnknownElement>().take(2)) {
      print('\n--- op=${u.opType} body=${u.rawBody.length}B ---');
      final offs = findBv41(u.rawBody);
      print('  bv41 offsets: $offs');
      for (final off in offs) {
        try {
          final inflated = Bv41.decode(u.rawBody, off);
          print('  inflated: ${inflated.length}B  hex=${hex(inflated, 40)}');
          if (TplPayload.isContainer(inflated)) {
            try {
              final tpl = TplPayload.decode(inflated);
              print('  tpl decoded: type=${tpl.strokeType} schema="${tpl.schema}" '
                  'anchors=${tpl.anchors.length} segs=${tpl.segments.length} '
                  'width=${tpl.width}');
            } catch (e) {
              print('  tpl FAIL: $e');
              // print schema area
              print('  tpl-bytes hex (after magic+len): ${hex(Uint8List.fromList(inflated.sublist(8, inflated.length > 60 ? 60 : inflated.length)), 52)}');
            }
          } else {
            print('  not tpl. first byte=0x${inflated.first.toRadixString(16)}');
          }
        } catch (e) {
          print('  bv41 FAIL: $e');
        }
      }
    }
    break;
  }
}
