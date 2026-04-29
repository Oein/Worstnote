// Dump all bv41 blobs in the body bytes for a given element (by lamport).
import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/bv41.dart';

String hexStr(Uint8List b, [int n = 32]) =>
    List.generate(n < b.length ? n : b.length,
        (i) => b[i].toRadixString(16).padLeft(2, '0')).join(' ');

void dumpMsg(Uint8List b, {String prefix = '', int maxDepth = 6, int depth = 0}) {
  if (depth > maxDepth) { print('${prefix}...'); return; }
  List<PbField> fields;
  try {
    fields = PbReader(b).readAll();
  } catch (_) {
    try {
      final s = utf8.decode(b, allowMalformed: false);
      if (s.runes.isNotEmpty && s.runes.every((r) => r >= 0x20 || r == 0x0a)) {
        print('${prefix}UTF8: "${s.replaceAll('\n', '\\n')}"');
        return;
      }
    } catch (_) {}
    print('${prefix}raw[${b.length}]: ${hexStr(b, 16)}');
    return;
  }
  for (final f in fields) {
    if (f.wireType == PbWireType.varint) {
      print('$prefix#${f.number} varint=${f.asInt}');
    } else if (f.wireType == PbWireType.fixed32) {
      print('$prefix#${f.number} f32=${f.asFloat32}');
    } else if (f.wireType == PbWireType.lengthDelim) {
      final bytes = f.asBytes;
      String? asText;
      if (bytes.length < 500) {
        try {
          final s = utf8.decode(bytes, allowMalformed: false);
          if (s.runes.isNotEmpty && s.runes.every((r) => r >= 0x20 || r == 0x0a)) {
            asText = s;
          }
        } catch (_) {}
      }
      if (asText != null) {
        print('$prefix#${f.number} text: "${asText.replaceAll('\n', '\\n')}"');
      } else {
        print('$prefix#${f.number} bytes[${bytes.length}]');
        dumpMsg(bytes, prefix: '$prefix  ', maxDepth: maxDepth, depth: depth + 1);
      }
    }
  }
}

List<int> findAllBv41(Uint8List b) {
  final out = <int>[];
  for (var i = 0; i + 4 <= b.length; i++) {
    if (b[i] == 0x62 && b[i+1] == 0x76 && b[i+2] == 0x34 && b[i+3] == 0x31) {
      out.add(i);
      if (i + 12 <= b.length) {
        final dst = ByteData.sublistView(b, i).getUint32(8, Endian.little);
        i += 12 + dst - 1;
      }
    }
  }
  return out;
}

Future<void> main(List<String> args) async {
  final dir = args[0];
  final targetLamport = args.length > 1 ? int.parse(args[1]) : 10191;

  final notesDir = Directory('$dir/notes');
  String? targetUuid;

  for (final file in notesDir.listSync().whereType<File>()) {
    final data = file.readAsBytesSync();
    List<Uint8List> records;
    try { records = PbReader.readLengthPrefixedRecords(data); } catch (_) { continue; }

    // Find HEAD: extract UUID
    for (final rec in records) {
      List<PbField> fields;
      try { fields = PbReader(rec).readAll(); } catch (_) { continue; }
      final lamport = fields.where((f) => f.number == 9 && f.wireType == PbWireType.varint).firstOrNull?.asInt;
      if (lamport != targetLamport) continue;
      targetUuid = fields.where((f) => f.number == 1 && f.wireType == PbWireType.lengthDelim).firstOrNull?.asString;
      print('UUID: $targetUuid');
      break;
    }
    if (targetUuid == null) continue;

    // Find BODY: the outer field whose inner #1 == uuid
    for (final rec in records) {
      List<PbField> outerFields;
      try { outerFields = PbReader(rec).readAll(); } catch (_) { continue; }

      for (final of in outerFields) {
        if (of.wireType != PbWireType.lengthDelim) continue;
        Uint8List bodyBytes;
        try {
          final inner = of.asMessage.grouped();
          final uuidField = inner[1]?.first;
          if (uuidField == null) continue;
          if (uuidField.wireType != PbWireType.lengthDelim) continue;
          if (uuidField.asString != targetUuid) continue;
          bodyBytes = of.asBytes;
        } catch (_) { continue; }

        print('Body size: ${bodyBytes.length} bytes');
        final offsets = findAllBv41(bodyBytes);
        print('Found ${offsets.length} bv41 blobs: $offsets');

        for (var blobIdx = 0; blobIdx < offsets.length; blobIdx++) {
          final off = offsets[blobIdx];
          try {
            final inflated = Bv41.decode(bodyBytes, off);
            print('\n--- bv41 blob $blobIdx at body-offset $off '
                '(${inflated.length} bytes inflated, '
                'first=0x${inflated.isNotEmpty ? inflated[0].toRadixString(16).padLeft(2,"0") : "empty"}) ---');
            dumpMsg(inflated, maxDepth: 7);
          } catch (e) {
            print('  decode error: $e');
          }
        }
        return;
      }
    }
  }
  print('Not found.');
}
