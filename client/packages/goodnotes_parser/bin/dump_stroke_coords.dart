/// Dump coordinate ranges of all strokes with pts > 0 in a page.
import 'dart:io';
import 'package:goodnotes_parser/goodnotes_parser.dart';
import 'package:goodnotes_parser/src/model.dart';

Future<void> main(List<String> args) async {
  final src = args[0];
  final pageIdx = int.parse(args[1]);
  final stat = FileStat.statSync(src);
  final doc = stat.type == FileSystemEntityType.directory
      ? await GoodNotesDocument.openDirectory(src)
      : await GoodNotesDocument.openFile(src);
  final page = doc.pages[pageIdx];

  for (final el in page.elements) {
    if (el is! StrokeElement) continue;
    if (el.points.isEmpty) continue;
    final pts = el.points;
    final xs = pts.map((p) => p.x);
    final ys = pts.map((p) => p.y);
    final minX = xs.reduce((a, b) => a < b ? a : b);
    final maxX = xs.reduce((a, b) => a > b ? a : b);
    final minY = ys.reduce((a, b) => a < b ? a : b);
    final maxY = ys.reduce((a, b) => a > b ? a : b);
    final c = el.color;
    print('L${el.lamport} op=${el.opType} pts=${pts.length} '
          'x=${minX.toStringAsFixed(0)}..${maxX.toStringAsFixed(0)} '
          'y=${minY.toStringAsFixed(0)}..${maxY.toStringAsFixed(0)} '
          'color=(${c.r.toStringAsFixed(2)},${c.g.toStringAsFixed(2)},${c.b.toStringAsFixed(2)}) '
          'schema=${el.payload?.schema}');
  }
}
