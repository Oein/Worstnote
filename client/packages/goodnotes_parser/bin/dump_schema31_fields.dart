import 'dart:io';
import 'package:goodnotes_parser/goodnotes_parser.dart';
import 'package:goodnotes_parser/src/model.dart';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/bv41.dart';
import 'dart:typed_data';

Future<void> main(List<String> args) async {
  final src = args[0];
  final pageIdx = int.parse(args[1]);
  final stat = FileStat.statSync(src);
  final doc = stat.type == FileSystemEntityType.directory
      ? await GoodNotesDocument.openDirectory(src)
      : await GoodNotesDocument.openFile(src);
  final page = doc.pages[pageIdx];
  
  int count = 0;
  for (final el in page.elements) {
    if (el is! StrokeElement) continue;
    if (el.points.isNotEmpty) continue;
    if (el.payload?.schema == null) continue;
    final schema = el.payload!.schema!;
    if (!schema.startsWith('vA(')) continue;
    
    // This is a schema-31 stub. We can't access raw body from here.
    // Print useful info.
    print('S31 op=${el.opType} L${el.lamport} bbox=${el.bbox} color=${el.color.r.toStringAsFixed(2)},${el.color.g.toStringAsFixed(2)},${el.color.b.toStringAsFixed(2)}');
    if (count++ > 5) break;
  }
}
