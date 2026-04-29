// Dump unknown element bodies, with hex preview when not protobuf.
import 'dart:typed_data';
import 'package:goodnotes_parser/goodnotes_parser.dart';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/model.dart';

String hex(Uint8List b, [int n = 64]) {
  final sb = StringBuffer();
  for (var i = 0; i < n && i < b.length; i++) {
    sb.write(b[i].toRadixString(16).padLeft(2, '0'));
    sb.write(' ');
  }
  return sb.toString();
}

void dumpFields(Uint8List bytes, {int depth = 0, int max = 8}) {
  if (depth > max) return;
  List<PbField> fields;
  try {
    fields = PbReader(bytes).readAll();
  } catch (e) {
    print('${'  ' * depth}<not-proto len=${bytes.length}: ${hex(bytes, 32)}>');
    return;
  }
  final pad = '  ' * depth;
  for (final f in fields) {
    if (f.wireType == PbWireType.varint) {
      print('$pad#${f.number} v=${f.asInt}');
    } else if (f.wireType == PbWireType.fixed32) {
      print('$pad#${f.number} f32=${f.asFloat32}');
    } else if (f.wireType == PbWireType.lengthDelim) {
      final b = f.asBytes;
      print('$pad#${f.number} bytes[${b.length}] hex=${hex(b, 12)}');
      dumpFields(b, depth: depth + 1, max: max);
    } else {
      print('$pad#${f.number}');
    }
  }
}

Future<void> main(List<String> args) async {
  final doc = args[0].endsWith('.goodnotes')
      ? await GoodNotesDocument.openFile(args[0])
      : await GoodNotesDocument.openDirectory(args[0]);
  for (var pi = 0; pi < doc.pages.length; pi++) {
    final p = doc.pages[pi];
    final unknowns = p.elements.whereType<UnknownElement>().toList();
    if (unknowns.isEmpty) continue;
    print('\n=== Page ${pi + 1} — ${unknowns.length} unknowns ===');
    final byOp = <int, List<UnknownElement>>{};
    for (final u in unknowns) {
      byOp.putIfAbsent(u.opType, () => []).add(u);
    }
    for (final entry in byOp.entries) {
      print('\n  op=${entry.key}: ${entry.value.length} elements');
      final u = entry.value.first;
      print('  hex0: ${hex(u.rawBody, 32)}');
      dumpFields(u.rawBody, depth: 1);
    }
    if (pi > 1) break;
  }
}
