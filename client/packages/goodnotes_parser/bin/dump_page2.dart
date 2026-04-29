import 'package:goodnotes_parser/goodnotes_parser.dart';
import 'package:goodnotes_parser/src/model.dart';

Future<void> main(List<String> args) async {
  final doc = await GoodNotesDocument.openDirectory(args[0]);
  final pageIdx = args.length > 1 ? int.parse(args[1]) : 1;
  final p = doc.pages[pageIdx];
  print('Page ${pageIdx+1}: ${p.elements.length} elements, bg=${p.backgroundAttachmentId}');
  for (var i = 0; i < p.elements.length; i++) {
    final el = p.elements[i];
    if (el is ImageElement) {
      print('[IMAGE $i] bbox=${el.bbox} attachId=${el.attachmentId}');
      final att = doc.attachments[el.attachmentId];
      if (att != null) print('  -> isPng=${att.isPng} isPdf=${att.isPdf} size=${att.bytes.length}');
    } else if (el is StrokeElement) {
      print('[STROKE $i] op=${el.opType} pts=${el.payload?.flatPoints().length ?? 0}');
    } else if (el is TextElement) {
      print('[TEXT $i] text="${el.text}"');
    }
  }
}
