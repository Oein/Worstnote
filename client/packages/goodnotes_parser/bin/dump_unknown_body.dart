/// Dump the body of a specific element by its Lamport clock value.
import 'dart:io';
import 'dart:typed_data';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/bv41.dart';

bool _looksLikeUuid(List<int> b) =>
    b.length == 36 && b[8] == 0x2d && b[13] == 0x2d && b[18] == 0x2d && b[23] == 0x2d;

void _dumpFieldRecurse(PbField f, int depth) {
  final indent = '  ' * depth;
  if (f.wireType == PbWireType.varint) {
    print('${indent}field[${f.number}] varint=${f.asInt}');
  } else if (f.wireType == PbWireType.fixed32) {
    print('${indent}field[${f.number}] f32=${f.asFloat32}');
  } else if (f.wireType == PbWireType.fixed64) {
    print('${indent}field[${f.number}] f64 (${f.asBytes.length}b)');
  } else if (f.wireType == PbWireType.lengthDelim) {
    final bytes = f.asBytes;
    if (bytes.length == 36 && _looksLikeUuid(bytes)) {
      print('${indent}field[${f.number}] UUID=${f.asString}');
      return;
    }
    final hexPrev = bytes.take(32).map((b) => b.toRadixString(16).padLeft(2,'0')).join('');
    print('${indent}field[${f.number}] len=${bytes.length} hex=$hexPrev${bytes.length > 32 ? "..." : ""}');
    // Check for bv41
    for (var i = 0; i + 12 <= bytes.length; i++) {
      if (bytes[i]==0x62 && bytes[i+1]==0x76 && bytes[i+2]==0x34 && bytes[i+3]==0x31) {
        try {
          final dec = Bv41.decode(bytes, i);
          print('${indent}  [bv41 at $i] decompressed ${dec.length} bytes:');
          print('${indent}  ${dec.map((b) => b.toRadixString(16).padLeft(2,'0')).join('')}');
        } catch(_) {}
      }
    }
    // Try sub-message parse
    try {
      final sub = f.asMessage.readAll();
      if (sub.isNotEmpty && depth < 3) {
        for (final sf in sub) {
          _dumpFieldRecurse(sf, depth + 1);
        }
      }
    } catch(_) {}
  }
}

Future<void> main(List<String> args) async {
  final path = args[0];
  final pageNum = int.parse(args[1]);
  final targetLamport = int.parse(args[2]);

  final tmpDir = Directory.systemTemp.createTempSync('unk_');
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

  // Find the HEAD with targetLamport, then get its body
  String? targetUuid;
  for (final rec in records) {
    List<PbField> fields;
    try { fields = PbReader(rec).readAll(); } catch(_) { continue; }
    final f1 = fields.where((f) => f.number == 1 && f.wireType == PbWireType.lengthDelim).firstOrNull;
    if (f1 == null || !_looksLikeUuid(f1.asBytes)) continue;
    final f9 = fields.where((f) => f.number == 9 && f.wireType == PbWireType.varint).firstOrNull;
    if (f9 == null || f9.asInt != targetLamport) continue;
    targetUuid = f1.asString;
    final f2 = fields.where((f) => f.number == 2 && f.wireType == PbWireType.lengthDelim).firstOrNull;
    final opType = f2?.asMessage.grouped()[1]?.first.asInt ?? -1;
    final actor = fields.where((f) => f.number == 8).firstOrNull?.asInt ?? 0;
    print('Found HEAD: uuid=$targetUuid op=$opType L$targetLamport actor=$actor');
    break;
  }

  if (targetUuid == null) { print('Not found'); return; }

  // Find the body
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
        if (innerOne.asString != targetUuid) continue;
        print('\nBody bytes (${f.asBytes.length}):');
        final bodyBytes = f.asBytes;
        print(bodyBytes.map((b) => b.toRadixString(16).padLeft(2,'0')).join(''));
        print('\nParsed body fields:');
        final bodyFields = PbReader(bodyBytes).readAll();
        for (final bf in bodyFields) {
          _dumpFieldRecurse(bf, 0);
        }
        tmpDir.deleteSync(recursive: true);
        return;
      } catch(_) {}
    }
  }
  print('Body not found');
  tmpDir.deleteSync(recursive: true);
}
