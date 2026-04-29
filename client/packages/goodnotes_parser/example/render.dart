// Render every page of a .goodnotes (or extracted dir) to SVG.
//
//   dart run example/render.dart input.goodnotes output_dir/

import 'dart:io';
import 'package:goodnotes_parser/goodnotes_parser.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: render.dart <input> <out_dir>');
    exit(2);
  }
  final inPath = args[0];
  final outDir = Directory(args[1])..createSync(recursive: true);

  final stat = FileStat.statSync(inPath);
  final doc = stat.type == FileSystemEntityType.directory
      ? await GoodNotesDocument.openDirectory(inPath)
      : await GoodNotesDocument.openFile(inPath);

  final renderer = const SvgRenderer();
  for (var i = 0; i < doc.pages.length; i++) {
    final svg = renderer.render(doc.pages[i], doc, pageNumberInPdf: i + 1);
    final path = '${outDir.path}/page_${(i + 1).toString().padLeft(2, '0')}.svg';
    await File(path).writeAsString(svg);
    final p = doc.pages[i];
    final strokePts = p.strokes.fold<int>(0, (a, s) => a + s.points.length);
    print('wrote $path  '
        '(${p.elements.length} elements, $strokePts stroke pts, '
        '${p.texts.length} texts)');
  }
}
