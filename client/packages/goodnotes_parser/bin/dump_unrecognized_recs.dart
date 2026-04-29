/// Count and categorize ALL LP records in a page notes file.
/// Show records that are not recognized as HEAD or BODY.
import 'dart:io';
import 'dart:typed_data';
import 'package:goodnotes_parser/src/protobuf.dart';

bool _looksLikeUuid(List<int> b) =>
    b.length == 36 && b[8] == 0x2d && b[13] == 0x2d && b[18] == 0x2d && b[23] == 0x2d;

Future<void> main(List<String> args) async {
  final path = args[0];
  final pageNum = args.length > 1 ? int.parse(args[1]) : 0;

  final tmpDir = Directory.systemTemp.createTempSync('urec_');
  await Process.run('unzip', ['-o', path, 'index.notes.pb', 'notes/*', '-d', tmpDir.path]);

  final indexData = File('${tmpDir.path}/index.notes.pb').readAsBytesSync();
  final indexRecs = PbReader.readLengthPrefixedRecords(indexData);
  String? pageUuid;
  var idx = 0;
  for (final rec in indexRecs) {
    final fields = PbReader(rec).readAll();
    final f2 = fields.where((f) => f.number == 2 && f.wireType == PbWireType.lengthDelim).firstOrNull;
    if (f2 != null && f2.asString.startsWith('notes/')) {
      if (idx == pageNum) {
        pageUuid = f2.asString.substring('notes/'.length);
        break;
      }
      idx++;
    }
  }
  if (pageUuid == null) { print('Page not found'); return; }

  final notesData = File('${tmpDir.path}/notes/$pageUuid').readAsBytesSync();
  final records = PbReader.readLengthPrefixedRecords(notesData);

  var totalRecs = 0;
  var headCount = 0;
  var bodyCount = 0;
  var unrecognized = 0;

  for (final rec in records) {
    totalRecs++;
    List<PbField> fields;
    try {
      fields = PbReader(rec).readAll();
    } catch (_) {
      unrecognized++;
      print('REC[${totalRecs-1}] PARSE_ERROR len=${rec.length}');
      continue;
    }

    // Check if HEAD
    final f1 = fields.where((f) => f.number == 1 && f.wireType == PbWireType.lengthDelim).firstOrNull;
    bool isHead = false;
    if (f1 != null && _looksLikeUuid(f1.asBytes)) {
      final has2 = fields.any((f) => f.number == 2 && f.wireType == PbWireType.lengthDelim);
      final has9 = fields.any((f) => f.number == 9 && f.wireType == PbWireType.varint);
      if (has2 && has9) {
        isHead = true;
        headCount++;
      }
    }
    if (isHead) continue;

    // Check if BODY
    bool isBody = false;
    for (final f in fields) {
      if (f.wireType != PbWireType.lengthDelim) continue;
      try {
        final inner = f.asMessage.grouped();
        final innerOne = inner[1]?.first;
        if (innerOne == null) continue;
        if (innerOne.wireType != PbWireType.lengthDelim) continue;
        if (_looksLikeUuid(innerOne.asBytes)) {
          isBody = true;
          bodyCount++;
          break;
        }
      } catch(_) {}
    }
    if (isBody) continue;

    // Unrecognized
    unrecognized++;
    final fieldNums = fields.map((f) => f.number).toList()..sort();
    final firstField = fields.isNotEmpty ? fields.first : null;
    final firstInfo = firstField == null ? 'empty' :
        '${firstField.wireType.name}#${firstField.number}='
        '${firstField.wireType == PbWireType.varint ? firstField.asInt.toString() : 'len${firstField.asBytes.length}'}';
    print('UNREC[${totalRecs-1}] len=${rec.length} fields=$fieldNums first=$firstInfo');
  }

  print('');
  print('Total records: $totalRecs');
  print('HEAD: $headCount, BODY: $bodyCount, Unrecognized: $unrecognized');

  tmpDir.deleteSync(recursive: true);
}
