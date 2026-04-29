import 'dart:io';
import 'dart:typed_data';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/bv41.dart';
import 'package:goodnotes_parser/src/tpl.dart';

Future<void> main(List<String> args) async {
  final notesFile = File(args[0]);
  final data = notesFile.readAsBytesSync();
  final records = PbReader.readLengthPrefixedRecords(data);

  final headByUuid = <String, (int opType, int lamport)>{};
  final bodyByUuid = <String, Uint8List>{};

  for (final rec in records) {
    List<PbField> fields;
    try { fields = PbReader(rec).readAll(); } catch (_) { continue; }
    final f1 = fields.where((f) => f.number == 1 && f.wireType == PbWireType.lengthDelim).firstOrNull;
    if (f1 != null && f1.asBytes.length == 36 && f1.asBytes[8] == 0x2d) {
      final has2 = fields.any((f) => f.number == 2 && f.wireType == PbWireType.lengthDelim);
      final has9 = fields.any((f) => f.number == 9 && f.wireType == PbWireType.varint);
      if (has2 && has9) {
        final f2 = fields.where((f) => f.number == 2 && f.wireType == PbWireType.lengthDelim).first;
        final m = f2.asMessage.grouped();
        final opType = m[1]?.first.asInt ?? -1;
        final lamport = fields.where((f) => f.number == 9 && f.wireType == PbWireType.varint).first.asInt;
        headByUuid[f1.asString] = (opType, lamport);
        continue;
      }
    }
    for (final f in fields) {
      if (f.wireType != PbWireType.lengthDelim) continue;
      try {
        final inner = f.asMessage.grouped();
        final innerOne = inner[1]?.first;
        if (innerOne == null || innerOne.wireType != PbWireType.lengthDelim) continue;
        final b = innerOne.asBytes;
        if (b.length != 36 || b[8] != 0x2d) continue;
        bodyByUuid[innerOne.asString] = f.asBytes;
        break;
      } catch (_) { continue; }
    }
  }

  for (final entry in headByUuid.entries) {
    final uuid = entry.key;
    final (opType, lamport) = entry.value;
    final bodyBytes = bodyByUuid[uuid];
    if (bodyBytes == null) continue;
    try {
      final offsets = _findBv41(bodyBytes);
      if (offsets.isEmpty) continue;
      final inflated = Bv41.decode(bodyBytes, offsets.first);
      final payload = TplPayload.decode(inflated);
      if (payload == null || payload.anchors.isEmpty) continue;
      final a = payload.anchors.first;
      final schema = payload.schema;
      final isSynth = schema == 'synthetic';
      final pts = payload.anchors.length + payload.segments.length;
      print('${uuid.substring(0,8)} op=$opType lam=$lamport synth=$isSynth pts=$pts start=(${a.x.toStringAsFixed(1)},${a.y.toStringAsFixed(1)})');
    } catch (_) {}
  }
}
List<int> _findBv41(Uint8List b) {
  final out = <int>[];
  for (var i = 0; i + 4 <= b.length; i++) {
    if (b[i] == 0x62 && b[i+1] == 0x76 && b[i+2] == 0x34 && b[i+3] == 0x31) out.add(i);
  }
  return out;
}
