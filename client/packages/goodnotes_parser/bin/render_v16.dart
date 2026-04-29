import 'dart:io';
import 'package:goodnotes_parser/goodnotes_parser.dart';
import 'package:goodnotes_parser/src/svg_renderer.dart';

Future<void> main(List<String> args) async {
  final srcDir = args[0];
  final outDir = args[1];
  Directory(outDir).createSync(recursive: true);
  
  final srcStat = FileStat.statSync(srcDir);
  final doc = srcStat.type == FileSystemEntityType.directory
      ? await GoodNotesDocument.openDirectory(srcDir)
      : await GoodNotesDocument.openFile(srcDir);
  final renderer = SvgRenderer();
  // Track how many times each PDF attachment has been used so we can
  // pass the correct 1-based page number within that attachment file.
  final attachPageCount = <String, int>{};
  for (var i = 0; i < doc.pages.length; i++) {
    final page = doc.pages[i];
    final attachId = page.backgroundAttachmentId ?? '';
    if (attachId.isNotEmpty) {
      attachPageCount[attachId] = (attachPageCount[attachId] ?? 0) + 1;
    }
    final pdfPage = attachPageCount[attachId] ?? 1;
    final svg = renderer.render(page, doc, pageNumberInPdf: pdfPage);
    File('$outDir/page_${(i+1).toString().padLeft(2,'0')}.svg').writeAsStringSync(svg);
    print('Rendered page ${i+1} (attach=$attachId pdfPage=$pdfPage)');
  }
}
