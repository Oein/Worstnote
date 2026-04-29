import 'dart:io';
import 'package:goodnotes_parser/goodnotes_parser.dart';
import 'package:goodnotes_parser/src/model.dart';

Future<void> main(List<String> args) async {
  final src = args[0];
  final pageIdx = int.parse(args[1]);
  final xMin = double.parse(args[2]);
  final yMin = double.parse(args[3]);
  final xMax = double.parse(args[4]);
  final yMax = double.parse(args[5]);
  final stat = FileStat.statSync(src);
  final doc = stat.type == FileSystemEntityType.directory
      ? await GoodNotesDocument.openDirectory(src)
      : await GoodNotesDocument.openFile(src);
  final page = doc.pages[pageIdx];
  for (final el in page.elements) {
    final bx = el.bbox;
    if (bx != null) {
      if (bx.maxX < xMin || bx.minX > xMax) continue;
      if (bx.maxY < yMin || bx.minY > yMax) continue;
    }
    final pos = bx == null ? '?' : '(${bx.minX.toStringAsFixed(0)},${bx.minY.toStringAsFixed(0)} ${bx.width.toStringAsFixed(0)}x${bx.height.toStringAsFixed(0)})';
    final type = el.runtimeType.toString();
    var extra = '';
    if (el is TextElement) extra = ' "${el.text.length > 30 ? el.text.substring(0, 30) + "..." : el.text}"';
    if (el is StrokeElement) extra = ' pts=${el.points.length} schema=${el.payload?.schema}';
    if (el is UnknownElement) extra = ' rawLen=${el.rawBody.length}';
    print('  $type op=${el.opType} L${el.lamport} $pos$extra');
  }
}
