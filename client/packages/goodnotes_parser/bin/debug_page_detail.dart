import 'dart:io';
import 'dart:typed_data';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/bv41.dart';
import 'package:goodnotes_parser/src/parsers.dart';
import 'package:goodnotes_parser/src/model.dart';

Future<void> main(List<String> args) async {
  final notesFile = File(args[0]);
  final data = notesFile.readAsBytesSync();
  final page = parseNotePage(pageId: 'debug', data: data);
  print('Elements: ${page.elements.length}');
  for (var i = 0; i < page.elements.length; i++) {
    final el = page.elements[i];
    final t = el.runtimeType;
    final op = el.opType;
    final lam = el.lamport;
    final bb = el.bbox;
    final bbStr = bb != null ? 'bbox=(${bb.minX.toStringAsFixed(0)},${bb.minY.toStringAsFixed(0)} ${bb.width.toStringAsFixed(0)}x${bb.height.toStringAsFixed(0)})' : 'bbox=null';
    if (el is TextElement) {
      print('[$i] TEXT op=$op lam=$lam $bbStr text="${el.text.replaceAll("\n","\\n")}"');
    } else if (el is StrokeElement) {
      final pts = (el.payload?.anchors.length ?? 0) + (el.payload?.segments.length ?? 0);
      final schema = el.payload?.schema ?? '?';
      print('[$i] STROKE op=$op lam=$lam $bbStr pts=$pts schema=$schema');
    } else if (el is ImageElement) {
      print('[$i] IMAGE op=$op lam=$lam $bbStr attach=${el.attachmentId.substring(0,8)}');
    } else if (el is UnknownElement) {
      print('[$i] UNKNOWN op=$op lam=$lam $bbStr rawlen=${el.rawBody.length}');
    }
  }
}
