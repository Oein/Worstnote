/// Find polyline shapes with body[20] containing specific coordinates.
import 'dart:io';
import 'package:goodnotes_parser/src/protobuf.dart';

bool _looksLikeUuid(List<int> b) =>
    b.length == 36 && b[8] == 0x2d && b[13] == 0x2d && b[18] == 0x2d && b[23] == 0x2d;

double _asF32(PbField f) {
  if (f.wireType == PbWireType.fixed32) return f.asFloat32;
  if (f.wireType == PbWireType.lengthDelim) {
    final m = f.asMessage.grouped();
    final f1 = m[1]?.first;
    if (f1 != null && f1.wireType == PbWireType.fixed32) return f1.asFloat32;
    if (f1 != null && f1.wireType == PbWireType.lengthDelim) {
      final m2 = f1.asMessage.grouped();
      final fx = m2[1]?.first;
      if (fx != null && fx.wireType == PbWireType.fixed32) return fx.asFloat32;
    }
  }
  return double.nan;
}

Future<void> main(List<String> args) async {
  final path = args[0];
  final pageNum = args.length > 1 ? int.parse(args[1]) : 0;
  final tmpDir = Directory.systemTemp.createTempSync('fpc_');
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

        // Get all coordinates from body[20]
        final b20 = body[20]?.first;
        if (b20 == null || b20.wireType != PbWireType.lengthDelim) continue;

        final m20 = b20.asMessage.grouped();
        final allPts = <(double,double)>[];
        
        // First point: body[20][1]
        final fp = m20[1]?.first;
        if (fp != null && fp.wireType == PbWireType.lengthDelim) {
          final fm = fp.asMessage.grouped();
          final p1 = fm[1]?.first;
          if (p1 != null) {
            if (p1.wireType == PbWireType.lengthDelim) {
              final pm = p1.asMessage.grouped();
              final x = pm[1]?.first?.asFloat32;
              final y = pm[2]?.first?.asFloat32;
              if (x != null && y != null) allPts.add((x, y));
            } else if (p1.wireType == PbWireType.fixed32) {
              final x = p1.asFloat32;
              final p2 = fm[2]?.first;
              if (p2 != null && p2.wireType == PbWireType.fixed32) allPts.add((x, p2.asFloat32));
            }
          }
        }

        // Mid points: body[20][2] (repeated)
        for (final mp in m20[2] ?? <PbField>[]) {
          if (mp.wireType != PbWireType.lengthDelim) continue;
          final mm = mp.asMessage.grouped();
          final x = mm[1]?.first?.asFloat32;
          final y = mm[2]?.first?.asFloat32;
          if (x != null && y != null) allPts.add((x, y));
        }

        // Last point: body[20][3]
        final lp = m20[3]?.first;
        if (lp != null && lp.wireType == PbWireType.lengthDelim) {
          final lm = lp.asMessage.grouped();
          final p1 = lm[1]?.first;
          if (p1 != null) {
            if (p1.wireType == PbWireType.lengthDelim) {
              final pm = p1.asMessage.grouped();
              final x = pm[1]?.first?.asFloat32;
              final y = pm[2]?.first?.asFloat32;
              if (x != null && y != null) allPts.add((x, y));
            } else if (p1.wireType == PbWireType.fixed32) {
              final x = p1.asFloat32;
              final p2 = lm[2]?.first;
              if (p2 != null && p2.wireType == PbWireType.fixed32) allPts.add((x, p2.asFloat32));
            }
          }
        }

        if (allPts.isEmpty) continue;

        final int flag = () {
          try {
            final b3 = body[3]?.first;
            if (b3 != null && b3.wireType == PbWireType.lengthDelim) {
              return b3.asMessage.grouped()[1]?.first.asInt ?? 1;
            }
          } catch(_) {}
          return 1;
        }();

        final firstPt = allPts.first;
        final lastPt = allPts.last;
        print('L${head["lam"]} op=${head["op"]} flag=$flag pts=${allPts.length} '
            'first=(${firstPt.$1.toStringAsFixed(1)},${firstPt.$2.toStringAsFixed(1)}) '
            'last=(${lastPt.$1.toStringAsFixed(1)},${lastPt.$2.toStringAsFixed(1)})');
        break;
      } catch(_) {}
    }
  }

  tmpDir.deleteSync(recursive: true);
}
