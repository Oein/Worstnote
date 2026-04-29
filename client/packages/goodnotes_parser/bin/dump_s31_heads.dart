/// Dump HEAD records for schema-31 strokes, showing parent/ref links.
import 'dart:io';
import 'dart:typed_data';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/bv41.dart';

bool _looksLikeUuid(List<int> b) =>
    b.length == 36 && b[8] == 0x2d && b[13] == 0x2d && b[18] == 0x2d && b[23] == 0x2d;

bool _hasBv41Schema31(Uint8List data) {
  for (var i = 0; i + 12 <= data.length; i++) {
    if (data[i]==0x62 && data[i+1]==0x76 && data[i+2]==0x34 && data[i+3]==0x31) {
      try {
        final dec = Bv41.decode(data, i);
        if (dec.length > 8) {
          var k = 8;
          final allowed = 'vufiSAd()'.codeUnits.toSet();
          while (k < dec.length && allowed.contains(dec[k])) k++;
          final schema = String.fromCharCodes(dec.sublist(8, k));
          if (schema.startsWith('vA(v)A(u)A(u)')) return true;
        }
      } catch(_) {}
    }
  }
  return false;
}

Future<void> main(List<String> args) async {
  final path = args[0];
  final pageNum = args.length > 1 ? int.parse(args[1]) : 0;

  final tmpDir = Directory.systemTemp.createTempSync('s31h_');
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

  // Collect schema-31 body UUIDs
  final schema31Uuids = <String>{};
  for (final rec in records) {
    Map<int, List<PbField>> outer;
    try { outer = PbReader(rec).grouped(); } catch(_) { continue; }
    for (final f in outer.values.expand((x) => x)) {
      if (f.wireType != PbWireType.lengthDelim) continue;
      try {
        final inner = f.asMessage.grouped();
        final innerOne = inner[1]?.first;
        if (innerOne == null) continue;
        if (innerOne.wireType != PbWireType.lengthDelim) continue;
        if (!_looksLikeUuid(innerOne.asBytes)) continue;
        if (_hasBv41Schema31(f.asBytes)) {
          schema31Uuids.add(innerOne.asString);
        }
        break;
      } catch(_) {}
    }
  }

  // Now find HEAD records for these UUIDs
  var shown = 0;
  for (final rec in records) {
    if (shown >= 5) break;
    List<PbField> fields;
    try { fields = PbReader(rec).readAll(); } catch(_) { continue; }
    final f1 = fields.where((f) => f.number == 1 && f.wireType == PbWireType.lengthDelim).firstOrNull;
    if (f1 == null || !_looksLikeUuid(f1.asBytes)) continue;
    final uuid = f1.asString;
    if (!schema31Uuids.contains(uuid)) continue;

    final f2 = fields.where((f) => f.number == 2 && f.wireType == PbWireType.lengthDelim).firstOrNull;
    if (f2 == null) continue;
    final m2 = f2.asMessage.grouped();
    final opType = m2[1]?.first.asInt ?? -1;
    final lamport = fields.where((f) => f.number == 9).firstOrNull?.asInt ?? -1;
    final actor = fields.where((f) => f.number == 8).firstOrNull?.asInt ?? 0;
    final schema = fields.where((f) => f.number == 16).firstOrNull?.asInt ?? 0;

    print('HEAD uuid=$uuid op=$opType L$lamport actor=$actor schema=$schema');

    // parent (field 6) and ref (field 7)
    for (final f in fields) {
      if (f.number == 6 && f.wireType == PbWireType.lengthDelim) {
        try { print('  parent=${f.asString}'); }
        catch(_) { print('  parent_bytes=${f.asBytes.map((b)=>b.toRadixString(16).padLeft(2,'0')).join('')}'); }
      }
      if (f.number == 7 && f.wireType == PbWireType.lengthDelim) {
        try { print('  ref=${f.asString}'); }
        catch(_) { print('  ref_bytes=${f.asBytes.map((b)=>b.toRadixString(16).padLeft(2,'0')).join('')}'); }
      }
      // any other interesting fields
      if (f.number > 9 && f.number != 16) {
        if (f.wireType == PbWireType.varint) print('  field[${f.number}]=${f.asInt}');
        else if (f.wireType == PbWireType.lengthDelim) {
          final bytes = f.asBytes;
          print('  field[${f.number}] len=${bytes.length} hex=${bytes.take(20).map((b)=>b.toRadixString(16).padLeft(2,'0')).join('')}');
        }
      }
    }
    shown++;
  }

  tmpDir.deleteSync(recursive: true);
}
