import 'dart:io';
import 'package:goodnotes_parser/goodnotes_parser.dart';
import 'package:goodnotes_parser/src/model.dart';

Future<void> main(List<String> args) async {
  final src = args[0];
  final pageIdx = int.parse(args[1]);
  final filter = args.length > 2 ? args[2] : '';

  final stat = FileStat.statSync(src);
  final doc = stat.type == FileSystemEntityType.directory
      ? await GoodNotesDocument.openDirectory(src)
      : await GoodNotesDocument.openFile(src);
  final page = doc.pages[pageIdx];
  print('Page $pageIdx: ${page.elements.length} elements');
  for (final el in page.elements) {
    if (el is TextElement) {
      final bx = el.bbox;
      final pos = bx == null ? '?' : '(${bx.minX.toStringAsFixed(0)},${bx.minY.toStringAsFixed(0)} ${bx.width.toStringAsFixed(0)}x${bx.height.toStringAsFixed(0)})';
      final txt = el.text.length > 40 ? el.text.substring(0, 40) + '…' : el.text;
      final fill = el.fillColor == null ? '' : ' fill=${el.fillColor}';
      if (filter.isEmpty || el.text.contains(filter)) {
        print('  TXT op=${el.opType} L${el.lamport} $pos size=${el.fontSize.toStringAsFixed(1)} "$txt"$fill');
      }
    } else if (el is StrokeElement) {
      final bx = el.bbox;
      final pos = bx == null ? '?' : '(${bx.minX.toStringAsFixed(0)},${bx.minY.toStringAsFixed(0)} ${bx.width.toStringAsFixed(0)}x${bx.height.toStringAsFixed(0)})';
      final pts = el.points.length;
      if (filter.isEmpty || filter == 'stroke') {
        print('  STK op=${el.opType} L${el.lamport} $pos pts=$pts w=${el.width.toStringAsFixed(1)} arrow=${el.arrowEnd} schema=${el.payload?.schema}');
      }
    }
  }
}
