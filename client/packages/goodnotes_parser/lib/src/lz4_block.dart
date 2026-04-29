import 'dart:typed_data';

/// Decode an LZ4 block-format byte sequence (no frame, no checksum).
///
/// `expectedLen` is optional — when supplied, the decoder stops as soon as
/// that many output bytes are produced (matches what GoodNotes' `bv41`
/// containers carry as `srcLen`).
Uint8List lz4BlockDecode(Uint8List src, {int? expectedLen}) {
  final out = <int>[]; // growable so overlap-copy can self-reference
  var i = 0;
  final n = src.length;
  while (i < n) {
    final token = src[i++];
    var litLen = token >> 4;
    if (litLen == 15) {
      while (true) {
        final b = src[i++];
        litLen += b;
        if (b != 255) break;
      }
    }
    for (var k = 0; k < litLen; k++) {
      out.add(src[i + k]);
    }
    i += litLen;
    if (i >= n) break; // last sequence has no match
    if (i + 2 > n) break;
    final offset = src[i] | (src[i + 1] << 8);
    i += 2;
    if (offset == 0) {
      throw const FormatException('lz4: zero match offset');
    }
    var matchLen = token & 0xf;
    if (matchLen == 15) {
      while (true) {
        final b = src[i++];
        matchLen += b;
        if (b != 255) break;
      }
    }
    matchLen += 4;
    final start = out.length - offset;
    for (var k = 0; k < matchLen; k++) {
      out.add(out[start + k]);
    }
    if (expectedLen != null && out.length >= expectedLen) break;
  }
  return Uint8List.fromList(out);
}
