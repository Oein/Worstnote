/// Dump all schema-31 body[2]=varint 31 elements with coordinates on a page.
import 'dart:io';
import 'package:goodnotes_parser/src/protobuf.dart';

bool _looksLikeUuid(List<int> b) =>
    b.length == 36 && b[8] == 0x2d && b[13] == 0x2d && b[18] == 0x2d && b[23] == 0x2d;

Future<void> main(List<String> args) async {
  final path = args[0];
  final pageNum = args.length > 1 ? int.parse(args[1]) : 0;
  final tmpDir = Directory.systemTemp.createTempSync('apl_');
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

  final heads = <String, Map<String,dynamic>>{};
  for (final rec in records) {
    List<PbField> fields;
    try { fields = PbReader(rec).readAll(); } catch(_) { continue; }
    final f1 = fields.where((f) => f.number == 1 && f.wireType == PbWireType.lengthDelim).firstOrNull;
    if (f1 == null || !_looksLikeUuid(f1.asBytes)) continue;
    final f9 = fields.where((f) => f.number == 9 && f.wireType == PbWireType.varint).firstOrNull;
    if (f9 == null) continue;
    final f2 = fields.where((f) => f.number == 2 && f.wireType == PbWireType.lengthDelim).firstOrNull;
    final opType = f2?.asMessage.grouped()[1]?.first.asInt ?? -1;
    heads[f1.asString] = {'lam': f9.asInt, 'op': opType};
  }

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
        final head = heads[uuid];
        if (head == null) continue;

        final bodyBytes = f.asBytes;
        final body = PbReader(bodyBytes).grouped();

        // Must be body[2] = varint 31
        final b2 = body[2]?.first;
        if (b2 == null || b2.wireType != PbWireType.varint || b2.asInt != 31) continue;

        // Must have body[20]
        final b20 = body[20]?.first;
        if (b20 == null || b20.wireType != PbWireType.lengthDelim) continue;

        // Get flag
        int flag = 1;
        final b3 = body[3]?.first;
        if (b3 != null && b3.wireType == PbWireType.lengthDelim) {
          flag = b3.asMessage.grouped()[1]?.first.asInt ?? 1;
        }

        // Get first+last point
        try {
          final m20 = b20.asMessage.grouped();
          final firstPt = m20[1]?.first;
          int ptCount = 0;
          double? fx, fy, lx, ly;
          if (firstPt != null) {
            final fm = firstPt.asMessage.grouped();
            fx = fm[1]?.first.asFloat32;
            fy = fm[2]?.first.asFloat32;
            ptCount++;
          }
          // mid points
          final mids = m20[2] ?? [];
          for (final mp in mids) {
            if (mp.wireType != PbWireType.lengthDelim) continue;
            final mm = mp.asMessage.grouped();
            lx = mm[1]?.first.asFloat32;
            ly = mm[2]?.first.asFloat32;
            ptCount++;
          }
          // last point
          final lastPt = m20[3]?.first;
          if (lastPt != null) {
            final lm = lastPt.asMessage.grouped();
            lx = lm[1]?.first.asFloat32;
            ly = lm[2]?.first.asFloat32;
            ptCount++;
          }
          print('L${head["lam"]} op=${head["op"]} flag=$flag pts=$ptCount '
              'first=(${fx?.toStringAsFixed(1)},${fy?.toStringAsFixed(1)}) '
              'last=(${lx?.toStringAsFixed(1)},${ly?.toStringAsFixed(1)})');
        } catch(_) {
          print('L${head["lam"]} op=${head["op"]} flag=$flag pts=? (parse error)');
        }

        break;
      } catch(_) {}
    }
  }

  tmpDir.deleteSync(recursive: true);
}
