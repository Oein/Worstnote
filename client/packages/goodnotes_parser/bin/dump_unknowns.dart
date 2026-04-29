import 'dart:io';
import 'dart:typed_data';
import 'package:goodnotes_parser/goodnotes_parser.dart';
import 'package:goodnotes_parser/src/model.dart';
import 'package:goodnotes_parser/src/protobuf.dart';

Future<void> main(List<String> args) async {
  final path = args[0];
  final pageIdx = args.length > 1 ? int.parse(args[1]) : 0;
  final doc = path.endsWith('.goodnotes')
      ? await GoodNotesDocument.openFile(path)
      : await GoodNotesDocument.openDirectory(path);
  final p = doc.pages[pageIdx];
  for (var i = 0; i < p.elements.length; i++) {
    final el = p.elements[i];
    if (el is UnknownElement) {
      print('UnknownElement[$i] op=${el.opType} lam=${el.lamport} bodyLen=${el.rawBody.length}');
      if (el.rawBody.length > 0) {
        try {
          final fields = PbReader(el.rawBody).readAll();
          for (final f in fields) {
            if (f.wireType == PbWireType.varint) print('  [${f.number}] v=${f.asInt}');
            else if (f.wireType == PbWireType.lengthDelim) {
              final bs = f.asBytes;
              String s = '';
              try { s = f.asString; } catch(_) {}
              print('  [${f.number}] len=${bs.length} hex=${bs.take(12).map((b)=>b.toRadixString(16).padLeft(2,"0")).join(" ")} str="${s.substring(0, s.length.clamp(0, 40))}"');
            }
          }
        } catch(e) { print('  parse error: $e'); }
      }
    }
  }
}
