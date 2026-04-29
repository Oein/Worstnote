// Debug: dump text elements and unknown elements from a page directory.
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
  print('=== Page ${pageIdx + 1} — ${p.elements.length} elements ===');

  for (var i = 0; i < p.elements.length; i++) {
    final el = p.elements[i];
    if (el is TextElement) {
      print('\n[TEXT $i] lamport=${el.lamport} bbox=${el.bbox} '
          'fontSize=${el.fontSize.toStringAsFixed(1)} '
          'text="${el.text.replaceAll('\n', '\\n')}"');
    } else if (el is UnknownElement) {
      print('\n[UNKNOWN $i] op=${el.opType} lamport=${el.lamport} '
          'bbox=${el.bbox} rawLen=${el.rawBody.length}');
      _dumpFields(el.rawBody, depth: 1, max: 3);
    } else if (el is StrokeElement) {
      final pts = el.payload?.flatPoints().length ?? 0;
      print('[STROKE $i] op=${el.opType} bbox=${el.bbox} '
          'color=${_colorStr(el.color)} w=${el.width.toStringAsFixed(2)} '
          'pts=$pts schema=${el.payload?.schema}');
    }
  }
}

String _colorStr(dynamic c) {
  if (c == null) return 'null';
  return 'rgba(${(c.r*255).round()},${(c.g*255).round()},${(c.b*255).round()},${c.a.toStringAsFixed(2)})';
}

void _dumpFields(Uint8List bytes, {int depth = 0, int max = 3}) {
  if (depth > max) return;
  List<dynamic> fields;
  try {
    fields = PbReader(bytes).readAll();
  } catch (e) {
    print('${'  ' * depth}<parse-error>');
    return;
  }
  final pad = '  ' * depth;
  for (final f in fields) {
    if (f.wireType == PbWireType.varint) {
      print('$pad#${f.number} v=${f.asInt}');
    } else if (f.wireType == PbWireType.fixed32) {
      print('$pad#${f.number} f32=${f.asFloat32}');
    } else if (f.wireType == PbWireType.lengthDelim) {
      final b = f.asBytes as Uint8List;
      print('$pad#${f.number} bytes[${b.length}]');
      _dumpFields(b, depth: depth + 1, max: max);
    }
  }
}
