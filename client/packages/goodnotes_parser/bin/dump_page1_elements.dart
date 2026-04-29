import 'dart:io';
import 'dart:typed_data';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/bv41.dart';

bool _looksLikeUuid(List<int> b) =>
    b.length == 36 && b[8] == 0x2d && b[13] == 0x2d && b[18] == 0x2d && b[23] == 0x2d;

Future<void> main(List<String> args) async {
  final path = args[0];
  final pageNum = args.length > 1 ? int.parse(args[1]) : 1;
  final tmpDir = Directory.systemTemp.createTempSync('p1_');
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

  // Build head map
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

  // Find bodies and classify
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

        // Check body[2]
        final b2 = body[2]?.first;
        String type = 'unknown';
        String extra = '';

        // Check for bv41 text
        bool hasText = false;
        String textContent = '';
        for (var i = 0; i + 4 <= bodyBytes.length; i++) {
          if (bodyBytes[i] == 0x62 && bodyBytes[i+1] == 0x76 &&
              bodyBytes[i+2] == 0x34 && bodyBytes[i+3] == 0x31) {
            try {
              final inf = Bv41.decode(bodyBytes, i);
              if (inf.isNotEmpty && inf[0] == 0x0a) {
                hasText = true;
                // Try to extract text
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

        if (hasText) {
          type = 'TEXT';
          // Get bbox
          double? x, y;
          final f20 = body[20]?.first;
          if (f20 != null && f20.wireType == PbWireType.lengthDelim) {
            try {
              final m20 = f20.asMessage.grouped();
              final p = m20[1]?.first;
              if (p != null && p.wireType == PbWireType.lengthDelim) {
                final pm = p.asMessage.grouped();
                x = pm[1]?.first?.asFloat32;
                y = pm[2]?.first?.asFloat32;
              }
            } catch(_) {}
          }
          extra = 'pos=(${x?.toStringAsFixed(0)},${y?.toStringAsFixed(0)}) text="$textContent"';
        } else if (b2 != null && b2.wireType == PbWireType.varint && b2.asInt == 31) {
          type = 'POLYLINE31';
          final b20 = body[20]?.first;
          final ptCount = b20 != null ? 'has_pts' : 'no_pts';
          extra = ptCount;
        } else if (b2 != null && b2.wireType == PbWireType.lengthDelim) {
          // Maybe a stroke with bbox
          try {
            final m2 = b2.asMessage.grouped();
            final origin = m2[1]?.first;
            if (origin != null) {
              final om = origin.asMessage.grouped();
              final ox = om[1]?.first?.asFloat32;
              final oy = om[2]?.first?.asFloat32;
              final sz = m2[2]?.first?.asMessage.grouped();
              final w = sz?[1]?.first?.asFloat32;
              final h = sz?[2]?.first?.asFloat32;
              type = 'STROKE';
              extra = 'bbox=(${ox?.toStringAsFixed(0)},${oy?.toStringAsFixed(0)} ${w?.toStringAsFixed(0)}x${h?.toStringAsFixed(0)})';
            }
          } catch(_) {}
        }

        print('L${head["lam"]} op=${head["op"]} $type $extra');
        break;
      } catch(_) {}
    }
  }

  tmpDir.deleteSync(recursive: true);
}
