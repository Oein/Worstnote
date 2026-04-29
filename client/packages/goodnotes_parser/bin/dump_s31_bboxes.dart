/// Dump all schema-31 strokes: their UUID, opType, lamport, bbox, color,
/// and the raw decompressed bv41 content.
import 'dart:io';
import 'dart:typed_data';
import 'package:goodnotes_parser/goodnotes_parser.dart';
import 'package:goodnotes_parser/src/model.dart';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/bv41.dart';

bool _hasBv41Schema31(Uint8List data) {
  for (var i = 0; i + 12 <= data.length; i++) {
    if (data[i]==0x62 && data[i+1]==0x76 && data[i+2]==0x34 && data[i+3]==0x31) {
      try {
        final dec = Bv41.decode(data, i);
        if (dec.length > 8) {
          var k = 8;
          final allowed = 'vufiSAd()'.codeUnits.toSet();
          while (k < dec.length && allowed.contains(dec[k])) k++;
          final schema = String.fromCharCodes(dec.sublist(8, k));
          if (schema.startsWith('vA(v)A(u)A(u)')) return true;
        }
      } catch(_) {}
    }
  }
  return false;
}

Uint8List? _getDecompressedBv41(Uint8List data) {
  for (var i = 0; i + 12 <= data.length; i++) {
    if (data[i]==0x62 && data[i+1]==0x76 && data[i+2]==0x34 && data[i+3]==0x31) {
      try {
        final dec = Bv41.decode(data, i);
        if (dec.length > 8) {
          var k = 8;
          final allowed = 'vufiSAd()'.codeUnits.toSet();
          while (k < dec.length && allowed.contains(dec[k])) k++;
          final schema = String.fromCharCodes(dec.sublist(8, k));
          if (schema.startsWith('vA(v)A(u)A(u)')) return dec;
        }
      } catch(_) {}
    }
  }
  return null;
}

Future<void> main(List<String> args) async {
  final src = args[0];
  final pageIdx = int.parse(args[1]);
  final doc = await GoodNotesDocument.openFile(src);
  final page = doc.pages[pageIdx];

  // Get raw page data for additional body parsing
  final tmpDir = Directory.systemTemp.createTempSync('s31bx_');
  await Process.run('unzip', ['-o', src, 'index.notes.pb', 'notes/*', '-d', tmpDir.path]);

  final indexData = File('${tmpDir.path}/index.notes.pb').readAsBytesSync();
  final indexRecs = PbReader.readLengthPrefixedRecords(indexData);
  String? pageUuid;
  var idx = 0;
  for (final rec in indexRecs) {
    final fields = PbReader(rec).readAll();
    final f2 = fields.where((f) => f.number == 2 && f.wireType == PbWireType.lengthDelim).firstOrNull;
    if (f2 != null && f2.asString.startsWith('notes/')) {
      if (idx == pageIdx) {
        pageUuid = f2.asString.substring('notes/'.length);
        break;
      }
      idx++;
    }
  }

  final notesData = File('${tmpDir.path}/notes/$pageUuid').readAsBytesSync();
  final records = PbReader.readLengthPrefixedRecords(notesData);

  // Map uuid -> body bytes
  final bodyByUuid = <String, Uint8List>{};
  for (final rec in records) {
    Map<int, List<PbField>> outer;
    try { outer = PbReader(rec).grouped(); } catch(_) { continue; }
    for (final f in outer.values.expand((x) => x)) {
      if (f.wireType != PbWireType.lengthDelim) continue;
      try {
        final inner = f.asMessage.grouped();
        final innerOne = inner[1]?.first;
        if (innerOne == null) continue;
        if (innerOne.wireType != PbWireType.lengthDelim) continue;
        if (innerOne.asBytes.length != 36) continue;
        final b = innerOne.asBytes;
        if (b[8] != 0x2d || b[13] != 0x2d || b[18] != 0x2d || b[23] != 0x2d) continue;
        bodyByUuid[innerOne.asString] = f.asBytes;
        break;
      } catch(_) {}
    }
  }

  // Now cross-reference with parsed elements
  for (final el in page.elements) {
    if (el is! StrokeElement) continue;
    final bodyBytes = bodyByUuid[el.id];
    if (bodyBytes == null) continue;
    if (!_hasBv41Schema31(bodyBytes)) continue;

    final bx = el.bbox;
    final pos = bx == null ? 'null' : '(${bx.minX.toStringAsFixed(0)},${bx.minY.toStringAsFixed(0)} ${bx.width.toStringAsFixed(0)}x${bx.height.toStringAsFixed(0)})';
    final c = el.color;
    print('STK op=${el.opType} L${el.lamport} $pos pts=${el.points.length} color=(${c.r.toStringAsFixed(2)},${c.g.toStringAsFixed(2)},${c.b.toStringAsFixed(2)})');

    // Show the decompressed bv41 content
    final dec = _getDecompressedBv41(bodyBytes);
    if (dec != null) {
      final hexAll = dec.map((b) => b.toRadixString(16).padLeft(2,'0')).join('');
      print('  bv41 decompressed [${dec.length} bytes]: $hexAll');
    }

    // Show body field[7] (CRDT ref)
    final bfields = PbReader(bodyBytes).grouped();
    final f7 = bfields[7]?.first;
    if (f7 != null && f7.wireType == PbWireType.lengthDelim) {
      print('  body[7]: ${f7.asBytes.map((b) => b.toRadixString(16).padLeft(2,'0')).join('')}');
    }
  }

  tmpDir.deleteSync(recursive: true);
}
