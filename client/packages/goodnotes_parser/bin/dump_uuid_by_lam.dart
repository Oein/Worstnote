/// Show UUID and container link for given Lamport values on a page.
import 'dart:io';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/bv41.dart';

bool _looksLikeUuid(List<int> b) =>
    b.length == 36 && b[8] == 0x2d && b[13] == 0x2d && b[18] == 0x2d && b[23] == 0x2d;

Future<void> main(List<String> args) async {
  final path = args[0];
  final pageNum = int.parse(args[1]);
  final targets = args.skip(2).map(int.parse).toSet();

  final tmpDir = Directory.systemTemp.createTempSync('uid_');
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

  // Collect ALL HEAD records by lamport (there may be dups with same UUID)
  final headsByLam = <int, Map<String,dynamic>>{};
  for (final rec in records) {
    List<PbField> fields;
    try { fields = PbReader(rec).readAll(); } catch(_) { continue; }
    final f1 = fields.where((f) => f.number == 1 && f.wireType == PbWireType.lengthDelim).firstOrNull;
    if (f1 == null || !_looksLikeUuid(f1.asBytes)) continue;
    final f9 = fields.where((f) => f.number == 9 && f.wireType == PbWireType.varint).firstOrNull;
    if (f9 == null) continue;
    final lam = f9.asInt;
    if (!targets.contains(lam)) continue;
    final f2 = fields.where((f) => f.number == 2 && f.wireType == PbWireType.lengthDelim).firstOrNull;
    final opType = f2?.asMessage.grouped()[1]?.first.asInt ?? -1;
    headsByLam[lam] = {'uuid': f1.asString, 'op': opType};
  }

  // Find bodies and check field #6 (container link)
  for (final rec in records) {
    Map<int, List<PbField>> outer;
    try { outer = PbReader(rec).grouped(); } catch(_) { continue; }
    for (final f in outer.values.expand((x) => x)) {
      if (f.wireType != PbWireType.lengthDelim) continue;
      try {
        final inner = f.asMessage.grouped();
        final innerOne = inner[1]?.first;
        if (innerOne == null || innerOne.wireType != PbWireType.lengthDelim) continue;
        if (!_looksLikeUuid(innerOne.asBytes)) continue;
        final uuid = innerOne.asString;

        // Find which target Lamport this UUID belongs to
        int? matchLam;
        for (final e in headsByLam.entries) {
          if (e.value['uuid'] == uuid) { matchLam = e.key; break; }
        }
        if (matchLam == null) continue;

        final bodyBytes = f.asBytes;
        final body = PbReader(bodyBytes).grouped();

        // Check field #6 for container link
        final f6 = body[6]?.first;
        String containerLink = 'none';
        if (f6 != null && f6.wireType == PbWireType.lengthDelim) {
          try {
            final m6 = f6.asMessage.grouped();
            final f6_1 = m6[1]?.first;
            if (f6_1 != null && f6_1.wireType == PbWireType.lengthDelim && _looksLikeUuid(f6_1.asBytes)) {
              containerLink = f6_1.asString;
            }
          } catch(_) {}
        }

        // Extract text
        String textContent = '';
        for (var i = 0; i + 4 <= bodyBytes.length; i++) {
          if (bodyBytes[i] == 0x62 && bodyBytes[i+1] == 0x76 && bodyBytes[i+2] == 0x34 && bodyBytes[i+3] == 0x31) {
            try {
              final inf = Bv41.decode(bodyBytes, i);
              if (inf.isNotEmpty && inf[0] == 0x0a) {
                final outer2 = PbReader(inf).grouped();
                final paras = outer2[1] ?? [];
                final parts = <String>[];
                for (final p in paras) {
                  if (p.wireType != PbWireType.lengthDelim) continue;
                  final m = p.asMessage.grouped();
                  final t = m[1]?.first?.asString ?? '';
                  if (t.isNotEmpty) parts.add(t);
                }
                textContent = parts.join(' / ');
                break;
              }
            } catch(_) {}
          }
        }

        print('L$matchLam op=${headsByLam[matchLam]!["op"]} uuid=$uuid container=$containerLink text="$textContent"');
        break;
      } catch(_) {}
    }
  }

  tmpDir.deleteSync(recursive: true);
}
