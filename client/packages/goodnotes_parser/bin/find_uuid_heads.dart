/// Find all HEAD records for a specific UUID.
import 'dart:io';
import 'package:goodnotes_parser/src/protobuf.dart';

bool _looksLikeUuid(List<int> b) =>
    b.length == 36 && b[8] == 0x2d && b[13] == 0x2d && b[18] == 0x2d && b[23] == 0x2d;

Future<void> main(List<String> args) async {
  final path = args[0];
  final pageNum = int.parse(args[1]);
  final targetUuid = args[2].toUpperCase();

  final tmpDir = Directory.systemTemp.createTempSync('fuh_');
  await Process.run('unzip', ['-o', path, 'index.notes.pb', 'notes/*', '-d', tmpDir.path]);

  final indexData = File('${tmpDir.path}/index.notes.pb').readAsBytesSync();
  final indexRecs = PbReader.readLengthPrefixedRecords(indexData);
  String? pageUuid;
  var idx = 0;
  for (final rec in indexRecs) {
    final fields = PbReader(rec).readAll();
    final f2 = fields.where((f) => f.number == 2 && f.wireType == PbWireType.lengthDelim).firstOrNull;
    if (f2 != null && f2.asString.startsWith('notes/')) {
      if (idx == pageNum) { pageUuid = f2.asString.substring('notes/'.length); break; }
      idx++;
    }
  }
  if (pageUuid == null) { print('Page not found'); return; }

  final notesData = File('${tmpDir.path}/notes/$pageUuid').readAsBytesSync();
  final records = PbReader.readLengthPrefixedRecords(notesData);

  var found = 0;
  for (final rec in records) {
    List<PbField> fields;
    try { fields = PbReader(rec).readAll(); } catch(_) { continue; }
    final f1 = fields.where((f) => f.number == 1 && f.wireType == PbWireType.lengthDelim).firstOrNull;
    if (f1 == null || !_looksLikeUuid(f1.asBytes)) continue;
    if (f1.asString.toUpperCase() != targetUuid) continue;
    found++;
    final f9 = fields.where((f) => f.number == 9 && f.wireType == PbWireType.varint).firstOrNull;
    final f2 = fields.where((f) => f.number == 2 && f.wireType == PbWireType.lengthDelim).firstOrNull;
    final opType = f2?.asMessage.grouped()[1]?.first.asInt ?? -1;
    final lam = f9?.asInt ?? -1;
    final actor = fields.where((f) => f.number == 8).firstOrNull?.asInt ?? 0;
    print('HEAD #$found: op=$opType L$lam actor=$actor');
  }
  if (found == 0) print('Not found');
  tmpDir.deleteSync(recursive: true);
}
