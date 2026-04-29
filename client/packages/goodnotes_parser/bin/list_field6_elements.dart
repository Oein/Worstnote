// List elements that have body field #6 (possible callout indicator)
import 'dart:typed_data';
import 'dart:io';
import 'package:goodnotes_parser/goodnotes_parser.dart';
import 'package:goodnotes_parser/src/model.dart';
import 'package:goodnotes_parser/src/protobuf.dart';

Future<void> main(List<String> args) async {
  final dir = args[0];
  final doc = await GoodNotesDocument.openDirectory(dir);
  final notesDir = Directory('$dir/notes');
  // Build lamport→element type map
  final elemByUuid = <String, String>{};
  for (final page in doc.pages) {
    for (final el in page.elements) {
      if (el is TextElement) elemByUuid[el.id] = 'TEXT "${el.text.replaceAll("\n","\\n").substring(0, el.text.length.clamp(0,20))}"';
      else if (el is StrokeElement) elemByUuid[el.id] = 'STROKE';
      else elemByUuid[el.id] = 'UNKNOWN/${el.runtimeType}';
    }
  }
  for (final file in notesDir.listSync().whereType<File>()) {
    final data = file.readAsBytesSync();
    List<Uint8List> records;
    try { records = PbReader.readLengthPrefixedRecords(data); } catch (_) { continue; }
    for (final rec in records) {
      List<PbField> outerFields;
      try { outerFields = PbReader(rec).readAll(); } catch (_) { continue; }
      for (final of in outerFields) {
        if (of.wireType != PbWireType.lengthDelim) continue;
        try {
          final allFields = PbReader(of.asBytes).readAll();
          final hasField6 = allFields.any((f) => f.number == 6);
          if (!hasField6) continue;
          final inner = of.asMessage.grouped();
          final uField = inner[1]?.first;
          if (uField == null || uField.wireType != PbWireType.lengthDelim) continue;
          final id = uField.asString;
          print('${elemByUuid[id] ?? "?"} id=$id');
        } catch (_) {}
      }
    }
  }
}
