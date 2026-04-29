import 'dart:io';
import 'dart:typed_data';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/bv41.dart';

String hex(Uint8List b, [int n = 48]) =>
    List.generate(n < b.length ? n : b.length, (i) => b[i].toRadixString(16).padLeft(2,'0')).join(' ');

void dumpMsg(Uint8List b, {String pfx = '', int depth = 0}) {
  if (depth > 5) { print('${pfx}...'); return; }
  List<PbField> fields;
  try { fields = PbReader(b).readAll(); } catch (_) { print('${pfx}raw[${b.length}]: ${hex(b, 24)}'); return; }
  for (final f in fields) {
    if (f.wireType == PbWireType.varint) print('$pfx#${f.number} varint=${f.asInt}');
    else if (f.wireType == PbWireType.fixed32) print('$pfx#${f.number} f32=${f.asFloat32}');
    else if (f.wireType == PbWireType.lengthDelim) {
      final bytes = f.asBytes;
      try {
        final s = String.fromCharCodes(bytes);
        if (bytes.length < 200 && bytes.every((c) => c >= 32 || c == 10)) {
          print('$pfx#${f.number} text: "$s"'); continue;
        }
      } catch (_) {}
      print('$pfx#${f.number} bytes[${bytes.length}]');
      dumpMsg(bytes, pfx: '$pfx  ', depth: depth + 1);
    }
  }
}

Future<void> main(List<String> args) async {
  final notesFile = File(args[0]);
  final targetLamport = int.parse(args[1]);
  final data = notesFile.readAsBytesSync();
  final records = PbReader.readLengthPrefixedRecords(data);

  String? targetUuid;
  for (final rec in records) {
    List<PbField> fields;
    try { fields = PbReader(rec).readAll(); } catch (_) { continue; }
    final lam = fields.where((f) => f.number == 9 && f.wireType == PbWireType.varint).firstOrNull?.asInt;
    if (lam != targetLamport) continue;
    targetUuid = fields.where((f) => f.number == 1 && f.wireType == PbWireType.lengthDelim).firstOrNull?.asString;
    print('UUID: $targetUuid  opType=${fields.where((f)=>f.number==2&&f.wireType==PbWireType.lengthDelim).firstOrNull?.asMessage.grouped()[1]?.first.asInt}');
    break;
  }
  if (targetUuid == null) { print('not found'); return; }

  for (final rec in records) {
    List<PbField> outerFields;
    try { outerFields = PbReader(rec).readAll(); } catch (_) { continue; }
    for (final of in outerFields) {
      if (of.wireType != PbWireType.lengthDelim) continue;
      try {
        final inner = of.asMessage.grouped();
        final u = inner[1]?.first;
        if (u == null || u.wireType != PbWireType.lengthDelim || u.asString != targetUuid) continue;
        final bodyBytes = of.asBytes;
        print('Body ${bodyBytes.length} bytes:');
        dumpMsg(bodyBytes, pfx: '  ');
        // Check for bv41
        for (var i = 0; i + 4 <= bodyBytes.length; i++) {
          if (bodyBytes[i]==0x62&&bodyBytes[i+1]==0x76&&bodyBytes[i+2]==0x34&&bodyBytes[i+3]==0x31) {
            print('\n  bv41 at $i:');
            final inf = Bv41.decode(bodyBytes, i);
            print('  inflated ${inf.length} bytes: ${hex(inf)}');
            dumpMsg(inf, pfx: '    ');
          }
        }
        return;
      } catch (_) { continue; }
    }
  }
}
