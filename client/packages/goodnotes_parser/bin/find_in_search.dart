// Find text in search index and show glyph positions
import 'dart:typed_data';
import 'dart:io';
import 'package:goodnotes_parser/goodnotes_parser.dart';
import 'package:goodnotes_parser/src/model.dart';

Future<void> main(List<String> args) async {
  final dir = args[0];
  final needle = args[1];
  final doc = await GoodNotesDocument.openDirectory(dir);
  for (final entry in doc.searchIndices.entries) {
    for (final token in entry.value.tokens) {
      if (token.text.contains(needle)) {
        print('Found "${token.text}" in index ${entry.key}:');
        for (final run in token.glyphRuns) {
          print('  glyph run: off=${run.charOffset} cnt=${run.charCount} bbox=${run.bbox}');
        }
      }
    }
  }
}
