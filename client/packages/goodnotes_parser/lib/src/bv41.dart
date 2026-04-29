import 'dart:typed_data';

import 'lz4_block.dart';

/// `bv41` container — GoodNotes' wrapper around LZ4-block-compressed data.
///
/// Layout:
/// ```
/// "bv41" (4)  | u32 LE srcLen | u32 LE dstLen | dstLen bytes payload
/// ```
class Bv41 {
  static final List<int> _magic = const [0x62, 0x76, 0x34, 0x31]; // "bv41"

  /// True if [data] starts with the bv41 magic.
  static bool isContainer(Uint8List data) {
    if (data.length < 4) return false;
    for (var i = 0; i < 4; i++) {
      if (data[i] != _magic[i]) return false;
    }
    return true;
  }

  /// Decompress a single bv41 container starting at [offset] inside [data].
  /// Returns the inflated payload.
  static Uint8List decode(Uint8List data, [int offset = 0]) {
    if (!isContainer(Uint8List.sublistView(data, offset))) {
      throw const FormatException('bv41: missing magic');
    }
    final bd = ByteData.sublistView(data, offset);
    final srcLen = bd.getUint32(4, Endian.little);
    final dstLen = bd.getUint32(8, Endian.little);
    final payload = Uint8List.sublistView(
      data,
      offset + 12,
      offset + 12 + dstLen,
    );
    return lz4BlockDecode(payload, expectedLen: srcLen);
  }

  /// Find every bv41 container inside [data] and decode all of them.
  /// Returns `(absoluteOffset, decompressedPayload)` pairs.
  static List<({int offset, Uint8List payload})> decodeAll(Uint8List data) {
    final out = <({int offset, Uint8List payload})>[];
    var i = 0;
    while (i + 12 <= data.length) {
      if (data[i] == _magic[0] &&
          data[i + 1] == _magic[1] &&
          data[i + 2] == _magic[2] &&
          data[i + 3] == _magic[3]) {
        try {
          final p = decode(data, i);
          out.add((offset: i, payload: p));
          // Skip past container header so we don't re-match inside compressed data.
          final dstLen = ByteData.sublistView(data, i)
              .getUint32(8, Endian.little);
          i += 12 + dstLen;
          continue;
        } catch (_) {
          // fallthrough; advance by 1
        }
      }
      i++;
    }
    return out;
  }
}
