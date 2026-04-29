import 'dart:typed_data';
import 'package:goodnotes_parser/goodnotes_parser.dart';
import 'package:test/test.dart';

void main() {
  test('lz4 block: simple literal-only frame', () {
    // token 0x40 → literal=4, match=0; literal "abcd"; final sequence has no
    // match per LZ4 spec → decoder must stop after literals.
    final src = Uint8List.fromList([0x40, 0x61, 0x62, 0x63, 0x64]);
    final out = lz4BlockDecode(src, expectedLen: 4);
    expect(out, equals([0x61, 0x62, 0x63, 0x64]));
  });

  test('lz4 block: extended literal length', () {
    // token = 0xf0 (lit=15, match=0). Need extra length byte.
    // lit_extra=1 → total literal = 15 + 1 = 16.
    final src = Uint8List.fromList([
      0xf0, 0x01, // token + extra-length
      ...List.generate(16, (i) => 0x41 + i),
    ]);
    final out = lz4BlockDecode(src, expectedLen: 16);
    expect(out.length, 16);
    expect(out.first, 0x41);
    expect(out.last, 0x50);
  });

  test('bv41 magic detection', () {
    final not = Uint8List.fromList([0x00, 0x01, 0x02, 0x03]);
    expect(Bv41.isContainer(not), isFalse);
    final yes = Uint8List.fromList(
        [0x62, 0x76, 0x34, 0x31, 0, 0, 0, 0, 0, 0, 0, 0]);
    expect(Bv41.isContainer(yes), isTrue);
  });
}
