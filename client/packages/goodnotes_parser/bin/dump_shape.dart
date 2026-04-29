import 'dart:io';
import 'dart:typed_data';

import 'package:goodnotes_parser/goodnotes_parser.dart';
import 'package:goodnotes_parser/src/bv41.dart';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/model.dart';

Iterable<int> _findAllBv41(Uint8List data) sync* {
  for (var i = 0; i + 4 <= data.length; i++) {
    if (data[i] == 0x62 && data[i + 1] == 0x76 &&
        data[i + 2] == 0x34 && data[i + 3] == 0x31) yield i;
  }
}

Future<void> main(List<String> args) async {
  final src = args[0];
  final pageIdx = int.parse(args[1]);
  final stat = FileStat.statSync(src);
  final doc = stat.type == FileSystemEntityType.directory
      ? await GoodNotesDocument.openDirectory(src)
      : await GoodNotesDocument.openFile(src);
  final page = doc.pages[pageIdx];

  // We need access to raw body bytes by uuid. Re-open via openFile gives only
  // parsed elements. Re-iterate via UnknownElement raw + StrokeElement bbox.
  // The dump is best-effort: we re-look at the StrokeElement.payload schema.
  for (final el in page.elements) {
    if (el is StrokeElement) {
      final schema = el.payload?.schema;
      if (schema != 'synthetic') continue;
      final pts = el.points.length;
      final bx = el.bbox;
      final pos = bx == null ? '?' : '(${bx.minX.toStringAsFixed(0)},${bx.minY.toStringAsFixed(0)} ${bx.width.toStringAsFixed(0)}x${bx.height.toStringAsFixed(0)})';
      print('STK op=${el.opType} L${el.lamport} $pos pts=$pts w=${el.width.toStringAsFixed(1)} strokeType=${el.payload?.strokeType}');
      // Print first/last point
      final first = el.points.first;
      final last = el.points.last;
      print('  start=(${first.x.toStringAsFixed(1)},${first.y.toStringAsFixed(1)}) end=(${last.x.toStringAsFixed(1)},${last.y.toStringAsFixed(1)})');
    }
  }
}
