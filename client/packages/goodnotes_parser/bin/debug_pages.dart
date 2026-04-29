import 'dart:io';
import 'package:goodnotes_parser/goodnotes_parser.dart';
import 'package:goodnotes_parser/src/model.dart';

Future<void> main(List<String> args) async {
  final dir = args.isNotEmpty ? args[0] : '/Users/oein/Downloads/notes/testfile';
  final doc = await GoodNotesDocument.openDirectory(dir);
  print('Pages: ${doc.pages.length}');
  for (var i = 0; i < doc.pages.length; i++) {
    final page = doc.pages[i];
    print('Page ${i+1}: id=${page.id} attach=${page.backgroundAttachmentId} elements=${page.elements.length}');
  }
}
