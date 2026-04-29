import 'dart:io';
import 'package:goodnotes_parser/goodnotes_parser.dart';
import 'package:goodnotes_parser/src/model.dart';

Future<void> main(List<String> args) async {
  final dir = args.isNotEmpty ? args[0] : '/Users/oein/Downloads/notes/testfile';
  final doc = await GoodNotesDocument.openDirectory(dir);
  for (var i = 0; i < doc.pages.length; i++) {
    final page = doc.pages[i];
    print('Page ${i+1}: ${page.elements.length} elements');
    for (final el in page.elements) {
      if (el is StrokeElement) print('  STROKE pts=${el.payload?.anchors.length ?? 0}');
      else if (el is TextElement) print('  TEXT "${el.text.replaceAll("\n","\\n")}"');
      else if (el is ImageElement) print('  IMAGE attach=${el.attachmentId}');
      else print('  OTHER ${el.runtimeType}');
    }
  }
}
