// ThumbnailService — renders note cover thumbnails to PNG and caches them
// on disk so the library screen can load covers instantly without replaying
// every stroke on each frame.
//
// Usage:
//   On note save → ThumbnailService.instance.schedule(noteId, spec, strokes, shapes, texts)
//   In library  → ThumbnailService.instance.getCached(noteId)

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../domain/page_object.dart';
import '../../domain/page_spec.dart';
import '../../domain/stroke.dart';
import '../canvas/painters/background_painter.dart';
import '../import/asset_service.dart';

class ThumbnailService {
  ThumbnailService._();
  static final ThumbnailService instance = ThumbnailService._();

  // Thumbnail width for note covers (library).
  static const double _thumbW = 240.0;
  // Thumbnail width for per-page previews (canvas scroll / sidebar).
  static const double _pageThumbW = 200.0;

  // Note-cover cache (noteId → bytes)
  final _mem = <String, Uint8List>{};
  // Per-page cache (pageId → bytes)
  final _pageMem = <String, Uint8List>{};

  // Only one generation runs at a time to avoid UI jank.
  Future<void>? _busy;

  // Emits noteId whenever a note-cover thumbnail is generated/updated.
  final _coverGenerated = StreamController<String>.broadcast();
  Stream<String> get onCoverGenerated => _coverGenerated.stream;

  /// True if the note cover is already in the memory cache (no disk I/O).
  bool hasCachedInMemory(String noteId) => _mem.containsKey(noteId);

  // ── Directory ──────────────────────────────────────────────────────────

  Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/thumbnails');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  Future<Directory> _pageDir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/thumbnails/pages');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  File _file(Directory d, String noteId) => File('${d.path}/$noteId.png');
  File _pageFile(Directory d, String pageId) => File('${d.path}/$pageId.png');

  // ── Public API ─────────────────────────────────────────────────────────

  /// Returns cached PNG bytes (memory then disk). Null if not cached.
  Future<Uint8List?> getCached(String noteId) async {
    if (_mem.containsKey(noteId)) return _mem[noteId];
    try {
      final f = _file(await _dir(), noteId);
      if (f.existsSync()) {
        final b = f.readAsBytesSync();
        _mem[noteId] = b;
        return b;
      }
    } catch (_) {}
    return null;
  }

  /// Schedule thumbnail generation (at most one at a time).
  /// Returns immediately; generation happens async on the next idle slot.
  void schedule({
    required String noteId,
    required PageSpec spec,
    required List<Stroke> strokes,
    required List<ShapeObject> shapes,
    required List<TextBoxObject> texts,
  }) {
    _busy = (_busy ?? Future.value()).then((_) => _generate(
      noteId: noteId,
      spec: spec,
      strokes: strokes,
      shapes: shapes,
      texts: texts,
    ));
  }

  /// Returns cached bytes if available; otherwise queues generation and
  /// waits until it completes, then returns the result.
  Future<Uint8List?> getOrGenerate({
    required String noteId,
    required PageSpec spec,
    required List<Stroke> strokes,
    required List<ShapeObject> shapes,
    required List<TextBoxObject> texts,
  }) async {
    final cached = await getCached(noteId);
    if (cached != null) return cached;
    // Queue in the serial chain and wait for this note to finish.
    final completer = Completer<Uint8List?>();
    _busy = (_busy ?? Future.value()).then((_) async {
      await _generate(
        noteId: noteId,
        spec: spec,
        strokes: strokes,
        shapes: shapes,
        texts: texts,
      );
      completer.complete(_mem[noteId]);
    });
    return completer.future;
  }

  /// Delete ALL cached thumbnails (note covers + per-page). Used by menu action.
  Future<void> clearAll() async {
    _mem.clear();
    _pageMem.clear();
    try {
      final d = await _dir();
      if (d.existsSync()) {
        for (final f in d.listSync()) {
          if (f is File) await f.delete();
        }
      }
    } catch (_) {}
    try {
      final d = await _pageDir();
      if (d.existsSync()) {
        for (final f in d.listSync()) {
          if (f is File) await f.delete();
        }
      }
    } catch (_) {}
  }

  /// Delete cached thumbnail so the library re-renders until the next save.
  Future<void> invalidate(String noteId) async {
    _mem.remove(noteId);
    try {
      final f = _file(await _dir(), noteId);
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }

  // ── Per-page API ───────────────────────────────────────────────────────

  /// Returns cached per-page thumbnail (memory then disk). Null if not cached.
  Future<Uint8List?> getCachedPage(String pageId) async {
    if (_pageMem.containsKey(pageId)) return _pageMem[pageId];
    try {
      final f = _pageFile(await _pageDir(), pageId);
      if (f.existsSync()) {
        final b = f.readAsBytesSync();
        _pageMem[pageId] = b;
        return b;
      }
    } catch (_) {}
    return null;
  }

  /// Schedule per-page thumbnail generation (serial queue, non-blocking).
  void schedulePage({
    required String pageId,
    required PageSpec spec,
    required List<Stroke> strokes,
    required List<ShapeObject> shapes,
    required List<TextBoxObject> texts,
  }) {
    _busy = (_busy ?? Future.value()).then(
      (_) => _generatePage(
        pageId: pageId,
        spec: spec,
        strokes: strokes,
        shapes: shapes,
        texts: texts,
      ),
    );
  }

  /// Returns cached page bytes; queues generation and awaits if not cached.
  Future<Uint8List?> getOrGeneratePage({
    required String pageId,
    required PageSpec spec,
    required List<Stroke> strokes,
    required List<ShapeObject> shapes,
    required List<TextBoxObject> texts,
  }) async {
    final cached = await getCachedPage(pageId);
    if (cached != null) return cached;
    final completer = Completer<Uint8List?>();
    _busy = (_busy ?? Future.value()).then((_) async {
      await _generatePage(
        pageId: pageId,
        spec: spec,
        strokes: strokes,
        shapes: shapes,
        texts: texts,
      );
      completer.complete(_pageMem[pageId]);
    });
    return completer.future;
  }

  Future<void> invalidatePage(String pageId) async {
    _pageMem.remove(pageId);
    try {
      final f = _pageFile(await _pageDir(), pageId);
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }

  Future<void> _generatePage({
    required String pageId,
    required PageSpec spec,
    required List<Stroke> strokes,
    required List<ShapeObject> shapes,
    required List<TextBoxObject> texts,
  }) async {
    try {
      final bytes = await _render(spec: spec, strokes: strokes, shapes: shapes, texts: texts, thumbW: _pageThumbW);
      if (bytes == null) return;
      _pageMem[pageId] = bytes;
      await (await _pageFile(await _pageDir(), pageId)).writeAsBytes(bytes);
    } catch (_) {}
  }

  /// Core render: paints spec+strokes+shapes to a PNG at [thumbW] wide.
  ///
  /// All drawing is done in page-coordinate space after applying canvas.scale,
  /// mirroring _ThumbnailPainter exactly. No cullRect is passed to Canvas —
  /// a cullRect causes Flutter to cull drawings near the page boundary.
  Future<Uint8List?> _render({
    required PageSpec spec,
    required List<Stroke> strokes,
    required List<ShapeObject> shapes,
    required List<TextBoxObject> texts,
    required double thumbW,
  }) async {
    final w = thumbW;
    final h = (w * spec.heightPt / spec.widthPt).clamp(50.0, 1600.0);
    final sx = w / spec.widthPt;
    final sy = h / spec.heightPt;

    final recorder = ui.PictureRecorder();
    // No cullRect — prevents edge-of-page strokes from being culled.
    final canvas = Canvas(recorder);

    // White base (thumbnail pixel coords)
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.white);

    // Raster backgrounds are drawn at thumbnail pixel size before scaling.
    switch (spec.background) {
      case PdfBackground(:final assetId, :final pageNo):
        await _drawPdfBackground(canvas, Size(w, h), assetId, pageNo);
      case ImageBackground(:final assetId):
        await _drawImageBackground(canvas, Size(w, h), assetId);
      default:
        break;
    }

    // Scale canvas to page-coordinate space for all vector content.
    canvas.save();
    canvas.scale(sx, sy);

    // Geometric background — drawn in page coords so spacingPt scales correctly.
    switch (spec.background) {
      case PdfBackground() || ImageBackground():
        break; // already drawn above
      default:
        BackgroundPainter(background: spec.background)
            .paint(canvas, Size(spec.widthPt, spec.heightPt));
    }

    // Strokes in page coords (canvas transform handles the scale).
    _paintStrokesScaled(canvas, spec, strokes, sx, tapeOnly: false);
    // Shapes in page coords.
    _paintShapesScaled(canvas, spec, shapes);
    // Text boxes in page coords.
    _paintTextsScaled(canvas, texts);
    // Tape on top of everything.
    _paintStrokesScaled(canvas, spec, strokes, sx, tapeOnly: true);

    canvas.restore();

    final picture = recorder.endRecording();
    final img = await picture.toImage(w.round(), h.round());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return data?.buffer.asUint8List();
  }

  Future<void> _drawPdfBackground(
      Canvas canvas, Size size, String assetId, int pageNo) async {
    File? file;
    try {
      file = await AssetService().fileFor(assetId);
      if (file == null) return;
      // Defensive size check: a 0-byte file is a leftover from an interrupted
      // download — opening it would either crash pdfium or hand us garbage.
      if (await file.length() == 0) {
        await file.delete();
        return;
      }
      final doc = await PdfDocument.openFile(file.path);
      if (pageNo < 1 || pageNo > doc.pages.length) {
        await doc.dispose();
        return;
      }
      final page = doc.pages[pageNo - 1]; // 0-indexed
      final pageImage = await page.render(
        width: size.width.round(),
        height: size.height.round(),
        // fullWidth/fullHeight tell pdfium the rendering scale.
        // Without these, pdfium uses the page's natural point size as the
        // rendering scale — which only captures the top-left crop in the bitmap.
        fullWidth: size.width,
        fullHeight: size.height,
        backgroundColor: const Color(0xFFFFFFFF),
      );
      if (pageImage != null) {
        // Use createImage() so the format (BGRA on pdfium) is handled
        // correctly — avoids the R↔B swap that occurs when the pixel
        // buffer is decoded with the wrong PixelFormat.
        final uiImage = await pageImage.createImage();
        canvas.drawImageRect(
          uiImage,
          Rect.fromLTWH(
              0, 0, uiImage.width.toDouble(), uiImage.height.toDouble()),
          Rect.fromLTWH(0, 0, size.width, size.height),
          Paint(),
        );
        uiImage.dispose();
      }
      await doc.dispose();
    } catch (_) {
      // Corrupt PDF asset — delete so the next sync re-downloads cleanly.
      try {
        if (file != null && await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  Future<void> _drawImageBackground(
      Canvas canvas, Size size, String assetId) async {
    try {
      final file = await AssetService().fileFor(assetId);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final codec = await descriptor.instantiateCodec(
        targetWidth: size.width.round(),
        targetHeight: size.height.round(),
      );
      final frame = await codec.getNextFrame();
      canvas.drawImageRect(
        frame.image,
        Rect.fromLTWH(0, 0, frame.image.width.toDouble(),
            frame.image.height.toDouble()),
        Rect.fromLTWH(0, 0, size.width, size.height),
        Paint(),
      );
      frame.image.dispose();
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
    } catch (_) {}
  }

  // ── Generation ─────────────────────────────────────────────────────────

  Future<void> _generate({
    required String noteId,
    required PageSpec spec,
    required List<Stroke> strokes,
    required List<ShapeObject> shapes,
    required List<TextBoxObject> texts,
  }) async {
    try {
      final bytes = await _render(spec: spec, strokes: strokes, shapes: shapes, texts: texts, thumbW: _thumbW);
      if (bytes == null) return;
      _mem[noteId] = bytes;
      await (await _file(await _dir(), noteId)).writeAsBytes(bytes);
      _coverGenerated.add(noteId);
    } catch (_) {}
  }

  /// Opens the thumbnail cache folder in Finder / Explorer.
  Future<void> openCacheFolder() async {
    final d = await _dir();
    if (!d.existsSync()) d.createSync(recursive: true);
    if (Platform.isMacOS) {
      await Process.run('open', [d.path]);
    } else if (Platform.isWindows) {
      await Process.run('explorer', [d.path]);
    }
  }

  // Draws strokes in the canvas's current page-coordinate space.
  // Caller must have applied canvas.scale(sx, sy) before this call.
  // sx is still needed for strokeWidth clamping in pixel units.
  void _paintStrokesScaled(Canvas canvas, PageSpec spec, List<Stroke> strokes, double sx, {bool tapeOnly = false}) {
    for (final s in strokes) {
      if (s.deleted || s.points.length < 2) continue;
      final isTape = s.tool == ToolKind.tape;
      if (tapeOnly && !isTape) continue;
      if (!tapeOnly && isTape) continue;
      final alpha = isTape ? 1.0 : s.opacity;
      final maxWidth = isTape ? double.infinity : 6.0 / sx;
      final paint = Paint()
        ..color = Color(s.colorArgb).withValues(alpha: alpha)
        // Stroke width is in page pts; the canvas scale converts to pixels.
        // Clamp in page-pt units so pixel result stays in 0.4..6px range.
        ..strokeWidth = s.widthPt.clamp(0.4 / sx, maxWidth)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      final path = Path()
        ..moveTo(s.points.first.x, s.points.first.y);
      for (final pt in s.points.skip(1)) {
        path.lineTo(pt.x, pt.y);
      }
      canvas.drawPath(path, paint);
    }
  }

  // Draws text boxes in the canvas's current page-coordinate space.
  void _paintTextsScaled(Canvas canvas, List<TextBoxObject> texts) {
    for (final t in texts) {
      if (t.deleted || t.text.isEmpty) continue;
      final w = (t.bbox.maxX - t.bbox.minX).clamp(1.0, double.infinity);
      final tp = TextPainter(
        text: TextSpan(
          text: t.text,
          style: TextStyle(
            fontSize: t.fontSizePt,
            color: Color(t.colorArgb),
            fontFamily: t.fontFamily,
            fontWeight: FontWeight.values.firstWhere(
              (fw) => fw.value == t.fontWeight,
              orElse: () => FontWeight.w400,
            ),
            fontStyle: t.italic ? FontStyle.italic : FontStyle.normal,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 5,
        ellipsis: '…',
      )..layout(maxWidth: w);
      tp.paint(canvas, Offset(t.bbox.minX, t.bbox.minY));
      tp.dispose();
    }
  }

  // Draws shapes in the canvas's current page-coordinate space.
  void _paintShapesScaled(Canvas canvas, PageSpec spec, List<ShapeObject> shapes) {
    for (final s in shapes) {
      if (s.deleted) continue;
      final rect =
          Rect.fromLTRB(s.bbox.minX, s.bbox.minY, s.bbox.maxX, s.bbox.maxY);
      if (s.filled &&
          s.shape != ShapeKind.arrow &&
          s.shape != ShapeKind.line) {
        final fc = s.fillColorArgb != null
            ? Color(s.fillColorArgb!)
            : Color(s.colorArgb);
        final fp = Paint()..color = fc..style = PaintingStyle.fill..isAntiAlias = true;
        switch (s.shape) {
          case ShapeKind.rectangle:
            canvas.drawRect(rect, fp);
          case ShapeKind.ellipse:
            canvas.drawOval(rect, fp);
          case ShapeKind.triangle:
            canvas.drawPath(Path()
              ..moveTo(rect.center.dx, rect.top)
              ..lineTo(rect.right, rect.bottom)
              ..lineTo(rect.left, rect.bottom)
              ..close(), fp);
          case ShapeKind.diamond:
            canvas.drawPath(Path()
              ..moveTo(rect.center.dx, rect.top)
              ..lineTo(rect.right, rect.center.dy)
              ..lineTo(rect.center.dx, rect.bottom)
              ..lineTo(rect.left, rect.center.dy)
              ..close(), fp);
          case ShapeKind.arrow:
          case ShapeKind.line:
            break;
        }
      }
      final sp = Paint()
        ..color = Color(s.colorArgb)
        ..style = PaintingStyle.stroke
        ..strokeWidth = s.strokeWidthPt
        ..isAntiAlias = true;
      switch (s.shape) {
        case ShapeKind.rectangle:
          canvas.drawRect(rect, sp);
        case ShapeKind.ellipse:
          canvas.drawOval(rect, sp);
        case ShapeKind.triangle:
          final path = Path()
            ..moveTo(rect.center.dx, rect.top)
            ..lineTo(rect.right, rect.bottom)
            ..lineTo(rect.left, rect.bottom)
            ..close();
          canvas.drawPath(path, sp);
        case ShapeKind.diamond:
          final path = Path()
            ..moveTo(rect.center.dx, rect.top)
            ..lineTo(rect.right, rect.center.dy)
            ..lineTo(rect.center.dx, rect.bottom)
            ..lineTo(rect.left, rect.center.dy)
            ..close();
          canvas.drawPath(path, sp);
        case ShapeKind.arrow:
          _drawArrow(canvas, rect, s.arrowFlipX, s.arrowFlipY, sp);
        case ShapeKind.line:
          final aPt = Offset(
            s.arrowFlipX ? rect.right : rect.left,
            s.arrowFlipY ? rect.bottom : rect.top,
          );
          final bPt = Offset(
            s.arrowFlipX ? rect.left : rect.right,
            s.arrowFlipY ? rect.top : rect.bottom,
          );
          canvas.drawLine(aPt, bPt, sp);
      }
    }
  }

  static void _drawArrow(
      Canvas canvas, Rect rect, bool flipX, bool flipY, Paint stroke) {
    final tail = Offset(
      flipX ? rect.right : rect.left,
      flipY ? rect.bottom : rect.top,
    );
    final head = Offset(
      flipX ? rect.left : rect.right,
      flipY ? rect.top : rect.bottom,
    );
    final dx = head.dx - tail.dx;
    final dy = head.dy - tail.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1) return;
    final ux = dx / len;
    final uy = dy / len;
    const headLen = 18.0;
    const headW = 9.0;
    final bx = head.dx - ux * headLen;
    final by = head.dy - uy * headLen;
    final perpX = -uy * headW;
    final perpY = ux * headW;
    canvas.drawLine(tail, head, stroke);
    canvas.drawLine(head, Offset(bx + perpX, by + perpY), stroke);
    canvas.drawLine(head, Offset(bx - perpX, by - perpY), stroke);
  }
}
