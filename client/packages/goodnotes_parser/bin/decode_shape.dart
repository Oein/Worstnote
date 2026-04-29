// Find distinct shape schemas across all unknown elements.
import 'dart:typed_data';
import 'package:goodnotes_parser/goodnotes_parser.dart';
import 'package:goodnotes_parser/src/model.dart';
import 'package:goodnotes_parser/src/bv41.dart';

Future<void> main(List<String> args) async {
  final doc = args[0].endsWith('.goodnotes')
      ? await GoodNotesDocument.openFile(args[0])
      : await GoodNotesDocument.openDirectory(args[0]);
  final byKey = <String, int>{};
  final samples = <String, UnknownElement>{};
  for (var pi = 0; pi < doc.pages.length; pi++) {
    for (final u in doc.pages[pi].elements.whereType<UnknownElement>()) {
      var off = -1;
      for (var i = 0; i + 4 <= u.rawBody.length; i++) {
        if (u.rawBody[i] == 0x62 && u.rawBody[i+1] == 0x76 &&
            u.rawBody[i+2] == 0x34 && u.rawBody[i+3] == 0x31) {
          off = i; break;
        }
      }
      if (off < 0) {
        final k = 'op=${u.opType}/no-bv41';
        byKey[k] = (byKey[k] ?? 0) + 1;
        samples[k] ??= u;
        continue;
      }
      Uint8List inflated;
      try { inflated = Bv41.decode(u.rawBody, off); } catch (_) { continue; }
      var k = 8;
      const allowed = 'vufiSAd()';
      while (k < inflated.length && allowed.codeUnits.contains(inflated[k])) {
        k++;
      }
      final schema = String.fromCharCodes(inflated.sublist(8, k));
      // shape type is uint16 LE at body[1..2]
      int? stype;
      if (inflated.length > k + 3) {
        stype = inflated[k + 1] | (inflated[k + 2] << 8);
      }
      final key = 'op=${u.opType}/v$stype/$schema';
      byKey[key] = (byKey[key] ?? 0) + 1;
      samples[key] ??= u;
    }
  }
  for (final e in byKey.entries) {
    print('${e.value.toString().padLeft(4)}  ${e.key}');
  }
}
