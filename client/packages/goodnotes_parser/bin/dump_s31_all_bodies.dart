/// For each schema-31 (bv41 with empty-array schema) body in TF2 page 0,
/// find ALL body records with the same UUID across the entire page file.
/// This reveals whether an earlier op=1 body was overwritten by op=4/op=7.
import 'dart:io';
import 'dart:typed_data';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/bv41.dart';

bool _looksLikeUuid(List<int> b) {
  if (b.length != 36) return false;
  return b[8] == 0x2d && b[13] == 0x2d && b[18] == 0x2d && b[23] == 0x2d;
}

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

String _bodyHex(Uint8List data) {
  return data.take(40).map((b) => b.toRadixString(16).padLeft(2,'0')).join('');
}

Future<void> main(List<String> args) async {
  final path = args[0];
  final pageNum = args.length > 1 ? int.parse(args[1]) : 0;

  final tmpDir = Directory.systemTemp.createTempSync('s31b_');
  await Process.run('unzip', ['-o', path, 'index.notes.pb', 'notes/*', '-d', tmpDir.path]);

  // Get page UUID from index
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

  final notesFile = File('${tmpDir.path}/notes/$pageUuid');
  final data = notesFile.readAsBytesSync();
  final records = PbReader.readLengthPrefixedRecords(data);

  // First pass: find all schema-31 UUIDs (the LAST body for each contains bv41-schema31)
  final schema31Uuids = <String>{};
  // Map of uuid -> list of (record_index, body_bytes)
  final allBodiesForUuid = <String, List<Uint8List>>{};

  for (var ri = 0; ri < records.length; ri++) {
    final rec = records[ri];
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
        final uuid = innerOne.asString;
        allBodiesForUuid.putIfAbsent(uuid, () => []).add(f.asBytes);
        if (_hasBv41Schema31(f.asBytes)) {
          schema31Uuids.add(uuid);
        }
        break;
      } catch(_) {}
    }
  }

  print('Total schema-31 UUIDs: ${schema31Uuids.length}');
  print('');

  // Show UUIDs that have multiple bodies
  var multiCount = 0;
  for (final uuid in schema31Uuids) {
    final bodies = allBodiesForUuid[uuid] ?? [];
    if (bodies.length > 1) {
      multiCount++;
      print('UUID $uuid has ${bodies.length} bodies:');
      for (var i = 0; i < bodies.length; i++) {
        final body = bodies[i];
        final isSc31 = _hasBv41Schema31(body);
        // Parse body fields
        Map<int, List<PbField>> bfields;
        try { bfields = PbReader(body).grouped(); } catch(_) {
          print('  body[$i] len=${body.length} [PARSE ERROR]');
          continue;
        }
        final f20 = bfields[20]?.first;
        final f21 = bfields[21]?.first;
        final f9 = bfields[9]?.first;
        final f20len = f20?.wireType == PbWireType.lengthDelim ? f20!.asBytes.length : -1;
        final f21info = f21?.wireType == PbWireType.varint ? 'varint=${f21!.asInt}' :
                        (f21?.wireType == PbWireType.lengthDelim ? 'len=${f21!.asBytes.length}' : 'null');
        final f9len = f9?.wireType == PbWireType.lengthDelim ? f9!.asBytes.length : -1;
        print('  body[$i] len=${body.length} schema31=$isSc31 f9len=$f9len f20len=$f20len f21=$f21info');
        if (f20 != null && f20.wireType == PbWireType.lengthDelim && f20.asBytes.length > 4) {
          print('    f20 hex: ${_bodyHex(f20.asBytes)}');
        }
      }
    }
  }
  print('');
  print('UUIDs with multiple bodies: $multiCount / ${schema31Uuids.length}');

  tmpDir.deleteSync(recursive: true);
}
