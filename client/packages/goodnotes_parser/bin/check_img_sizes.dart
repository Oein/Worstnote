import 'dart:typed_data';
import 'dart:io';
import 'package:goodnotes_parser/goodnotes_parser.dart';
import 'package:goodnotes_parser/src/model.dart';

Future<void> main(List<String> args) async {
  final doc = await GoodNotesDocument.openDirectory(args[0]);
  for (var pi = 0; pi < doc.pages.length; pi++) {
    for (final el in doc.pages[pi].elements) {
      if (el is! ImageElement) continue;
      final att = doc.attachments[el.attachmentId];
      if (att == null || !att.isPng || att.bytes.length < 24) continue;
      final bd = ByteData.sublistView(att.bytes);
      final pw = bd.getUint32(16, Endian.big).toDouble();
      final ph = bd.getUint32(20, Endian.big).toDouble();
      final bboxW = el.bbox!.maxX - el.bbox!.minX;
      final bboxH = el.bbox!.maxY - el.bbox!.minY;
      final pngAspect = pw / ph;
      final bboxAspect = bboxW / bboxH;
      final sizeAspect = el.bbox!.maxX / el.bbox!.maxY; // if #2=size
      print('Page ${pi+1}: bbox=${el.bbox!.minX.toStringAsFixed(1)},${el.bbox!.minY.toStringAsFixed(1)} → ${el.bbox!.maxX.toStringAsFixed(1)},${el.bbox!.maxY.toStringAsFixed(1)}');
      print('  PNG=${pw.toInt()}x${ph.toInt()} aspect=$pngAspect');
      print('  bbox_wh=${bboxW.toStringAsFixed(1)}x${bboxH.toStringAsFixed(1)} aspect=${bboxAspect.toStringAsFixed(3)}');
      print('  if_size_wh=${el.bbox!.maxX.toStringAsFixed(1)}x${el.bbox!.maxY.toStringAsFixed(1)} aspect=${sizeAspect.toStringAsFixed(3)}');
    }
  }
}
