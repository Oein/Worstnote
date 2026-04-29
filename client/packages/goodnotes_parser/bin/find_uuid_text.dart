import 'dart:typed_data';
import 'dart:io';
import 'dart:convert';
import 'package:archive/archive_io.dart';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/bv41.dart';

Future<void> main(List<String> args) async {
  final path = args[0];
  final target = args.length > 1 ? args[1] : '수도';

  Iterable<MapEntry<String,Uint8List>> noteFiles;
  final f = File(path);
  if (f.existsSync()) {
    final archive = ZipDecoder().decodeBytes(f.readAsBytesSync());
    noteFiles = archive
        .where((e) => e.isFile && e.name.startsWith('notes/'))
        .map((e) => MapEntry(e.name, Uint8List.fromList(e.content as List<int>)));
  } else {
    noteFiles = Directory('$path/notes')
        .listSync().whereType<File>()
        .map((e) => MapEntry(e.path, e.readAsBytesSync()));
  }

  for (final entry in noteFiles) {
    final data = entry.value;
    List<Uint8List> records;
    try { records = PbReader.readLengthPrefixedRecords(data); } catch(_) { continue; }

    final headByUuid = <String,int>{};
    final bodyUuids = <String>{};

    for (final rec in records) {
      List<PbField> fields;
      try { fields = PbReader(rec).readAll(); } catch(_) { continue; }

      // HEAD detection
      final f1 = fields.where((f) => f.number == 1 && f.wireType == PbWireType.lengthDelim).firstOrNull;
      if (f1 != null && f1.asBytes.length == 36 && f1.asBytes[8] == 0x2d) {
        final has9 = fields.any((f) => f.number == 9 && f.wireType == PbWireType.varint);
        final f2 = fields.where((f) => f.number == 2 && f.wireType == PbWireType.lengthDelim).firstOrNull;
        if (has9 && f2 != null) {
          final op = f2.asMessage.grouped()[1]?.first.asInt ?? -1;
          headByUuid[f1.asString] = op;
          continue;
        }
      }

      // BODY detection — scan for any field whose inner[1] is a UUID
      for (final fld in fields) {
        if (fld.wireType != PbWireType.lengthDelim) continue;
        try {
          final inner = fld.asMessage.grouped();
          final i1 = inner[1]?.first;
          if (i1 == null || i1.wireType != PbWireType.lengthDelim) continue;
          final b = i1.asBytes;
          if (b.length != 36 || b[8] != 0x2d) continue;
          // Check if this body contains target string in bv41
          final bodyBytes = fld.asBytes;
          for (var i = 0; i + 4 <= bodyBytes.length; i++) {
            if (bodyBytes[i]==0x62&&bodyBytes[i+1]==0x76&&bodyBytes[i+2]==0x34&&bodyBytes[i+3]==0x31) {
              try {
                final dec = Bv41.decode(bodyBytes, i);
                final s = const Utf8Codec(allowMalformed: true).decode(dec);
                if (s.contains(target)) {
                  final uuid = i1.asString;
                  bodyUuids.add(uuid);
                  print('BODY uuid=$uuid (field#${fld.number}) has "$target" in bv41');
                  print('  opType from headByUuid: ${headByUuid[uuid] ?? "NOT IN HEAD"}');
                }
              } catch(_) {}
            }
          }
        } catch(_) {}
      }
    }

    // Also check heads for these UUIDs
    for (final uuid in bodyUuids) {
      if (headByUuid.containsKey(uuid)) {
        print('  => HEAD found: uuid=$uuid opType=${headByUuid[uuid]}');
      } else {
        print('  => HEAD missing for uuid=$uuid');
      }
    }
  }
}
