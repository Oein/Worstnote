import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'document.dart';
import 'model.dart';
import 'tpl.dart';

/// Render a [Page] to an SVG string.
///
/// The output uses page-point coordinates (matching what's encoded in
/// the GoodNotes file). Pages with a background image (PNG attachment)
/// will use that image's pixel dimensions for the canvas; pages with a
/// PDF background fall back to A4 unless [pageWidth]/[pageHeight] are
/// supplied.
class SvgRenderer {
  /// Default page size when nothing else can be inferred.
  final double defaultPageWidth;
  final double defaultPageHeight;

  /// Font family used for text boxes. Browsers will fall back to local
  /// system fonts; if you need exact match, pass an exact CSS family.
  final String fontFamily;

  /// If true, the renderer will rasterize PDF-backed pages by shelling out
  /// to `pdftoppm` (poppler). When false (or `pdftoppm` is missing), PDF
  /// backgrounds are skipped.
  final bool rasterizePdfBackgrounds;

  /// DPI used when rasterizing PDF backgrounds. GoodNotes' on-screen
  /// canvas for PDF-backed pages is the PDF rasterized at iPad screen DPI
  /// (~132). Strokes / text coordinates are recorded in this space.
  final int pdfRasterDpi;

  const SvgRenderer({
    this.defaultPageWidth = 612,
    this.defaultPageHeight = 792,
    this.rasterizePdfBackgrounds = true,
    this.pdfRasterDpi = 132,
    this.fontFamily =
        '"Apple SD Gothic Neo", "Pretendard", "Noto Sans KR", system-ui, sans-serif',
  });

  /// Render a single page to SVG. The optional [pageNumberInPdf] hint is
  /// used when rasterizing a multi-page PDF background (1-based).
  String render(Page page, GoodNotesDocument doc, {int pageNumberInPdf = 1}) {
    final bg = doc.backgroundOf(page);

    // Rasterize / decode the background image (if any) so we know its
    // dimensions. Note: the background's pixel dimensions are NOT the same
    // as GoodNotes' canvas coordinate space — strokes & text bboxes live in
    // a separate canvas (~1024 wide for A4) and the background is scaled
    // to fit that canvas. We MUST size the SVG viewBox to the canvas, not
    // the background's pixel size.
    Uint8List? bgPng;
    if (bg != null && bg.isPng) {
      bgPng = bg.bytes;
    } else if (bg != null && bg.isPdf && rasterizePdfBackgrounds) {
      bgPng = _pdfPageToPng(bg.bytes, pageNumberInPdf, pdfRasterDpi);
    }

    final dims = _resolvePageSize(page, bgPng);
    final w = dims.$1, h = dims.$2;

    final sb = StringBuffer();
    sb.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    sb.writeln(
      '<svg xmlns="http://www.w3.org/2000/svg" '
      'xmlns:xlink="http://www.w3.org/1999/xlink" '
      'viewBox="0 0 $w $h" width="$w" height="$h">',
    );
    sb.writeln('<rect x="0" y="0" width="$w" height="$h" fill="white"/>');

    // Pre-scan for arrowhead strokes so we can emit per-color <defs>.
    final arrowColors = <String>{};
    for (final el in page.elements) {
      if (el is StrokeElement && el.arrowEnd) {
        arrowColors.add(_rgbHex(el.color));
      }
    }
    if (arrowColors.isNotEmpty) {
      sb.writeln('<defs>');
      for (final hex in arrowColors) {
        final id = 'arr${hex.substring(1)}';
        sb.writeln(
          '<marker id="$id" markerWidth="12" markerHeight="12" '
          'refX="11" refY="6" orient="auto" markerUnits="userSpaceOnUse">'
          '<path d="M0,0 L0,12 L12,6 z" fill="$hex"/>'
          '</marker>',
        );
      }
      sb.writeln('</defs>');
    }

    if (bgPng != null) {
      final b64 = base64.encode(bgPng);
      sb.writeln(
        '<image href="data:image/png;base64,$b64" '
        'x="0" y="0" width="$w" height="$h" '
        'preserveAspectRatio="none"/>',
      );
    }

    // Elements in change-log order. Deduplicate text: when GoodNotes lets
    // the user edit a text element, it stores the new version as a fresh
    // element with a higher lamport. Two-pass dedup so distinct cells in
    // dense tables aren't collapsed:
    //   1. tight 10px position bucket (catches edits where text content
    //      changed but the box stayed put);
    //   2. identical text within 80px (catches edits that nudged the box).
    final allTexts = page.elements.whereType<TextElement>().toList();
    final keepText = <TextElement>{...allTexts};

    final byPos = <String, TextElement>{};
    for (final el in allTexts) {
      final key = '${(el.bbox?.minX ?? 0).round() ~/ 10}|'
          '${(el.bbox?.minY ?? 0).round() ~/ 10}';
      final ex = byPos[key];
      if (ex == null) {
        byPos[key] = el;
      } else if (el.lamport > ex.lamport) {
        keepText.remove(ex);
        byPos[key] = el;
      } else {
        keepText.remove(el);
      }
    }
    final remaining = keepText.toList();
    for (var i = 0; i < remaining.length; i++) {
      final a = remaining[i];
      if (!keepText.contains(a) || a.text.isEmpty) continue;
      for (var j = i + 1; j < remaining.length; j++) {
        final b = remaining[j];
        if (!keepText.contains(b) || b.text != a.text) continue;
        final ax = a.bbox?.minX ?? 0, ay = a.bbox?.minY ?? 0;
        final bx = b.bbox?.minX ?? 0, by = b.bbox?.minY ?? 0;
        if ((ax - bx).abs() < 80 && (ay - by).abs() < 30) {
          keepText.remove(a.lamport >= b.lamport ? b : a);
        }
      }
    }
    // Deduplicate strokes: when GoodNotes stores two near-identical polyline
    // shapes (same color, similar width, endpoints within 20px), keep only
    // the higher-lamport one. Handles undo/redo pairs where two versions of
    // the same drawn line coexist in the CRDT log.
    final allStrokes = page.elements.whereType<StrokeElement>().toList();
    final keepStroke = <StrokeElement>{...allStrokes};
    for (var i = 0; i < allStrokes.length; i++) {
      final a = allStrokes[i];
      if (!keepStroke.contains(a)) continue;
      final ap = a.payload;
      if (ap == null || ap.anchors.isEmpty) continue;
      final apts = ap.flatPoints();
      if (apts.length < 2) continue;
      for (var j = i + 1; j < allStrokes.length; j++) {
        final b = allStrokes[j];
        if (!keepStroke.contains(b)) continue;
        final bp = b.payload;
        if (bp == null || bp.anchors.isEmpty) continue;
        if (_rgbHex(a.color) != _rgbHex(b.color)) continue;
        if ((a.width - b.width).abs() > 0.5) continue;
        final bpts = bp.flatPoints();
        if (bpts.length < 2) continue;
        if ((apts.first.x - bpts.first.x).abs() > 20) continue;
        if ((apts.first.y - bpts.first.y).abs() > 20) continue;
        if ((apts.last.x - bpts.last.x).abs() > 20) continue;
        if ((apts.last.y - bpts.last.y).abs() > 20) continue;
        keepStroke.remove(a.lamport >= b.lamport ? b : a);
      }
    }

    // Three render passes mirroring GoodNotes z-order:
    //   1) inline images + text fill rects (background)
    //   2) strokes (pen / highlighter / shapes)
    //   3) text content
    for (final el in page.elements) {
      if (el is ImageElement) _renderImage(sb, el, doc);
      else if (el is TextElement && keepText.contains(el)) _renderTextFill(sb, el);
    }
    for (final el in page.elements) {
      if (el is StrokeElement && keepStroke.contains(el)) _renderStroke(sb, el);
    }
    for (final el in page.elements) {
      if (el is TextElement && keepText.contains(el)) _renderTextContent(sb, el);
    }

    sb.writeln('</svg>');
    return sb.toString();
  }

  // ---- helpers ----

  (double, double) _resolvePageSize(Page page, Uint8List? bgBytes) {
    // For pages with a real background, the bg's pixel dimensions ARE
    // the GoodNotes canvas (1:1, because we rasterize PDFs at the same
    // ~132 DPI / iPad-screen DPI GoodNotes uses internally).
    if (bgBytes != null && bgBytes.length > 24) {
      final bd = ByteData.sublistView(bgBytes);
      final w = bd.getUint32(16, Endian.big);
      final h = bd.getUint32(20, Endian.big);
      if (w > 0 && h > 0) return (w.toDouble(), h.toDouble());
    }
    // No background image — assume an A4 page at 132 DPI (1091×1542).
    // This matches blank pages the user added on top of a PDF document.
    return (1091.0, 1542.0);
  }

  Uint8List? _pdfPageToPng(Uint8List pdfBytes, int pageNumber, int dpi) {
    try {
      final tmp = Directory.systemTemp.createTempSync('gn_pdfbg_');
      final pdfPath = '${tmp.path}/in.pdf';
      File(pdfPath).writeAsBytesSync(pdfBytes);
      final res = Process.runSync(
        'pdftoppm',
        ['-r', '$dpi', '-png', '-f', '$pageNumber', '-l', '$pageNumber',
         pdfPath, '${tmp.path}/out'],
      );
      if (res.exitCode != 0) return null;
      // pdftoppm names files as out-N.png with zero-padded N (no padding
      // when single page).
      for (final f in tmp.listSync().whereType<File>()) {
        if (f.path.endsWith('.png')) {
          final bytes = f.readAsBytesSync();
          tmp.deleteSync(recursive: true);
          return bytes;
        }
      }
      tmp.deleteSync(recursive: true);
      return null;
    } catch (_) {
      return null;
    }
  }


  void _renderStroke(StringBuffer sb, StrokeElement s) {
    final payload = s.payload;
    if (payload == null || payload.anchors.isEmpty) return;

    final c = s.color;
    final hex = _rgbHex(c);
    // Synthetic shape strokes (highlighter "tape" / underline) inherit a
    // fully-opaque RGBA from the source proto, but GoodNotes renders them
    // as semi-transparent so text underneath shows through. Detect by the
    // synthesized-payload schema marker.
    final isShape = payload.schema == 'synthetic' && s.width >= 3;
    final opacity = (isShape ? c.a * 0.45 : c.a).toStringAsFixed(3);
    final width = s.width <= 0 ? 1.0 : s.width;
    final strokeWidth = width.toStringAsFixed(3);

    // body[9] strokes already encode coordinates in canvas pixel space — no scaling needed.
    const scale = 1.0;

    final d = StringBuffer();
    final a = payload.anchors.first;
    d.write('M ${_f(a.x * scale)} ${_f(a.y * scale)}');
    if (payload.isHighlighter) {
      // Highlighter segments are 4-float (x, y, ctrl_x, ctrl_y).
      for (final seg in payload.segments) {
        if (seg.values.length >= 4) {
          d.write(' Q ${_f(seg.values[2] * scale)} ${_f(seg.values[3] * scale)} '
              '${_f(seg.values[0] * scale)} ${_f(seg.values[1] * scale)}');
        }
      }
    } else if (payload.schema == 'body9' && payload.segments.length >= 2) {
      // body9 arc/curve. For 3-point strokes use a single quadratic bezier
      // M p0 Q p1 p2 — passes through endpoints and is attracted toward
      // the middle waypoint without the overshoot Catmull-Rom produces on
      // sparse samples. For longer paths, fall back to Catmull-Rom →
      // cubic bezier smoothing.
      final pts = payload.flatPoints();
      if (pts.length == 3) {
        // Solve for the Bezier control point B such that the curve at t=0.5
        // hits p1 exactly: B = 2*p1 - 0.5*(p0 + p2).
        final p0 = pts[0], p1 = pts[1], p2 = pts[2];
        final bx = 2 * p1.x - 0.5 * (p0.x + p2.x);
        final by = 2 * p1.y - 0.5 * (p0.y + p2.y);
        d.write(' Q ${_f(bx)} ${_f(by)} ${_f(p2.x)} ${_f(p2.y)}');
      } else {
        for (var i = 0; i < pts.length - 1; i++) {
          final p0 = i == 0 ? pts[0] : pts[i - 1];
          final p1 = pts[i];
          final p2 = pts[i + 1];
          final p3 = i + 2 < pts.length ? pts[i + 2] : pts[pts.length - 1];
          final c1x = p1.x + (p2.x - p0.x) / 6;
          final c1y = p1.y + (p2.y - p0.y) / 6;
          final c2x = p2.x - (p3.x - p1.x) / 6;
          final c2y = p2.y - (p3.y - p1.y) / 6;
          d.write(' C ${_f(c1x)} ${_f(c1y)} ${_f(c2x)} ${_f(c2y)} ${_f(p2.x)} ${_f(p2.y)}');
        }
      }
    } else {
      // Pen segments: treat the first (x, y) as the line endpoint.
      // body9 with <2 segments falls through here; synthetic uses adaptive
      // threshold; regular pen uses a fixed ~20 canvas-unit threshold.
      final jumpThreshold = payload.schema == 'synthetic'
          ? _adaptiveJumpThreshold(payload)
          : 400.0;
      double px = a.x, py = a.y;
      for (final seg in payload.segments) {
        final sx = seg.x * scale, sy = seg.y * scale;
        final dpx = px * scale, dpy = py * scale;
        d.write(' ${(sx - dpx) * (sx - dpx) + (sy - dpy) * (sy - dpy) > jumpThreshold ? 'M' : 'L'} '
            '${_f(sx)} ${_f(sy)}');
        px = seg.x; py = seg.y;
      }
    }

    final arrowAttr = s.arrowEnd
        ? ' marker-end="url(#arr${hex.substring(1)})"'
        : '';
    sb.writeln(
      '<path d="$d" stroke="$hex" stroke-opacity="$opacity" '
      'stroke-width="$strokeWidth" fill="none" '
      'stroke-linecap="round" stroke-linejoin="round"$arrowAttr/>',
    );
  }

  void _renderImage(
      StringBuffer sb, ImageElement el, GoodNotesDocument doc) {
    final att = doc.attachments[el.attachmentId];
    final bbox = el.bbox;
    if (att == null || bbox == null) return;
    Uint8List? png;
    if (att.isPng) {
      png = att.bytes;
    } else if (att.isPdf && rasterizePdfBackgrounds) {
      png = _pdfPageToPng(att.bytes, 1, pdfRasterDpi);
    }
    if (png == null) return;
    final b64 = base64.encode(png);
    sb.writeln(
      '<image href="data:image/png;base64,$b64" '
      'x="${_f(bbox.minX)}" y="${_f(bbox.minY)}" '
      'width="${_f(bbox.width)}" height="${_f(bbox.height)}" '
      'preserveAspectRatio="none"/>',
    );
  }

  void _renderTextFill(StringBuffer sb, TextElement t) {
    final bbox = t.bbox;
    // Render fill rect. Behaviour:
    //   text non-empty + non-white  → render (yellow sticky-note etc)
    //   text non-empty + white      → skip (painting over neighbours)
    //   text empty + white + large  → render (PDF-mask panel)
    //   text empty + anything else  → skip (orphaned container with no
    //                                 content; rendering a colored block
    //                                 alone looks like a glitch)
    if (t.fillColor != null && bbox != null) {
      final fc = t.fillColor!;
      // For the size check and large-panel detection, use the container bbox
      // (which is the full frame) if available, otherwise use element bbox.
      final sizeBbox = t.containerBbox ?? bbox;
      final isWhite = fc.r > 0.95 && fc.g > 0.95 && fc.b > 0.95;
      final isLargeEmptyWhitePanel = t.text.isEmpty && isWhite &&
          sizeBbox.width > 200 && sizeBbox.height > 60;
      final shouldRender = (t.text.isNotEmpty && !isWhite) || isLargeEmptyWhitePanel;
      if (shouldRender) {
        final fhex = _rgbHex(fc);
        final rx = t.cornerRadius > 0 ? ' rx="${_f(t.cornerRadius)}"' : '';
        final size = (t.fontSize <= 0 || t.fontSize > 200) ? 16.0 : t.fontSize;
        // Container-backed sticky notes (cornerRadius > 0 or containerBbox
        // present): use the full container dimensions for the background rect.
        // Plain text highlights: shrink to estimated text width/height.
        double rectW = sizeBbox.width;
        double rectH = sizeBbox.height;
        if (t.text.isNotEmpty && !isLargeEmptyWhitePanel &&
            t.cornerRadius <= 0 && t.containerBbox == null) {
          final lines = t.text.split('\n');
          double maxLineW = 0;
          for (final ln in lines) {
            final w = _estimateWidth(ln, size);
            if (w > maxLineW) maxLineW = w;
          }
          if (maxLineW > 0 && maxLineW < sizeBbox.width) rectW = maxLineW;
          // Shrink height to fit actual line count (line-height ≈ 1.2× size).
          final fitH = lines.length * size * 1.2;
          if (fitH > 0 && fitH < sizeBbox.height) rectH = fitH;
        }
        final pad = isLargeEmptyWhitePanel ? 4.0 : 0.0;
        // Use containerBbox position for the background rect origin so all
        // elements within the same container share the same background frame.
        final rectBbox = t.containerBbox ?? sizeBbox;
        sb.writeln(
          '<rect x="${_f(rectBbox.minX - pad)}" y="${_f(rectBbox.minY - pad)}" '
          'width="${_f(rectW + pad * 2)}" height="${_f(rectH + pad * 2)}" '
          'fill="$fhex"$rx/>',
        );
      }
    }
  }

  void _renderTextContent(StringBuffer sb, TextElement t) {
    if (t.text.isEmpty) return;
    final size = (t.fontSize <= 0 || t.fontSize > 200) ? 16.0 : t.fontSize;
    final hex = _rgbHex(t.color);
    final opacity = t.color.a.toStringAsFixed(3);
    final bbox = t.bbox;
    final x = bbox?.minX ?? 0;
    final y = (bbox?.minY ?? 0) + size;
    final boxW = bbox?.width ?? 0;
    final spacing =
        t.letterSpacing == null ? '' : ' letter-spacing="${_f(t.letterSpacing!)}"';

    // Wrap text into lines that fit within boxW using character-width estimation.
    final wrappedLines = boxW > size * 1.5
        ? _wrapText(t.text, boxW, size)
        : t.text.split('\n');

    final body = StringBuffer();
    for (var i = 0; i < wrappedLines.length; i++) {
      final dy = i == 0 ? '0' : _f(size * 1.2);
      body.write('<tspan x="${_f(x)}" dy="$dy">${_escape(wrappedLines[i])}</tspan>');
    }
    sb.writeln(
      '<text x="${_f(x)}" y="${_f(y)}" '
      'font-family=\'$fontFamily\' '
      'font-size="${_f(size)}" fill="$hex" fill-opacity="$opacity"'
      '$spacing>$body</text>',
    );
  }

  /// Estimate rendered width of a string at [fontSize].
  /// Korean/CJK full-width chars ≈ 1em; ASCII/Latin ≈ 0.55em.
  double _estimateWidth(String s, double fontSize) {
    double w = 0;
    for (final r in s.runes) {
      if (r >= 0xAC00 && r <= 0xD7A3) {
        w += fontSize; // Hangul syllable
      } else if (r >= 0x3000 && r <= 0x9FFF) {
        w += fontSize; // CJK / Jamo / symbols
      } else {
        w += fontSize * 0.55; // Latin / ASCII
      }
    }
    return w;
  }

  /// Word-wrap [text] to lines that fit within [maxWidth] pixels at [fontSize].
  /// Respects existing \n line breaks and inserts new ones where needed.
  List<String> _wrapText(String text, double maxWidth, double fontSize) {
    final result = <String>[];
    for (final paragraph in text.split('\n')) {
      if (paragraph.isEmpty) { result.add(''); continue; }
      // Try to break at spaces first; if no spaces, break by character.
      final words = paragraph.split(' ');
      final line = StringBuffer();
      double lineW = 0;
      for (var wi = 0; wi < words.length; wi++) {
        final word = words[wi];
        final wordW = _estimateWidth(word, fontSize);
        final spaceW = fontSize * 0.3;
        if (line.isEmpty) {
          // If a single word is wider than the box, break it by characters.
          if (wordW > maxWidth) {
            final chars = StringBuffer();
            double charLineW = 0;
            for (final r in word.runes) {
              final cw = _estimateWidth(String.fromCharCode(r), fontSize);
              if (charLineW + cw > maxWidth && chars.isNotEmpty) {
                result.add(chars.toString());
                chars.clear(); charLineW = 0;
              }
              chars.writeCharCode(r);
              charLineW += cw;
            }
            if (chars.isNotEmpty) { line.write(chars); lineW = charLineW; }
          } else {
            line.write(word); lineW = wordW;
          }
        } else if (lineW + spaceW + wordW > maxWidth) {
          result.add(line.toString());
          line.clear(); lineW = 0;
          line.write(word); lineW = wordW;
        } else {
          line.write(' $word'); lineW += spaceW + wordW;
        }
      }
      if (line.isNotEmpty) result.add(line.toString());
    }
    return result.isEmpty ? [''] : result;
  }

  /// Adaptive jump threshold for synthetic shape strokes.
  /// Uses 100× the median squared inter-point distance so genuine sub-path
  /// gaps (≫ typical sample spacing) trigger a Move while continuous outlines
  /// always connect with Line-to.
  double _adaptiveJumpThreshold(TplPayload payload) {
    final segs = payload.segments;
    if (segs.isEmpty || payload.anchors.isEmpty) return 400.0;
    final spacings = <double>[];
    double px = payload.anchors.first.x, py = payload.anchors.first.y;
    for (final seg in segs) {
      final dx = seg.x - px, dy = seg.y - py;
      spacings.add(dx * dx + dy * dy);
      px = seg.x; py = seg.y;
    }
    spacings.sort();
    final medianSq = spacings[spacings.length ~/ 2];
    return medianSq * 100; // 10× in linear distance
  }

  String _rgbHex(Color4 c) {
    int b(double v) => (v.clamp(0.0, 1.0) * 255).round();
    return '#${b(c.r).toRadixString(16).padLeft(2, '0')}'
        '${b(c.g).toRadixString(16).padLeft(2, '0')}'
        '${b(c.b).toRadixString(16).padLeft(2, '0')}';
  }

  String _f(double v) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toStringAsFixed(3);
  }

  String _escape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}
