// Dump raw text element content for debugging.
import 'dart:typed_data';
import 'dart:convert';
import 'package:goodnotes_parser/goodnotes_parser.dart';
import 'package:goodnotes_parser/src/model.dart';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/bv41.dart';

Future<void> main(List<String> args) async {
  final path = args[0];
  final pageIdx = args.length > 1 ? int.parse(args[1]) : 0;
  final doc = path.endsWith('.goodnotes')
      ? await GoodNotesDocument.openFile(path)
      : await GoodNotesDocument.openDirectory(path);

  final p = doc.pages[pageIdx];
  print('Page ${pageIdx + 1}: ${p.elements.length} elements');

  for (var i = 0; i < p.elements.length; i++) {
    final el = p.elements[i];
    if (el is TextElement) {
      print('\n=== TextElement[$i] lamport=${el.lamport} '
          'text="${el.text.replaceAll('\n', '\\n')}" '
          'size=${el.fontSize.toStringAsFixed(1)} bbox=${el.bbox} ===');
    }
  }
}
