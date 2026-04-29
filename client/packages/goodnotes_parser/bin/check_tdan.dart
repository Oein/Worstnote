import 'package:goodnotes_parser/goodnotes_parser.dart';
import 'package:goodnotes_parser/src/model.dart';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'dart:typed_data';
import 'dart:io';

Future<void> main() async {
  // Find UUIDs for 땐 elements and check their opTypes
  final doc = await GoodNotesDocument.openFile('/Users/oein/Downloads/notes/TF1.goodnotes');
  final p = doc.pages[0];
  final targetLamports = {10418, 10295};
  for (final el in p.elements) {
    if (el is TextElement && targetLamports.contains(el.lamport)) {
      print('ID=${el.id} op=${el.opType} lam=${el.lamport} text="${el.text}" fillColor=${el.fillColor}');
    }
  }
}
