import 'dart:io';
import 'package:goodnotes_parser/src/protobuf.dart';

Future<void> main(List<String> args) async {
  final path = args[0];
  final tmpDir = Directory.systemTemp.createTempSync('lsp_');
  await Process.run('unzip', ['-o', path, 'index.notes.pb', 'notes/*', '-d', tmpDir.path]);
  
  final indexData = File('${tmpDir.path}/index.notes.pb').readAsBytesSync();
  final indexRecs = PbReader.readLengthPrefixedRecords(indexData);
  int idx = 0;
  for (final rec in indexRecs) {
    final fields = PbReader(rec).readAll();
    final f2 = fields.where((f) => f.number == 2 && f.wireType == PbWireType.lengthDelim).firstOrNull;
    if (f2 != null && f2.asString.startsWith('notes/')) {
      final uuid = f2.asString.substring('notes/'.length);
      final notesFile = File('${tmpDir.path}/notes/$uuid');
      final size = notesFile.existsSync() ? notesFile.lengthSync() : -1;
      print('Page[$idx] uuid=$uuid size=$size');
      idx++;
    }
  }
  tmpDir.deleteSync(recursive: true);
}
