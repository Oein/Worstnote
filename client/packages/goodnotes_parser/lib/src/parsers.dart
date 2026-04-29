/// Internal parsers for index/notes/search/events files.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'bv41.dart';
import 'model.dart';
import 'protobuf.dart';
import 'tpl.dart';

class IndexEntry {
  final String uuid;
  final String path;
  final int? flag;
  IndexEntry(this.uuid, this.path, [this.flag]);
}

List<IndexEntry> parseIndex(Uint8List data) {
  final out = <IndexEntry>[];
  for (final rec in PbReader.readLengthPrefixedRecords(data)) {
    String? uuid;
    String? path;
    int? flag;
    final r = PbReader(rec);
    while (true) {
      final f = r.next();
      if (f == null) break;
      if (f.number == 1) uuid = f.asString;
      if (f.number == 2) path = f.asString;
      if (f.number == 3 && f.wireType == PbWireType.varint) flag = f.asInt;
    }
    if (uuid != null && path != null) {
      out.add(IndexEntry(uuid, path, flag));
    }
  }
  return out;
}

/// Single-byte schema.pb is a varint version.
int parseSchemaVersion(Uint8List data) {
  final r = PbReader(data);
  while (true) {
    final f = r.next();
    if (f == null) break;
    if (f.number == 1 && f.wireType == PbWireType.varint) {
      return f.asInt;
    }
  }
  return 0;
}

/// Extract per-page background attachment IDs by scanning `index.events.pb`.
///
/// Returns the attachment IDs in the order PageCreate events appear. Pair
/// these with [parseIndex] entries from `index.notes.pb` (also in event
/// creation order) — non-blank pages on disk align with the events 1:1.
List<String> extractPageBackgroundAttachments(Uint8List eventsData) {
  final out = <String>[];
  for (final rec in PbReader.readLengthPrefixedRecords(eventsData)) {
    for (final f in PbReader(rec).readAll()) {
      if (f.wireType != PbWireType.lengthDelim) continue;
      // PageCreate event = top-level field #2. The inner sub-msg's #4 is
      // the attachment-key UUID for the page background.
      if (f.number == 2) {
        try {
          final m = f.asMessage.grouped();
          final ref = m[4]?.first;
          if (ref != null && ref.wireType == PbWireType.lengthDelim) {
            out.add(ref.asString);
          }
        } catch (_) {}
      }
    }
  }
  return out;
}

/// Best-effort document title extraction from `index.events.pb`.
/// We look at the first record's `#30 → #2 → #1` (string).
String? extractTitleFromEvents(Uint8List data) {
  for (final rec in PbReader.readLengthPrefixedRecords(data)) {
    final fields = PbReader(rec).readAll();
    for (final f in fields) {
      if (f.wireType != PbWireType.lengthDelim) continue;
      // recursively descend to find the first plausible UTF-8 string
      // located in #30/#2/#1
      if (f.number == 30) {
        final inner = f.asMessage.grouped();
        final two = inner[2]?.first;
        if (two != null && two.wireType == PbWireType.lengthDelim) {
          final innerTwo = two.asMessage.grouped();
          final one = innerTwo[1]?.first;
          if (one != null && one.wireType == PbWireType.lengthDelim) {
            return one.asString;
          }
        }
      }
    }
    // Title is in the first DocumentCreate event; bail early.
    break;
  }
  return null;
}

/// Parse a `notes/<UUID>` file into a [Page].
///
/// The page file is a stream of (varint length + protobuf message) records.
/// Records come in pairs: HEAD declares an element, BODY supplies geometry +
/// payload. We pair them by element-uuid match.
Page parseNotePage({
  required String pageId,
  required Uint8List data,
}) {
  List<Uint8List> records;
  try {
    records = PbReader.readLengthPrefixedRecords(data);
  } catch (_) {
    return Page(id: pageId, elements: const [], schemaVersion: 0);
  }
  final headByUuid = <String, _Head>{};
  final bodyByUuid = <String, Uint8List>{};
  String? backgroundAttachmentId;
  var schemaVersion = 0;

  for (final rec in records) {
    List<PbField> fields;
    try {
      fields = PbReader(rec).readAll();
    } catch (_) {
      continue; // skip malformed record
    }
    // HEAD: top-level field #1 is the element UUID (string), small (~105B).
    final fOne = fields.where((f) => f.number == 1).toList();
    if (fOne.isNotEmpty &&
        fOne.first.wireType == PbWireType.lengthDelim &&
        _looksLikeUuid(fOne.first.asBytes)) {
      // It's a HEAD if it carries #2 = {opType, hash} and #8 actor + #9 lamport.
      final has2 = fields.any((f) => f.number == 2 &&
          f.wireType == PbWireType.lengthDelim);
      final has9 = fields.any((f) => f.number == 9 &&
          f.wireType == PbWireType.varint);
      if (has2 && has9) {
        final h = _Head.fromFields(fields);
        if (h != null) {
          headByUuid[h.id] = h;
          if (h.refUuid != null) {
            backgroundAttachmentId ??= h.refUuid;
          }
          schemaVersion = h.schema > schemaVersion ? h.schema : schemaVersion;
          continue;
        }
      }
    }
    // BODY: top-level wraps a sub-message whose inner #1 is the element UUID.
    for (final f in fields) {
      if (f.wireType != PbWireType.lengthDelim) continue;
      try {
        final inner = f.asMessage.grouped();
        final innerOne = inner[1]?.first;
        if (innerOne == null) continue;
        if (innerOne.wireType != PbWireType.lengthDelim) continue;
        if (!_looksLikeUuid(innerOne.asBytes)) continue;
        bodyByUuid[innerOne.asString] = f.asBytes;
        break;
      } catch (_) {
        continue;
      }
    }
  }

  // Collect UUIDs that were explicitly created (any HEAD with opType != 3).
  // A text element with opType=3 and no prior create represents an uncommitted
  // IME edit that GoodNotes does not render. For strokes, opType=3 is a valid
  // content-create operation and must always be rendered.
  final createdUuids = <String>{};
  for (final rec in records) {
    List<PbField> fields;
    try { fields = PbReader(rec).readAll(); } catch (_) { continue; }
    final idField = fields.where(
        (f) => f.number == 1 && f.wireType == PbWireType.lengthDelim).firstOrNull;
    if (idField == null || !_looksLikeUuid(idField.asBytes)) continue;
    final opTypeField = fields.where(
        (f) => f.number == 2 && f.wireType == PbWireType.lengthDelim).firstOrNull;
    if (opTypeField == null) continue;
    final m = opTypeField.asMessage.grouped();
    final opType = m[1]?.first.asInt ?? -1;
    if (opType != 3) createdUuids.add(idField.asString);
  }

  // Scan all bodies (including those without a HEAD) for container bbox+fill.
  // When a TEXT element's body has field #6 = {field_1: containerUuid}, it
  // means the text is embedded inside a container frame (e.g. an inline
  // sticky-note box). We resolve the container's position and fill color and
  // apply them to the text element instead of the placeholder origin.
  final containerBodies = <String, Uint8List>{}; // containerUuid → bodyBytes
  final embeddedContainerOf = <String, String>{}; // elementUuid → containerUuid
  for (final bodyBytes in bodyByUuid.values) {
    _findContainerLink(bodyBytes, bodyByUuid, embeddedContainerOf,
        containerBodies);
  }

  final elements = <PageElement>[];
  // Iterate in head insertion order (= file order = lamport order).
  for (final h in headByUuid.values) {
    final bodyBytes = bodyByUuid[h.id];
    if (bodyBytes == null) {
      elements.add(UnknownElement(
        id: h.id,
        opType: h.opType,
        lamport: h.lamport,
        rawBody: Uint8List(0),
      ));
      continue;
    }
    var el = _classifyBody(h, bodyBytes);
    // op=5 STROKE = valid highlighter — keep.
    // op=5 TEXT = real annotation when text is non-empty and non-jamo — keep.
    // op=5 TEXT with empty/jamo text = eraser/undo marker — skip.
    // op=5 UnknownElement = skip.
    if (h.opType == 5) {
      if (el is StrokeElement) {
        // keep
      } else if (el is TextElement &&
          el.text.isNotEmpty &&
          !_isJamoOnly(el.text) &&
          !_containsJamo(el.text)) {
        // keep real text annotations (no isolated jamo = finished composition)
      } else {
        continue;
      }
    }
    // Drop any text element whose content contains isolated jamo — these are
    // always intermediate IME composition states (e.g. "형ㅈ"), regardless of
    // which opType produced them.
    if (el is TextElement && _containsJamo(el.text)) continue;
    // opType=3 (text update) with no prior create = uncommitted IME input,
    // BUT only when the text is jamo-only (incomplete Hangul syllable).
    // Full text that only has opType=3 records (e.g. created on another
    // device whose opType=2 was pruned) must still be rendered.
    if (el is TextElement && !createdUuids.contains(h.id) &&
        _isJamoOnly(el.text)) continue;

    // Apply container bbox/fill to embedded text elements.
    if (el is TextElement) {
      final containerUuid = embeddedContainerOf[h.id];
      if (containerUuid != null) {
        final cBody = containerBodies[containerUuid];
        if (cBody != null) {
          el = _applyContainerStyle(el, cBody);
        }
      }
    }

    elements.add(el);
  }

  // Container-level dedup: within each container, keep only the
  // highest-lamport non-empty child text element. This suppresses old/replaced
  // content when the user edited a sticky note (the most-recent lamport is the
  // current content; lower-lamport versions should not render).
  if (embeddedContainerOf.isNotEmpty) {
    final containerWinner = <String, int>{};
    for (final el in elements) {
      if (el is TextElement && el.text.isNotEmpty) {
        final cUuid = embeddedContainerOf[el.id];
        if (cUuid != null) {
          final prev = containerWinner[cUuid];
          if (prev == null || el.lamport > prev) containerWinner[cUuid] = el.lamport;
        }
      }
    }
    elements.removeWhere((el) {
      if (el is TextElement && el.text.isNotEmpty) {
        final cUuid = embeddedContainerOf[el.id];
        if (cUuid != null) return el.lamport < (containerWinner[cUuid] ?? 0);
      }
      return false;
    });
  }

  return Page(
    id: pageId,
    backgroundAttachmentId: backgroundAttachmentId,
    elements: elements,
    schemaVersion: schemaVersion == 0 ? 24 : schemaVersion,
  );
}

PageElement _classifyBody(_Head h, Uint8List bodyBytes) {
  Map<int, List<PbField>> body;
  try {
    body = PbReader(bodyBytes).grouped();
  } catch (_) {
    return UnknownElement(
      id: h.id, opType: h.opType, lamport: h.lamport,
      rawBody: bodyBytes,
    );
  }

  // Schema-31 body[3][1] flag: for TEXT elements all values are active.
  // For non-text schema-31 elements (shapes/strokes), flag=2 means deleted.
  final bodyTwo_s31 = body[2]?.first;
  if (bodyTwo_s31 != null && bodyTwo_s31.wireType == PbWireType.varint &&
      bodyTwo_s31.asInt == 31) {
    // Check flag
    int flag31 = 1;
    try {
      final f3 = body[3]?.first;
      if (f3 != null && f3.wireType == PbWireType.lengthDelim) {
        flag31 = f3.asMessage.grouped()[1]?.first.asInt ?? 1;
      }
    } catch (_) {}
    if (flag31 == 2) {
      // Connector/line shapes (body[21] with coordinate points) have flag=2
      // to indicate the line cap style, NOT deletion — let them fall through.
      final hasConnectorPoints = body.containsKey(21) &&
          !(body.containsKey(20));
      if (!hasConnectorPoints) {
        // Only keep if it has bv41 text content — text elements with flag=2
        // are valid student annotations; other shapes/strokes with flag=2 are
        // deleted.
        bool hasText = false;
        for (var i = 0; i + 4 <= bodyBytes.length; i++) {
          if (bodyBytes[i] == 0x62 && bodyBytes[i+1] == 0x76 &&
              bodyBytes[i+2] == 0x34 && bodyBytes[i+3] == 0x31) {
            try {
              final inf = Bv41.decode(bodyBytes, i);
              if (inf.isNotEmpty && inf[0] == 0x0a) { hasText = true; break; }
            } catch (_) {}
          }
        }
        if (!hasText) {
          return UnknownElement(
              id: h.id, opType: h.opType, lamport: h.lamport,
              rawBody: bodyBytes);
        }
      }
    }
  }

  BBox? bbox;
  // 1) Stroke / general element: BBox at #2 = { TopLeft, BotRight }.
  final two = body[2]?.first;
  if (two != null && two.wireType == PbWireType.lengthDelim) {
    try { bbox = _readBBox(two.asMessage); } catch (_) {}
  }
  // 2) Text-box body (top-level #21 wrapper): origin at #20.#1.{x,y}; size
  //    at #21.#2.{w,h}. Compute the resulting BBox.
  if (bbox == null) {
    final originField = body[20]?.first;
    final sizeField = body[21]?.first;
    if (originField != null &&
        originField.wireType == PbWireType.lengthDelim) {
      try {
        final origin = originField.asMessage.grouped();
        final p = origin[1]?.first;
        if (p != null && p.wireType == PbWireType.lengthDelim) {
          final pm = p.asMessage.grouped();
          final ox = pm[1]?.first.asFloat32;
          final oy = pm[2]?.first.asFloat32;
          double w = 0, hgt = 0;
          if (sizeField != null &&
              sizeField.wireType == PbWireType.lengthDelim) {
            final sz = sizeField.asMessage.grouped();
            final sub = sz[2]?.first;
            if (sub != null && sub.wireType == PbWireType.lengthDelim) {
              final sm = sub.asMessage.grouped();
              w = sm[1]?.first.asFloat32 ?? 0;
              hgt = sm[2]?.first.asFloat32 ?? 0;
            }
          }
          if (ox != null && oy != null) {
            final fw = w.isFinite && w > 0 ? w : 200.0;
            final fh = hgt.isFinite && hgt > 0 ? hgt : 32.0;
            bbox = BBox(ox, oy, ox + fw, oy + fh);
          }
        }
      } catch (_) {}
    }
  }

  // Color #4 (RGBA float quad)
  Color4? color;
  final four = body[4]?.first;
  if (four != null && four.wireType == PbWireType.lengthDelim) {
    try { color = _readRGBA(four.asMessage); } catch (_) {}
  }

  // Stroke width #15 — sometimes f32, sometimes a Version sub-message.
  double? width;
  final fifteen = body[15]?.first;
  if (fifteen != null) {
    if (fifteen.wireType == PbWireType.fixed32) {
      width = fifteen.asFloat32;
    }
  }

  // The text-content sub-message at #32 carries:
  //  • #32.#2 = (textWidth, lineHeight)  — the rendered text block size,
  //    used when the explicit font-size field is the -404 sentinel.
  //  • #32.#10 = (top, right, bottom, left) — content insets (padding)
  //    around the text inside its frame. Default is (10, 10, 10, 10).
  double? renderedLineHeight;
  double padTop = 0, padLeft = 0;
  final f32 = body[32]?.first;
  if (f32 != null && f32.wireType == PbWireType.lengthDelim) {
    try {
      final m32 = f32.asMessage.grouped();
      final two = m32[2]?.first;
      if (two != null && two.wireType == PbWireType.lengthDelim) {
        final p = two.asMessage.grouped();
        final h = p[2]?.first;
        if (h != null && h.wireType == PbWireType.fixed32) {
          final v = h.asFloat32;
          if (v.isFinite && v > 4 && v < 200) renderedLineHeight = v;
        }
      }
      final ten = m32[10]?.first;
      if (ten != null && ten.wireType == PbWireType.lengthDelim) {
        final p = ten.asMessage.grouped();
        final t = p[1]?.first;
        final l = p[4]?.first;
        if (t != null && t.wireType == PbWireType.fixed32) {
          final v = t.asFloat32;
          if (v.isFinite && v >= 0 && v < 200) padTop = v;
        }
        if (l != null && l.wireType == PbWireType.fixed32) {
          final v = l.asFloat32;
          if (v.isFinite && v >= 0 && v < 200) padLeft = v;
        }
      }
    } catch (_) {}
  }
  // Shift bbox by the (left, top) padding so origin lands on the actual
  // visible text top-left rather than the outer frame top-left.
  if (bbox != null && (padTop > 0 || padLeft > 0)) {
    bbox = BBox(bbox.minX + padLeft, bbox.minY + padTop,
        bbox.maxX + padLeft, bbox.maxY + padTop);
  }

  // body[30] = background fill: body[30][1][1]{#1:R,#2:G,#3:B} (fixed32).
  // body[33][1][4] = corner radius (fixed32).
  Color4? fillColor;
  double cornerRadius = 0;
  final f30 = body[30]?.first;
  if (f30 != null && f30.wireType == PbWireType.lengthDelim) {
    try {
      final m30 = f30.asMessage.grouped();                   // body[30]
      final f30_1 = m30[1]?.first;                          // body[30][1]
      if (f30_1 != null && f30_1.wireType == PbWireType.lengthDelim) {
        final m30_1 = f30_1.asMessage.grouped();             // body[30][1]
        final f30_1_1 = m30_1[1]?.first;                    // body[30][1][1]
        if (f30_1_1 != null && f30_1_1.wireType == PbWireType.lengthDelim) {
          final rgb = f30_1_1.asMessage.grouped();           // body[30][1][1]
          final r = rgb[1]?.first?.asFloat32 ?? 0;
          final g = rgb[2]?.first?.asFloat32 ?? 0;
          final b = rgb[3]?.first?.asFloat32 ?? 0;
          if (r.isFinite && g.isFinite && b.isFinite) {
            fillColor = Color4(r, g, b, 1.0);
          }
        }
      }
    } catch (_) {}
  }
  final f33 = body[33]?.first;
  if (f33 != null && f33.wireType == PbWireType.lengthDelim) {
    try {
      final m33 = f33.asMessage.grouped();
      final crField = m33[1]?.first;
      if (crField != null && crField.wireType == PbWireType.lengthDelim) {
        final crMsg = crField.asMessage.grouped();
        final v = crMsg[4]?.first?.asFloat32 ?? 0;
        if (v.isFinite && v > 0 && v < 200) cornerRadius = v;
      }
    } catch (_) {}
  }

  // Look for a bv41 inside the body; classify by inner first byte.
  TplPayload? tpl;
  TextElement? maybeText;
  ({TplPayload payload, double? width})? shapeFromTpl;
  for (final off in _findAllBv41(bodyBytes)) {
    try {
      final inflated = Bv41.decode(bodyBytes, off);
      if (TplPayload.isContainer(inflated)) {
        try {
          tpl ??= TplPayload.decode(inflated);
        } catch (_) {
          shapeFromTpl ??= _decodeShapeTpl(inflated);
        }
      } else if (inflated.isNotEmpty && inflated.first == 0x0a) {
        maybeText ??= _decodeTextBox(h, inflated, bbox: bbox,
            lineHeight: renderedLineHeight,
            fillColor: fillColor, cornerRadius: cornerRadius);
      }
    } catch (_) {
      // ignore
    }
  }

  if (maybeText != null) return maybeText;
  // Only do the early return if the payload actually has anchor points.
  // Strokes with anchors.isEmpty have their real points in body[9] (newer
  // format); fall through to the body[9] decoder below.
  if (tpl != null && tpl.anchors.isNotEmpty) {
    return StrokeElement(
      id: h.id,
      opType: h.opType,
      lamport: h.lamport,
      bbox: bbox,
      color: color ?? const Color4(0, 0, 0, 1),
      width: width ?? tpl.width,
      payload: tpl,
      arrowEnd: _readArrowTypeConnector(body),
    );
  }
  // Old shape-tpl (highlighter tape / underline / arrow): single element
  // contains multiple disconnected sub-paths; the renderer breaks them up
  // by distance jumps.
  if (shapeFromTpl != null) {
    final p = shapeFromTpl.payload;
    return StrokeElement(
      id: h.id,
      opType: h.opType,
      lamport: h.lamport,
      bbox: bbox ?? _bboxFromPoints(p),
      color: color ?? const Color4(1, 1, 0, 0.4),
      width: width ?? shapeFromTpl.width ?? p.width,
      payload: p,
    );
  }
  // Body[9] newer stroke format: points stored as indexed sub-fields of #9>#2.
  // Used when the bv41 TplPayload has zero anchors (the actual point data
  // lives here instead of in the compressed blob).
  if (tpl == null || tpl.anchors.isEmpty) {
    final f9 = body[9]?.first;
    if (f9 != null && f9.wireType == PbWireType.lengthDelim) {
      try {
        final m9 = f9.asMessage.grouped();
        final f9_2 = m9[2]?.first;
        if (f9_2 != null && f9_2.wireType == PbWireType.lengthDelim) {
          final allPtFields = PbReader(f9_2.asBytes).readAll();
          final pts = <TplPoint>[];
          for (final pf in allPtFields) {
            if (pf.wireType != PbWireType.lengthDelim) continue;
            final pm = pf.asMessage.grouped();
            final x = pm[1]?.first.asFloat32;
            final y = pm[2]?.first.asFloat32;
            if (x != null && y != null) pts.add(TplPoint(x, y));
          }
          if (pts.length >= 2) {
            double w = width ?? 1.0;
            final f9_15 = m9[15]?.first;
            if (f9_15 != null && f9_15.wireType == PbWireType.fixed32) {
              final v = f9_15.asFloat32;
              if (v.isFinite && v > 0 && v < 200) w = v;
            }
            final segs = <TplSegment>[];
            for (var i = 1; i < pts.length; i++) {
              segs.add(TplSegment(
                  [pts[i].x, pts[i].y, pts[i].x, pts[i].y]));
            }
            final p9 = TplPayload(
              strokeType: 1,
              width: w,
              pressures: List<int>.filled(pts.length, 0xffff),
              anchors: [pts.first],
              segments: segs,
              schema: 'body9',  // coords already in canvas pixel space
              trailer: Uint8List(0),
            );
            return StrokeElement(
              id: h.id, opType: h.opType, lamport: h.lamport,
              bbox: bbox ?? _bboxFromPoints(p9),
              color: color ?? const Color4(0, 0, 0, 1),
              width: w, payload: p9,
            );
          }
        }
      } catch (_) {}
    }
  }

  // Fallback: bv41 TplPayload existed but had no points (empty-anchor stub).
  if (tpl != null) {
    return StrokeElement(
      id: h.id, opType: h.opType, lamport: h.lamport,
      bbox: bbox,
      color: color ?? const Color4(0, 0, 0, 1),
      width: width ?? tpl.width,
      payload: tpl,
    );
  }

  // Schema-31 polyline shape: points in #20, style in #32. No bv41.
  final polyline = _decodePolylineShape(body, fallbackColor: color);
  if (polyline != null) {
    return StrokeElement(
      id: h.id,
      opType: h.opType,
      lamport: h.lamport,
      bbox: bbox ?? _bboxFromPoints(polyline.payload),
      color: polyline.color,
      width: polyline.width,
      payload: polyline.payload,
      arrowEnd: _readArrowType(body),
    );
  }
  // Any element with a ref_uuid + bbox that isn't a stroke or text is an
  // INLINE image (PNG/PDF) embedded on the page. The op_type varies (9
  // observed, but other values exist for cover-page maps etc).
  if (h.refUuid != null && bbox != null) {
    return ImageElement(
      id: h.id,
      opType: h.opType,
      lamport: h.lamport,
      bbox: bbox,
      attachmentId: h.refUuid!,
    );
  }
  return UnknownElement(
    id: h.id,
    opType: h.opType,
    lamport: h.lamport,
    bbox: bbox,
    rawBody: bodyBytes,
  );
}

TextElement? _decodeTextBox(_Head h, Uint8List inflated,
    {BBox? bbox, double? lineHeight,
     Color4? fillColor, double cornerRadius = 0}) {
  try {
    final outer = PbReader(inflated).grouped();
    // GoodNotes stores each paragraph as a separate #1 sub-message.
    // Read ALL of them and join their text content.
    final paragraphs = outer[1] ?? <PbField>[];
    if (paragraphs.isEmpty) return null;

    final textParts = <String>[];
    Color4 color = const Color4(0, 0, 0, 1);
    double size = 0; // sentinel: not set
    double? letter;

    for (final para in paragraphs) {
      if (para.wireType != PbWireType.lengthDelim) continue;
      final m = para.asMessage.grouped();
      final paraText = m[1]?.first.asString ?? '';
      if (paraText.isNotEmpty) textParts.add(paraText);
      // Style comes from the first paragraph that declares it.
      if (size <= 0) {
        final style = m[2]?.first;
        if (style != null && style.wireType == PbWireType.lengthDelim) {
          final s = style.asMessage.grouped();
          final colorSub = s[3]?.first;
          if (colorSub != null && colorSub.wireType == PbWireType.lengthDelim) {
            color = _readRGBA(colorSub.asMessage) ?? color;
          }
          final sizeF = s[40]?.first;
          if (sizeF != null && sizeF.wireType == PbWireType.fixed32) {
            final v = sizeF.asFloat32;
            // GoodNotes uses sentinel like -404 for "default size"; ignore.
            if (v.isFinite && v > 0 && v < 200) size = v;
          }
          final spF = s[70]?.first;
          if (spF != null && spF.wireType == PbWireType.fixed32) {
            final v = spF.asFloat32;
            if (v.isFinite && v.abs() < 50) letter = v;
          }
        }
      }
    }
    final text = textParts.join('');
    // If the explicit font-size field was the sentinel, fall back to the
    // text-block's line-height. GoodNotes' default line-height is roughly
    // fontSize × 1.2, so divide by 1.2 to recover a plausible font-size.
    if (size <= 0 && lineHeight != null) {
      size = lineHeight / 1.2;
    }
    if (size <= 0) size = 16;
    return TextElement(
      id: h.id,
      opType: h.opType,
      lamport: h.lamport,
      bbox: bbox,
      text: text,
      color: color,
      fontSize: size,
      letterSpacing: letter,
      fillColor: fillColor,
      cornerRadius: cornerRadius,
    );
  } catch (_) {
    return null;
  }
}

BBox? _readBBox(PbReader r) {
  final m = r.grouped();
  final origin = m[1]?.first;
  final size = m[2]?.first;
  if (origin == null || size == null) return null;
  if (origin.wireType != PbWireType.lengthDelim ||
      size.wireType != PbWireType.lengthDelim) return null;
  final om = origin.asMessage.grouped();
  final sm = size.asMessage.grouped();
  final ox = om[1]?.first;
  final oy = om[2]?.first;
  final sw = sm[1]?.first;
  final sh = sm[2]?.first;
  if (ox == null || oy == null || sw == null || sh == null) return null;
  // body[2] stores origin (#1) + size-vector (#2).
  // The BBox spans from origin to origin+size.
  final x = ox.asFloat32, y = oy.asFloat32;
  final w = sw.asFloat32, h = sh.asFloat32;
  return BBox(x, y, x + w, y + h);
}

Color4? _readRGBA(PbReader r) {
  final m = r.grouped();
  final f1 = m[1]?.first;
  final f2 = m[2]?.first;
  final f3 = m[3]?.first;
  final f4 = m[4]?.first;
  if (f1 == null || f2 == null || f3 == null || f4 == null) return null;
  return Color4(f1.asFloat32, f2.asFloat32, f3.asFloat32, f4.asFloat32);
}

/// Returns true if every non-whitespace rune is a bare Hangul Jamo consonant
/// or vowel (U+1100–U+11FF Jamo, U+3130–U+318F Compatibility Jamo).
/// These appear when the user typed jamo in the IME but never completed a
/// syllable (i.e. the key-press was stored but the session was aborted).
bool _isJamoOnly(String s) {
  if (s.trim().isEmpty) return true;
  for (final r in s.runes) {
    if (r == 0x20 || r == 0x0a || r == 0x09) continue;
    if (r >= 0x1100 && r <= 0x11FF) continue; // Conjoining Jamo
    if (r >= 0x3130 && r <= 0x318F) continue; // Compatibility Jamo
    return false; // complete syllable, ASCII, etc. — keep the element
  }
  return true;
}

/// Returns true if the string contains ANY isolated jamo — an indicator
/// of an unfinished Korean syllable composition (e.g. "형ㅈ").
bool _containsJamo(String s) {
  for (final r in s.runes) {
    if (r >= 0x1100 && r <= 0x11FF) return true; // Conjoining Jamo
    if (r >= 0x3130 && r <= 0x318F) return true; // Compatibility Jamo
  }
  return false;
}

bool _looksLikeUuid(Uint8List b) {
  if (b.length != 36) return false;
  // crude check: dash positions
  return b[8] == 0x2d && b[13] == 0x2d && b[18] == 0x2d && b[23] == 0x2d;
}

List<int> _findAllBv41(Uint8List b) {
  final out = <int>[];
  for (var i = 0; i + 4 <= b.length; i++) {
    if (b[i] == 0x62 && b[i+1] == 0x76 && b[i+2] == 0x34 && b[i+3] == 0x31) {
      out.add(i);
      // skip past this container so we don't match inside its compressed
      // payload (best-effort; bounded read of dstLen)
      if (i + 12 <= b.length) {
        final dst = ByteData.sublistView(b, i)
            .getUint32(8, Endian.little);
        i += 12 + dst - 1; // -1 because loop ++ adds one
      }
    }
  }
  return out;
}

class _Head {
  final String id;
  final int opType;
  final int hash;
  final int lamport;
  final int actor;
  final int schema;
  final String? parentUuid;
  final String? refUuid;

  _Head({
    required this.id,
    required this.opType,
    required this.hash,
    required this.lamport,
    required this.actor,
    required this.schema,
    this.parentUuid,
    this.refUuid,
  });

  static _Head? fromFields(List<PbField> fields) {
    String? id;
    int? opType;
    int? hash;
    int? lamport;
    int actor = 0;
    int schema = 0;
    String? parent;
    String? ref;
    for (final f in fields) {
      switch (f.number) {
        case 1:
          if (f.wireType == PbWireType.lengthDelim) id = f.asString;
          break;
        case 2:
          if (f.wireType == PbWireType.lengthDelim) {
            final m = f.asMessage.grouped();
            opType = m[1]?.first.asInt;
            hash = m[2]?.first.asInt;
          }
          break;
        case 6:
          if (f.wireType == PbWireType.lengthDelim) parent = f.asString;
          break;
        case 7:
          if (f.wireType == PbWireType.lengthDelim) ref = f.asString;
          break;
        case 8:
          if (f.wireType == PbWireType.varint) actor = f.asInt;
          break;
        case 9:
          if (f.wireType == PbWireType.varint) lamport = f.asInt;
          break;
        case 16:
          if (f.wireType == PbWireType.varint) schema = f.asInt;
          break;
      }
    }
    if (id == null || opType == null || hash == null || lamport == null) {
      return null;
    }
    return _Head(
      id: id, opType: opType, hash: hash,
      lamport: lamport, actor: actor, schema: schema,
      parentUuid: parent, refUuid: ref,
    );
  }
}

/// Parse a `search/<UUID>` file. Returns a [SearchIndex].
SearchIndex parseSearchIndex({
  required String targetId,
  required bool forAttachment,
  required Uint8List data,
}) {
  final tokens = <SearchToken>[];
  final tokenStrings = <String>[];
  final layouts = <List<GlyphRun>>[];

  if (data.length < 2) {
    return SearchIndex(
      targetId: targetId, forAttachment: forAttachment, tokens: tokens,
    );
  }
  final r = PbReader(data);
  List<PbField> all;
  try {
    all = r.readAll();
  } catch (_) {
    return SearchIndex(
      targetId: targetId, forAttachment: forAttachment, tokens: tokens,
    );
  }

  for (final f in all) {
    if (f.number == 3 && f.wireType == PbWireType.lengthDelim) {
      final raw = f.asBytes;
      // tokens are either UTF-8 strings OR sub-messages with `#5` line hash
      if (_looksLikeText(raw)) {
        tokenStrings.add(_safeUtf8(raw));
      } else {
        // sub-message marker — keep as empty to preserve indexing
        tokenStrings.add('');
      }
    } else if (f.number == 4 && f.wireType == PbWireType.lengthDelim) {
      final runs = <GlyphRun>[];
      final m = f.asMessage.grouped();
      final twos = m[2] ?? const [];
      for (final g in twos) {
        if (g.wireType != PbWireType.lengthDelim) continue;
        final gm = g.asMessage.grouped();
        final off = gm[1]?.first.asInt ?? 0;
        final cnt = gm[2]?.first.asInt ?? 0;
        BBox? bbox;
        final bb = gm[3]?.first;
        if (bb != null && bb.wireType == PbWireType.lengthDelim) {
          bbox = _readBBox(bb.asMessage);
        }
        runs.add(GlyphRun(off, cnt, bbox));
      }
      layouts.add(runs);
    }
  }
  // Pair tokens with layouts in order.
  for (var i = 0; i < tokenStrings.length; i++) {
    final layout = i < layouts.length ? layouts[i] : const <GlyphRun>[];
    tokens.add(SearchToken(tokenStrings[i], layout));
  }
  return SearchIndex(
    targetId: targetId,
    forAttachment: forAttachment,
    tokens: tokens,
  );
}

bool _looksLikeText(Uint8List b) {
  if (b.isEmpty) return false;
  // try to decode; if mostly printable, accept.
  try {
    final s = _safeUtf8(b);
    if (s.isEmpty) return false;
    var good = 0;
    for (final r in s.runes) {
      // exclude obvious binary chars
      if (r >= 0x20 || r == 0x0a || r == 0x09) good++;
    }
    return good / s.runes.length > 0.85;
  } catch (_) {
    return false;
  }
}

// Decode a shape-tpl payload (bv41+tpl with the shape schema).
// Returns null if not a recognized shape schema.
({TplPayload payload, double? width})? _decodeShapeTpl(
    Uint8List inflated) {
  try {
    if (inflated.length < 12) return null;
    var k = 8;
    const allowed = 'vufiSAd()';
    while (k < inflated.length && allowed.contains(String.fromCharCode(inflated[k]))) {
      k++;
    }
    final schema = String.fromCharCodes(inflated.sublist(8, k));
    if (!schema.startsWith('vA(v)A(u)A(u)')) return null;
    final body = inflated.sublist(k);
    final bd = ByteData.sublistView(body);
    var i = 1; // skip reserved0
    final shapeType = bd.getUint16(i, Endian.little); i += 2;
    // Parse arrays in order. We only need a few of them.
    final tokens = _tokenizeSchema(schema).skip(1).toList(); // skip leading 'v'
    final arrays = <List<dynamic>>[];
    for (final t in tokens) {
      if (!t.startsWith('A(')) return null;
      final inner = t.substring(2, t.length - 1);
      final count = bd.getUint32(i, Endian.little); i += 4;
      final list = <dynamic>[];
      for (var c = 0; c < count; c++) {
        if (inner == 'v') {
          list.add(bd.getUint16(i, Endian.little)); i += 2;
        } else if (inner == 'u' || inner == 'f') {
          list.add(bd.getFloat32(i, Endian.little)); i += 4;
        } else if (inner == 'i') {
          list.add(bd.getUint32(i, Endian.little)); i += 4;
        } else {
          return null; // unsupported
        }
      }
      arrays.add(list);
    }
    // Width tends to live at array[1][2] (anchor: x, y, width, ?).
    double? width;
    if (arrays.length > 1 && arrays[1].length >= 3) {
      final w = arrays[1][2] as double;
      if (w.isFinite && w > 0 && w < 200) width = w;
    }
    // Dense (x, y) samples form the LONGEST even-length float array in
    // the payload. Other float arrays carry per-stroke metadata (transform
    // matrix, timing, anchor) and would render as nonsense if used as path
    // coordinates.
    List<double>? dense;
    for (final a in arrays) {
      if (a.isEmpty || a.first is! double) continue;
      if (a.length < 4 || a.length % 2 != 0) continue;
      if (dense == null || a.length > dense.length) {
        dense = a.cast<double>();
      }
    }
    if (dense == null || dense.isEmpty) return null;
    final points = <TplPoint>[];
    for (var p = 0; p + 1 < dense.length; p += 2) {
      points.add(TplPoint(dense[p], dense[p + 1]));
    }
    if (points.length < 2) return null;
    return (
      payload: _polylinePayload(points, width ?? 1.0, strokeType: shapeType),
      width: width,
    );
  } catch (_) {
    return null;
  }
}

List<String> _tokenizeSchema(String s) {
  final out = <String>[];
  var k = 0;
  while (k < s.length) {
    final c = s[k];
    if (c == 'A' || c == 'S') {
      if (k + 1 < s.length && s[k + 1] == '(') {
        var depth = 0;
        var j = k + 1;
        while (j < s.length) {
          if (s[j] == '(') depth++;
          else if (s[j] == ')') { depth--; if (depth == 0) break; }
          j++;
        }
        out.add(s.substring(k, j + 1));
        k = j + 1;
        continue;
      }
    }
    out.add(c);
    k++;
  }
  return out;
}

// Decode a polyline shape from body[20] or body[21] + body[32].
// body[20] uses: #1→{#1:point}, #2=[midpoints], #3→{#1:point}
// body[21] uses: #1→{#1:point}, #5→{#2:point}, #3→{#1:point}
({TplPayload payload, Color4 color, double width})? _decodePolylineShape(
    Map<int, List<PbField>> body, {Color4? fallbackColor}) {
  final f20 = body[20]?.first;
  final f21 = body[21]?.first;
  final f32 = body[32]?.first;
  if (f32 == null || f32.wireType != PbWireType.lengthDelim) return null;

  final bool use21 =
      (f20 == null || f20.wireType != PbWireType.lengthDelim) &&
      (f21 != null && f21.wireType == PbWireType.lengthDelim);
  final fPoints = use21 ? f21
      : (f20 != null && f20.wireType == PbWireType.lengthDelim ? f20 : null);
  if (fPoints == null) return null;

  final points = <TplPoint>[];
  try {
    final m = fPoints.asMessage.grouped();
    if (use21) {
      // #21 layout for connectors: all field-1 entries are sequential points,
      // each with inner structure {#1:{#1:x,#2:y}}.
      // Fallback classic layout: first=#1→{#1:pt}, mid=#5→{#2:pt},
      // last=#3→{#1:pt}.
      final field1List = m[1] ?? <PbField>[];
      for (final fw in field1List) {
        final pt = _readPointWrapper(fw, innerField: 1);
        if (pt != null) points.add(pt);
      }
      if (points.length < 2) {
        // Classic layout with mid-points in field[5] innerField=2
        for (final mw in m[5] ?? const <PbField>[]) {
          final mp = _readPointWrapper(mw, innerField: 2);
          if (mp != null) points.add(mp);
        }
        final lp = _readPointWrapper(m[3]?.first, innerField: 1);
        if (lp != null) points.add(lp);
      }
    } else {
      // #20 layout: first=#1→{#1:pt}, mid=#2=[pts], last=#3→{#1:pt}
      final fp = _readPointWrapper(m[1]?.first, innerField: 1);
      if (fp != null) points.add(fp);
      for (final mid in m[2] ?? const <PbField>[]) {
        if (mid.wireType != PbWireType.lengthDelim) continue;
        final pm = mid.asMessage.grouped();
        final x = pm[1]?.first.asFloat32;
        final y = pm[2]?.first.asFloat32;
        if (x != null && y != null) points.add(TplPoint(x, y));
      }
      final lp = _readPointWrapper(m[3]?.first, innerField: 1);
      if (lp != null) points.add(lp);
    }
  } catch (_) {
    return null;
  }
  if (points.length < 2) return null;
  // Filter degenerate near-zero-extent polylines (3-point editing carets
  // that show up as tiny vertical/horizontal blips inside text rows).
  {
    var minX = points.first.x, maxX = points.first.x;
    var minY = points.first.y, maxY = points.first.y;
    for (final p in points) {
      if (p.x < minX) minX = p.x;
      if (p.x > maxX) maxX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.y > maxY) maxY = p.y;
    }
    if ((maxX - minX) < 5 && (maxY - minY) < 80) return null;
    if ((maxY - minY) < 5 && (maxX - minX) < 80) return null;
  }
  // Filter out doodle/lasso polylines that backtrack significantly. Clean
  // connector arrows / curves have path-length ≈ straight-line distance;
  // a freeform doodle traces 2× or more its endpoint distance.
  if (points.length > 4) {
    var pathLen = 0.0;
    for (var i = 1; i < points.length; i++) {
      final ddx = points[i].x - points[i - 1].x;
      final ddy = points[i].y - points[i - 1].y;
      pathLen += math.sqrt(ddx * ddx + ddy * ddy);
    }
    final dx = points.last.x - points.first.x;
    final dy = points.last.y - points.first.y;
    final straightLen = math.sqrt(dx * dx + dy * dy);
    if (straightLen < 1 || pathLen / straightLen > 2.0) {
      return null;
    }
  }

  double width = 1.0;
  Color4 color = fallbackColor ?? const Color4(0, 0, 0, 1);
  try {
    final m = f32.asMessage.grouped();
    final w = m[1]?.first;
    if (w != null && w.wireType == PbWireType.fixed32) {
      final v = w.asFloat32;
      if (v.isFinite && v > 0 && v < 200) width = v;
    }
    // Color structure: #3→{#1→{R,G,B,A}} — one extra nesting level
    final cOuter = m[3]?.first;
    if (cOuter != null && cOuter.wireType == PbWireType.lengthDelim) {
      final cInner = cOuter.asMessage.grouped()[1]?.first;
      if (cInner != null && cInner.wireType == PbWireType.lengthDelim) {
        final col = _readRGBA(cInner.asMessage);
        if (col != null) color = col;
      }
    }
  } catch (_) {}
  return (payload: _polylinePayload(points, width), color: color, width: width);
}

/// Read arrow-end flag from body[32] for schema-31 polyline shapes.
/// body[32]>#5 exists and its sub-field #1 (varint) indicates arrow type:
/// 1 = arrow at end, 0/absent = no arrow.
bool _readArrowType(Map<int, List<PbField>> body) {
  try {
    final f32 = body[32]?.first;
    if (f32 == null || f32.wireType != PbWireType.lengthDelim) return false;
    final m = f32.asMessage.grouped();
    final f5 = m[5]?.first;
    if (f5 == null || f5.wireType != PbWireType.lengthDelim) return false;
    final m5 = f5.asMessage.grouped();
    final v = m5[1]?.first.asInt ?? 0;
    return v > 0;
  } catch (_) {
    return false;
  }
}

/// Arrow indicator for bv41 connector strokes (vuA(v)A(S(uu))A(S(uuuu))vA(f) schema).
/// body[15] is a small message {#1: style_enum, #2: ref}.
/// style_enum 2 = plain line; 5 = arrowhead at end; 8 = arrowhead at start.
/// Any value other than 2 (or 1) is treated as "has arrowhead".
bool _readArrowTypeConnector(Map<int, List<PbField>> body) {
  try {
    final f15 = body[15]?.first;
    if (f15 == null || f15.wireType != PbWireType.lengthDelim) return false;
    final m = f15.asMessage.grouped();
    final v = m[1]?.first.asInt ?? 2;
    // v=1: plain line (no arrow). v>=2: arrowhead (2=default, 3/5/8=variants).
    return v >= 2;
  } catch (_) {
    return false;
  }
}

/// Read x,y from wrapper → {innerField: pointMsg → {#1: x, #2: y}}.
TplPoint? _readPointWrapper(PbField? wrapper, {required int innerField}) {
  if (wrapper == null || wrapper.wireType != PbWireType.lengthDelim) return null;
  try {
    final inner = wrapper.asMessage.grouped();
    final p = inner[innerField]?.first;
    if (p == null || p.wireType != PbWireType.lengthDelim) return null;
    final pm = p.asMessage.grouped();
    final x = pm[1]?.first.asFloat32;
    final y = pm[2]?.first.asFloat32;
    if (x != null && y != null) return TplPoint(x, y);
  } catch (_) {}
  return null;
}

TplPayload _polylinePayload(List<TplPoint> points, double width,
    {int strokeType = 1}) {
  // Force strokeType = 1 so renderer uses straight-line "L" path; segments
  // are 4-float so TplSegment.x/y resolves to values[0]/values[1].
  final segs = <TplSegment>[];
  for (var i = 1; i < points.length; i++) {
    segs.add(TplSegment([points[i].x, points[i].y, points[i].x, points[i].y]));
  }
  return TplPayload(
    strokeType: 1,
    width: width,
    pressures: List<int>.filled(points.length, 0xffff),
    anchors: [points.first],
    segments: segs,
    schema: 'synthetic',
    trailer: Uint8List(0),
  );
}

BBox _bboxFromPoints(TplPayload p) {
  double minX = double.infinity, minY = double.infinity;
  double maxX = -double.infinity, maxY = -double.infinity;
  for (final pt in p.flatPoints()) {
    if (pt.x < minX) minX = pt.x;
    if (pt.y < minY) minY = pt.y;
    if (pt.x > maxX) maxX = pt.x;
    if (pt.y > maxY) maxY = pt.y;
  }
  return BBox(minX, minY, maxX, maxY);
}

String _safeUtf8(Uint8List b) {
  try {
    return const Utf8Codec(allowMalformed: true).decode(b);
  } catch (_) {
    return '';
  }
}

/// Scan a body's bytes for a field-6 sub-message containing a UUID reference
/// (container link). If found, record the mapping and ensure the container
/// body is reachable.
void _findContainerLink(
  Uint8List bodyBytes,
  Map<String, Uint8List> allBodies,
  Map<String, String> embeddedContainerOf,
  Map<String, Uint8List> containerBodies,
) {
  try {
    final body = PbReader(bodyBytes).readAll();
    // Field 1 = element UUID (direct string, not nested sub-message)
    String? elementUuid;
    for (final f in body) {
      if (f.number == 1 && f.wireType == PbWireType.lengthDelim) {
        if (_looksLikeUuid(f.asBytes)) {
          elementUuid = f.asString;
        }
        break;
      }
    }
    if (elementUuid == null) return;

    // Field 6 = container reference sub-message: {field_1: containerUuid}
    for (final f in body) {
      if (f.number == 6 && f.wireType == PbWireType.lengthDelim) {
        try {
          final m6 = f.asMessage.grouped();
          final containerField = m6[1]?.first;
          if (containerField != null &&
              _looksLikeUuid(containerField.asBytes)) {
            final containerUuid = containerField.asString;
            embeddedContainerOf[elementUuid] = containerUuid;
            // Ensure the container body is indexed.
            final cBody = allBodies[containerUuid];
            if (cBody != null) containerBodies[containerUuid] = cBody;
          }
        } catch (_) {}
        break;
      }
    }
  } catch (_) {}
}

/// Replace a text element's bbox and fill with those from its container body.
/// Uses the same body[20]/body[21] parsing pattern as _classifyBody.
TextElement _applyContainerStyle(TextElement el, Uint8List containerBody) {
  try {
    final body = PbReader(containerBody).readAll().fold<Map<int, List<PbField>>>(
      {},
      (m, f) { (m[f.number] ??= []).add(f); return m; },
    );

    // Parse origin (body[20]) and size (body[21]) — same nesting as in
    // _classifyBody: origin[1].{x,y}; size[2].{w,h}.
    BBox? bbox;
    final f20 = body[20]?.first;
    final f21 = body[21]?.first;
    if (f20 != null && f21 != null &&
        f20.wireType == PbWireType.lengthDelim &&
        f21.wireType == PbWireType.lengthDelim) {
      try {
        final orig = f20.asMessage.grouped();
        final p = orig[1]?.first; // {x, y}
        final sz = f21.asMessage.grouped();
        final sub = sz[2]?.first; // {w, h}
        if (p != null && p.wireType == PbWireType.lengthDelim &&
            sub != null && sub.wireType == PbWireType.lengthDelim) {
          final pm = p.asMessage.grouped();
          final sm = sub.asMessage.grouped();
          final ox = pm[1]?.first.asFloat32 ?? 0;
          final oy = pm[2]?.first.asFloat32 ?? 0;
          final w = sm[1]?.first.asFloat32 ?? 0;
          final h = sm[2]?.first.asFloat32 ?? 0;
          if (ox.isFinite && oy.isFinite && w > 0 && h > 0) {
            bbox = BBox(ox, oy, ox + w, oy + h);
          }
        }
      } catch (_) {}
    }

    // Parse fill color (body[30]).
    Color4? fillColor;
    final f30 = body[30]?.first;
    if (f30 != null && f30.wireType == PbWireType.lengthDelim) {
      try {
        final m30 = f30.asMessage.grouped();
        final f30_1 = m30[1]?.first;
        if (f30_1 != null && f30_1.wireType == PbWireType.lengthDelim) {
          final m30_1 = f30_1.asMessage.grouped();
          final f30_1_1 = m30_1[1]?.first;
          if (f30_1_1 != null && f30_1_1.wireType == PbWireType.lengthDelim) {
            final rgb = f30_1_1.asMessage.grouped();
            final r = rgb[1]?.first?.asFloat32 ?? 0;
            final g = rgb[2]?.first?.asFloat32 ?? 0;
            final b = rgb[3]?.first?.asFloat32 ?? 0;
            if (r.isFinite && g.isFinite && b.isFinite) {
              fillColor = Color4(r, g, b, 1.0);
            }
          }
        }
      } catch (_) {}
    }

    if (bbox == null && fillColor == null) return el;

    // If the element already has its own bbox (local coordinates from
    // body[20]/body[21]), translate it into page space by adding the
    // container's page origin.  This preserves individual element positions
    // so multiple text elements inside the same container don't collapse to
    // the same dedup bucket.  containerBbox keeps the container's full page
    // rect for drawing the background fill.
    BBox? translatedBbox;
    final containerFullBbox = bbox; // container's page bbox
    if (containerFullBbox != null && el.bbox != null) {
      final local = el.bbox!;
      final dx = containerFullBbox.minX;
      final dy = containerFullBbox.minY;
      translatedBbox = BBox(dx + local.minX, dy + local.minY,
                            dx + local.maxX, dy + local.maxY);
    }

    return TextElement(
      id: el.id,
      opType: el.opType,
      lamport: el.lamport,
      bbox: translatedBbox ?? containerFullBbox ?? el.bbox,
      text: el.text,
      color: el.color,
      fontSize: el.fontSize,
      letterSpacing: el.letterSpacing,
      fillColor: fillColor ?? el.fillColor,
      cornerRadius: el.cornerRadius,
      containerBbox: containerFullBbox,
    );
  } catch (_) {
    return el;
  }
}
