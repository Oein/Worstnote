// Sample CLI: dump a quick summary of a .goodnotes (or already-unzipped
// directory) package.
//
//   dart run example/main.dart path/to/file.goodnotes
//   dart run example/main.dart path/to/extracted/dir/

import 'dart:io';

import 'package:goodnotes_parser/goodnotes_parser.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: main.dart <file.goodnotes | extracted-dir>');
    exit(2);
  }
  final path = args.first;
  final stat = FileStat.statSync(path);
  final doc = stat.type == FileSystemEntityType.directory
      ? await GoodNotesDocument.openDirectory(path)
      : await GoodNotesDocument.openFile(path);

  print('title           : ${doc.title}');
  print('schema version  : ${doc.schemaVersion}');
  print('pages           : ${doc.pages.length}');
  print('attachments     : ${doc.attachments.length}');
  print('search indices  : ${doc.searchIndices.length}');
  print('thumbnail bytes : ${doc.thumbnail?.length ?? 0}');
  print('');

  for (final p in doc.pages) {
    print('--- page ${p.id} (${p.elements.length} elements) ---');
    final s = p.strokes.length;
    final t = p.texts.length;
    print('  strokes=$s texts=$t bg=${p.backgroundAttachmentId}');
    for (final tx in p.texts.take(5)) {
      print('  text: "${tx.text}" size=${tx.fontSize} '
          'color=${tx.color}');
    }
    for (final st in p.strokes.take(3)) {
      print('  stroke: ${st.points.length} points '
          'width=${st.width.toStringAsFixed(2)} color=${st.color}');
    }
  }

  for (final a in doc.attachments.values) {
    print('attachment ${a.id} ${a.mimeType} ${a.bytes.length}B '
        'disk=${a.diskUuid}');
  }

  for (final s in doc.searchIndices.values) {
    final preview = s.tokens
        .map((t) => t.text)
        .where((t) => t.isNotEmpty)
        .take(20)
        .join(', ');
    print('search ${s.targetId} (forAttach=${s.forAttachment}) '
        '${s.tokens.length} tokens — $preview');
  }
}
