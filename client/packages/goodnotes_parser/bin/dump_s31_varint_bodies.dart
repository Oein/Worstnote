/// Find all body records where body[2] = varint 31 (true schema-31 polyline format).
/// These are being classified by parsers.dart, but some might be wrongly dropped.
import 'dart:io';
import 'dart:typed_data';
import 'package:goodnotes_parser/src/protobuf.dart';

bool _looksLikeUuid(List<int> b) =>
    b.length == 36 && b[8] == 0x2d && b[13] == 0x2d && b[18] == 0x2d && b[23] == 0x2d;

Future<void> main(List<String> args) async {
  final path = args[0];
  final pageNum = int.parse(args[1]);

  final tmpDir = Directory.systemTemp.createTempSync('s31v_');
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

  // Build HEAD lamport lookup
  final notesData = File('${tmpDir.path}/notes/$pageUuid').readAsBytesSync();
  final records = PbReader.readLengthPrefixedRecords(notesData);
  final headByUuid = <String, Map<String, dynamic>>{};
  for (final rec in records) {
    List<PbField> fields;
    try { fields = PbReader(rec).readAll(); } catch(_) { continue; }
    final f1 = fields.where((f) => f.number == 1 && f.wireType == PbWireType.lengthDelim).firstOrNull;
    if (f1 == null || !_looksLikeUuid(f1.asBytes)) continue;
    final f9 = fields.where((f) => f.number == 9 && f.wireType == PbWireType.varint).firstOrNull;
    if (f9 == null) continue;
    final f2h = fields.where((f) => f.number == 2 && f.wireType == PbWireType.lengthDelim).firstOrNull;
    final opType = f2h?.asMessage.grouped()[1]?.first.asInt ?? -1;
    headByUuid[f1.asString] = {'lam': f9.asInt, 'op': opType};
  }

  // Find bodies with body[2] = varint 31
  for (final rec in records) {
    Map<int, List<PbField>> outer;
    try { outer = PbReader(rec).grouped(); } catch(_) { continue; }
    for (final f in outer.values.expand((x) => x)) {
      if (f.wireType != PbWireType.lengthDelim) continue;
      Uint8List bodyBytes = f.asBytes;
      Map<int, List<PbField>> inner;
      try { inner = PbReader(bodyBytes).grouped(); } catch(_) { continue; }
      final innerOne = inner[1]?.first;
      if (innerOne == null || innerOne.wireType != PbWireType.lengthDelim) continue;
      if (!_looksLikeUuid(innerOne.asBytes)) continue;
      final uuid = innerOne.asString;

      // Check body[2] = varint 31
      final b2 = inner[2]?.first;
      if (b2 == null || b2.wireType != PbWireType.varint || b2.asInt != 31) continue;

      final head = headByUuid[uuid];
      final lam = head?['lam'] ?? -1;
      final op = head?['op'] ?? -1;

      // Get flag from body[3][1]
      int flag = 1;
      final b3 = inner[3]?.first;
      if (b3 != null && b3.wireType == PbWireType.lengthDelim) {
        flag = b3.asMessage.grouped()[1]?.first.asInt ?? 1;
      }

      // Get color from body[4] (RGBA floats)
      String colorStr = 'null';
      final b4 = inner[4]?.first;
      if (b4 != null && b4.wireType == PbWireType.lengthDelim) {
        try {
          final cm = b4.asMessage.grouped();
          final r = cm[1]?.first?.asFloat32 ?? 0;
          final g = cm[2]?.first?.asFloat32 ?? 0;
          final b_ = cm[3]?.first?.asFloat32 ?? 0;
          colorStr = '(${r.toStringAsFixed(2)},${g.toStringAsFixed(2)},${b_.toStringAsFixed(2)})';
        } catch(_) {}
      }

      // Get color from body[32][3][1] (another color location)
      String colorStr2 = 'null';
      final b32 = inner[32]?.first;
      if (b32 != null && b32.wireType == PbWireType.lengthDelim) {
        try {
          final m32 = b32.asMessage.grouped();
          final f3 = m32[3]?.first;
          if (f3 != null && f3.wireType == PbWireType.lengthDelim) {
            final cm = f3.asMessage.grouped();
            final f1c = cm[1]?.first;
            if (f1c != null && f1c.wireType == PbWireType.lengthDelim) {
              final rgb = f1c.asMessage.grouped();
              final r = rgb[1]?.first?.asFloat32 ?? 0;
              final g = rgb[2]?.first?.asFloat32 ?? 0;
              final b_ = rgb[3]?.first?.asFloat32 ?? 0;
              colorStr2 = '(${r.toStringAsFixed(2)},${g.toStringAsFixed(2)},${b_.toStringAsFixed(2)})';
            } else {
              final r = cm[1]?.first?.asFloat32 ?? 0;
              final g = cm[2]?.first?.asFloat32 ?? 0;
              final b_ = cm[3]?.first?.asFloat32 ?? 0;
              colorStr2 = '(${r.toStringAsFixed(2)},${g.toStringAsFixed(2)},${b_.toStringAsFixed(2)})';
            }
          }
        } catch(_) {}
      }

      // Count points in body[20]
      int ptCount = 0;
      double? firstX, firstY;
      final b20 = inner[20]?.first;
      if (b20 != null && b20.wireType == PbWireType.lengthDelim) {
        try {
          final m20 = b20.asMessage.grouped();
          for (final ptField in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
                                  16, 17, 18, 19, 20, 21, 22, 23, 24, 25]) {
            final pts = m20[ptField];
            if (pts == null) break;
            for (final pt in pts) {
              if (pt.wireType != PbWireType.lengthDelim) continue;
              try {
                final ptm = pt.asMessage.grouped();
                final xf = ptm[1]?.first;
                final yf = ptm[2]?.first;
                if (xf != null && yf != null) {
                  ptCount++;
                  if (firstX == null) {
                    // Try nested structure
                    if (xf.wireType == PbWireType.lengthDelim) {
                      final xm = xf.asMessage.grouped();
                      firstX = xm[1]?.first?.asFloat32;
                      firstY = xm[2]?.first?.asFloat32;
                    } else if (xf.wireType == PbWireType.fixed32) {
                      firstX = xf.asFloat32;
                      firstY = yf.wireType == PbWireType.fixed32 ? yf.asFloat32 : null;
                    }
                  }
                }
              } catch(_) {}
            }
          }
        } catch(_) {}
      }

      final posStr = firstX != null ? '(${firstX!.toStringAsFixed(0)},${firstY?.toStringAsFixed(0) ?? "?"})' : '?';

      print('L$lam op=$op flag=$flag pts=$ptCount firstPt=$posStr color4=$colorStr colorInk=$colorStr2');
      break;
    }
  }

  tmpDir.deleteSync(recursive: true);
}
