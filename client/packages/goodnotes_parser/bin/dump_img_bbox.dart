import 'dart:typed_data';
import 'dart:io';
import 'package:goodnotes_parser/goodnotes_parser.dart';
import 'package:goodnotes_parser/src/model.dart';
import 'package:goodnotes_parser/src/protobuf.dart';

Future<void> main(List<String> args) async {
  final doc = await GoodNotesDocument.openDirectory(args[0]);
  final pageIdx = int.parse(args[1]);
  final page = doc.pages[pageIdx];
  for (var i = 0; i < page.elements.length; i++) {
    final el = page.elements[i];
    if (el is! ImageElement) continue;
    final att = doc.attachments[el.attachmentId];
    print('[IMAGE $i] bbox=${el.bbox}');
    if (att != null && att.isPng && att.bytes.length > 24) {
      final bd = ByteData.sublistView(att.bytes);
      final pw = bd.getUint32(16, Endian.big);
      final ph = bd.getUint32(20, Endian.big);
      print('  PNG dimensions: ${pw}x${ph}');
    }
    // Dump body[2] raw
    final notesDir = Directory('${args[0]}/notes');
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
            final inner = of.asMessage.grouped();
            final uField = inner[1]?.first;
            if (uField == null || uField.wireType != PbWireType.lengthDelim) continue;
            if (uField.asString != el.id) continue;
            final body = of.asMessage.grouped();
            final f2 = body[2]?.first;
            if (f2 != null && f2.wireType == PbWireType.lengthDelim) {
              print('  body[2] hex: ${f2.asBytes.map((b)=>b.toRadixString(16).padLeft(2,"0")).join(" ")}');
              final m = f2.asMessage.grouped();
              for (final entry in m.entries) {
                final pts = entry.value;
                for (final pt in pts) {
                  if (pt.wireType == PbWireType.lengthDelim) {
                    final pm = pt.asMessage.grouped();
                    print('    #${entry.key} → x=${pm[1]?.first.asFloat32} y=${pm[2]?.first.asFloat32}');
                  }
                }
              }
            }
          } catch (_) {}
        }
      }
    }
  }
}
