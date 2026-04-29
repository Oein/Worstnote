import 'dart:io';
import 'package:goodnotes_parser/goodnotes_parser.dart';
import 'package:goodnotes_parser/src/model.dart';
Future<void> main(List<String> args) async {
  final doc = await GoodNotesDocument.openDirectory(args[0]);
  final p = doc.pages[int.parse(args[1])];
  for (var i = 0; i < p.elements.length; i++) {
    final el = p.elements[i];
    if (el is ImageElement) print('[IMAGE $i] op=${el.opType} bbox=${el.bbox}');
  }
}
