import 'dart:io';
import 'package:goodnotes_parser/src/protobuf.dart';

bool _looksLikeUuid(List<int> b) =>
    b.length == 36 && b[8] == 0x2d && b[13] == 0x2d && b[18] == 0x2d && b[23] == 0x2d;

Future<void> main() async {
  final path = '/Users/oein/Downloads/notes/TF3.goodnotes';
  final pageNum = 1;

  final tmpDir = Directory.systemTemp.createTempSync('tf3p2_');
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
  print('Page UUID: $pageUuid');
  if (pageUuid == null) { return; }

  final notesData = File('${tmpDir.path}/notes/$pageUuid').readAsBytesSync();
  print('Notes data size: ${notesData.length}');
  
  final records = PbReader.readLengthPrefixedRecords(notesData);
  print('Total LP records: ${records.length}');
  
  int headCount = 0, bodyLike = 0;
  final opTypes = <int, int>{};
  
  for (final rec in records) {
    try {
      final fields = PbReader(rec).readAll();
      final f1 = fields.where((f) => f.number == 1 && f.wireType == PbWireType.lengthDelim).firstOrNull;
      final f9 = fields.where((f) => f.number == 9 && f.wireType == PbWireType.varint).firstOrNull;
      if (f1 != null && _looksLikeUuid(f1.asBytes) && f9 != null) {
        headCount++;
        final f2 = fields.where((f) => f.number == 2 && f.wireType == PbWireType.lengthDelim).firstOrNull;
        final op = f2?.asMessage.grouped()[1]?.first.asInt ?? -1;
        opTypes[op] = (opTypes[op] ?? 0) + 1;
      } else {
        bodyLike++;
      }
    } catch(_) {}
  }
  
  print('HEAD-like records: $headCount, BODY-like: $bodyLike');
  print('OpTypes: $opTypes');
  
  tmpDir.deleteSync(recursive: true);
}
