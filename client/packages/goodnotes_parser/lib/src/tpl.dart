import 'dart:typed_data';

/// One stroke point. For highlighter ([TplPayload.strokeType] == 2) only
/// `x` and `y` are meaningful. For pens, `azimuth`/`altitude`/`time` carry
/// pen tilt and timestamp.
class TplPoint {
  final double x;
  final double y;
  final double azimuth;
  final double altitude;
  final double time;
  TplPoint(this.x, this.y,
      {this.azimuth = 0.0, this.altitude = 0.0, this.time = 0.0});

  @override
  String toString() => 'TplPoint($x, $y)';
}

/// One bezier segment.
///
/// - **Highlighter (4 floats)**: `(end_x, end_y, ctrl_x, ctrl_y)` — a
///   quadratic bezier from the previous point.
/// - **Pen (11 floats)**: `(delta, end_x, end_y, az, alt, t, mid_x, mid_y,
///   az2, alt2, t2)` — the segment's endpoint sits at indices 1, 2.
class TplSegment {
  final List<double> values;
  TplSegment(this.values);

  /// Endpoint X — adapts to highlighter (4 float) vs pen (11 float).
  double get x => values.length == 4 ? values[0] : values[1];
  /// Endpoint Y — adapts to highlighter (4 float) vs pen (11 float).
  double get y => values.length == 4 ? values[1] : values[2];

  @override
  String toString() => 'TplSegment(${values.length} floats)';
}

/// Decoded TPL payload (the body inside a `bv41` stroke container).
class TplPayload {
  /// 1 = pen, 2 = highlighter, 5 = special. Other values may exist.
  final int strokeType;

  /// Stroke base width in page points (1 pt = 1/72 in).
  final double width;

  /// Per-sample pressure as raw uint16 (0 = none, 0xffff = max).
  final List<int> pressures;

  /// Anchor point(s). Usually exactly one — the start of the stroke.
  final List<TplPoint> anchors;

  /// Bezier segments — one per consecutive pair of original samples.
  /// Length is `pressures.length - 1` for the strokes observed.
  final List<TplSegment> segments;

  /// Schema string used to encode the payload (kept for debugging /
  /// round-trip).
  final String schema;

  /// Trailing tail bytes that follow the schema — usually 6 bytes
  /// (`01 00 00 00 00 00`).
  final Uint8List trailer;

  TplPayload({
    required this.strokeType,
    required this.width,
    required this.pressures,
    required this.anchors,
    required this.segments,
    required this.schema,
    required this.trailer,
  });

  /// True if this is a highlighter / marker (no pressure curve).
  bool get isHighlighter => strokeType == 2;

  /// Number of original points (= pressures.length).
  int get pointCount => pressures.length;

  @override
  String toString() =>
      'TplPayload(type=$strokeType, width=$width, points=$pointCount)';

  static const _magic = [0x74, 0x70, 0x6c, 0x00]; // "tpl\0"

  /// True if [data] looks like a tpl\0 container (post-bv41-inflate).
  static bool isContainer(Uint8List data) {
    if (data.length < 8) return false;
    for (var i = 0; i < 4; i++) {
      if (data[i] != _magic[i]) return false;
    }
    return true;
  }

  /// Decode an inflated TPL payload. Throws [FormatException] on
  /// malformed input.
  factory TplPayload.decode(Uint8List data) {
    if (!isContainer(data)) {
      throw const FormatException('tpl: missing magic');
    }
    final bd = ByteData.sublistView(data);
    final declared = bd.getUint32(4, Endian.little);
    if (declared != data.length) {
      // Not strictly fatal — some pads have trailing zeros — but worth knowing.
    }
    // schema: ASCII chars in [vufiSAd()] until first non-grammar byte
    var k = 8;
    while (k < data.length) {
      final c = data[k];
      const allowed = 'vufiSAd()';
      if (allowed.codeUnits.contains(c)) {
        k++;
        continue;
      }
      break;
    }
    final schema = String.fromCharCodes(data.sublist(8, k));
    final body = data.sublist(k);
    return _parseBody(schema, body);
  }

  static TplPayload _parseBody(String schema, Uint8List body) {
    final bd = ByteData.sublistView(body);
    var i = 0;

    // --- shared header (all observed strokes) ---
    // First byte ALWAYS 0x00, then uint16 LE = stroke type, then float32 LE = width.
    // (This matches encoding `v u` where v=2B uint16 read across bytes 0..1
    // semantically representing the type, and u=4B float for width.)
    //
    // Important: byte 0 is the high byte of the uint16, but the observed
    // encoding stores the type in byte 1 with byte 0 = 0x00, so reading the
    // u16 LE and ignoring its top byte recovers the type (1, 2, 5).
    final reserved0 = body[i]; // expect 0x00
    i += 1;
    final strokeType = bd.getUint16(i, Endian.little);
    i += 2;
    final width = bd.getFloat32(i, Endian.little);
    i += 4;

    // --- A(v) pressures ---
    final pCount = bd.getUint32(i, Endian.little);
    i += 4;
    final pressures = List<int>.generate(pCount, (_) {
      final v = bd.getUint16(i, Endian.little);
      i += 2;
      return v;
    });

    // --- A(S(uu...)) anchors ---
    final isPen = schema.contains('S(uuuuu)');
    final anchorFloatCount = isPen ? 5 : 2;
    final aCount = bd.getUint32(i, Endian.little);
    i += 4;
    final anchors = <TplPoint>[];
    for (var a = 0; a < aCount; a++) {
      final fs = List<double>.generate(anchorFloatCount, (_) {
        final v = bd.getFloat32(i, Endian.little);
        i += 4;
        return v;
      });
      anchors.add(TplPoint(
        fs[0],
        fs[1],
        azimuth: anchorFloatCount > 2 ? fs[2] : 0.0,
        altitude: anchorFloatCount > 3 ? fs[3] : 0.0,
        time: anchorFloatCount > 4 ? fs[4] : 0.0,
      ));
    }

    // --- A(S(uuuu...)) bezier segments ---
    final segFloatCount = isPen ? 11 : 4;
    final sCount = bd.getUint32(i, Endian.little);
    i += 4;
    final segments = <TplSegment>[];
    for (var s = 0; s < sCount; s++) {
      final fs = List<double>.generate(segFloatCount, (_) {
        final v = bd.getFloat32(i, Endian.little);
        i += 4;
        return v;
      });
      segments.add(TplSegment(fs));
    }

    // --- Trailing optional empty arrays + tail (we don't strictly need
    // them, but advance past so trailer length is reported correctly). ---
    final trailer = body.sublist(i);

    if (reserved0 != 0) {
      // not fatal, but useful in debug
    }
    return TplPayload(
      strokeType: strokeType,
      width: width,
      pressures: pressures,
      anchors: anchors,
      segments: segments,
      schema: schema,
      trailer: trailer,
    );
  }

  /// Convenience: get all stroke points (anchors + segment endpoints) as
  /// `(x, y)` pairs in draw order. Useful for rendering a quick polyline
  /// approximation in a target app that doesn't support beziers.
  List<TplPoint> flatPoints() {
    final out = <TplPoint>[];
    out.addAll(anchors);
    for (final s in segments) {
      out.add(TplPoint(s.x, s.y));
    }
    return out;
  }
}
