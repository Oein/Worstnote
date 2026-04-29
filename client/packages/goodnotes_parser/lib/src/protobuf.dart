import 'dart:convert';
import 'dart:typed_data';

/// Protobuf wire types (subset used by GoodNotes).
enum PbWireType { varint, fixed64, lengthDelim, fixed32 }

/// One decoded protobuf field.
class PbField {
  final int number;
  final PbWireType wireType;
  /// Raw value:
  ///  - varint     : `int` (Dart int = 64-bit signed, treat as unsigned via mask)
  ///  - fixed64    : `int` (raw 64-bit signed)
  ///  - fixed32    : `int` (raw 32-bit signed; cast to float via [asFloat32])
  ///  - lengthDelim: `Uint8List`
  final Object value;

  PbField(this.number, this.wireType, this.value);

  int get asInt => value as int;
  double get asFloat32 {
    final bd = ByteData(4)..setInt32(0, value as int, Endian.little);
    return bd.getFloat32(0, Endian.little);
  }
  double get asDouble {
    final bd = ByteData(8)..setInt64(0, value as int, Endian.little);
    return bd.getFloat64(0, Endian.little);
  }
  Uint8List get asBytes => value as Uint8List;
  String get asString => utf8.decode(value as Uint8List, allowMalformed: true);
  PbReader get asMessage => PbReader(value as Uint8List);
}

/// Read protobuf wire format. Schema-less (no `.proto` needed).
class PbReader {
  final Uint8List data;
  int _pos = 0;
  PbReader(this.data);

  bool get hasMore => _pos < data.length;

  /// Iterate every field. Returns null when the buffer is exhausted.
  PbField? next() {
    if (!hasMore) return null;
    final tag = _readVarint();
    final wt = tag & 7;
    final fn = tag >> 3;
    if (fn == 0) {
      throw FormatException('pb: invalid field number 0 at $_pos');
    }
    switch (wt) {
      case 0:
        return PbField(fn, PbWireType.varint, _readVarint());
      case 1:
        final raw = ByteData.sublistView(data, _pos, _pos + 8)
            .getInt64(0, Endian.little);
        _pos += 8;
        return PbField(fn, PbWireType.fixed64, raw);
      case 2:
        final ln = _readVarint();
        final bytes = Uint8List.sublistView(data, _pos, _pos + ln);
        _pos += ln;
        return PbField(fn, PbWireType.lengthDelim, bytes);
      case 5:
        final raw = ByteData.sublistView(data, _pos, _pos + 4)
            .getInt32(0, Endian.little);
        _pos += 4;
        return PbField(fn, PbWireType.fixed32, raw);
      default:
        throw FormatException('pb: unsupported wire type $wt for #$fn');
    }
  }

  /// Decode all fields into a flat list.
  List<PbField> readAll() {
    final out = <PbField>[];
    while (true) {
      final f = next();
      if (f == null) break;
      out.add(f);
    }
    return out;
  }

  /// Group fields by number. Repeated fields → list of values.
  Map<int, List<PbField>> grouped() {
    final m = <int, List<PbField>>{};
    for (final f in readAll()) {
      m.putIfAbsent(f.number, () => []).add(f);
    }
    return m;
  }

  int _readVarint() {
    var r = 0;
    var s = 0;
    while (true) {
      final b = data[_pos++];
      r |= (b & 0x7f) << s;
      if ((b & 0x80) == 0) return r;
      s += 7;
      if (s > 70) throw const FormatException('pb: varint too long');
    }
  }

  /// Parse a stream of (varint length + message) records.
  static List<Uint8List> readLengthPrefixedRecords(Uint8List data) {
    final out = <Uint8List>[];
    var i = 0;
    while (i < data.length) {
      var ln = 0;
      var s = 0;
      while (true) {
        final b = data[i++];
        ln |= (b & 0x7f) << s;
        if ((b & 0x80) == 0) break;
        s += 7;
      }
      if (i + ln > data.length) {
        throw FormatException('pb: record length $ln overruns buffer');
      }
      out.add(Uint8List.sublistView(data, i, i + ln));
      i += ln;
    }
    return out;
  }
}
