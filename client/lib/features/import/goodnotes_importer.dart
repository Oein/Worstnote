// GoodNotes 5/6 (.goodnotes) → Notee importer.
//
// Pipeline:
//   1. User picks a .goodnotes (zip) file
//   2. `goodnotes_parser` decodes pages, strokes, text boxes, attachments
//   3. We map each Page → NotePage + Stroke list + TextBoxObject list
//   4. caller persists via Repository

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:goodnotes_parser/goodnotes_parser.dart' as gn;

import '../../core/ids.dart';
import '../../domain/layer.dart';
import '../../domain/page.dart' as np;
import '../../domain/page_object.dart';
import '../../domain/page_spec.dart';
import '../../domain/stroke.dart';
import '../canvas/painters/text_painter_widget.dart' show withRemeasuredHeight;
import 'asset_service.dart';

/// Result of a successful import — ready to be saved as a notebook.
class ImportedGoodNotes {
  final String title;
  final List<np.NotePage> pages;
  final Map<String, List<Layer>> layersByPage;
  final Map<String, String> activeLayerByPage;
  final Map<String, List<Stroke>> strokesByPage;
  final Map<String, List<TextBoxObject>> textsByPage;
  ImportedGoodNotes({
    required this.title,
    required this.pages,
    required this.layersByPage,
    required this.activeLayerByPage,
    required this.strokesByPage,
    required this.textsByPage,
  });
}

class GoodNotesImporter {
  /// Open a system file picker for `.goodnotes` packages and import the
  /// chosen file. Returns `null` if the user cancels.
  Future<ImportedGoodNotes?> pickAndImport() async {
    const group = XTypeGroup(
      label: 'GoodNotes',
      extensions: ['goodnotes', 'zip'],
    );
    final file = await openFile(acceptedTypeGroups: const [group]);
    if (file == null) return null;
    return importFile(file.path);
  }

  /// Read a `.goodnotes` package from [path] and convert it to Notee
  /// in-memory state. Heavy work runs on a background isolate.
  Future<ImportedGoodNotes?> importFile(
    String path, {
    String? noteId,
  }) async {
    final id = noteId ?? newId();
    final bytes = await File(path).readAsBytes();
    final doc = await compute(_parseDocBytes, bytes);
    final title = doc.title ?? _stripExtension(path.split(Platform.pathSeparator).last);
    final stroke = <String, List<Stroke>>{};
    final text = <String, List<TextBoxObject>>{};
    final layers = <String, List<Layer>>{};
    final activeLayer = <String, String>{};
    final pages = <np.NotePage>[];
    final now = DateTime.now().toUtc();
    final assets = AssetService();

    // Pre-store every PNG/PDF attachment in the asset store so PageSpec
    // backgrounds can reference them by hash id. Also capture pixel/point
    // dimensions so the page can match the underlying asset (instead of
    // defaulting to A4 and misaligning the strokes).
    final attachAssetId = <String, AssetRef>{};
    final attachSize = <String, ({double w, double h})>{};
    for (final entry in doc.attachments.entries) {
      final a = entry.value;
      if (!a.isPng && !a.isPdf) continue;
      final ref = await assets.putBytes(a.bytes, mime: a.mimeType);
      attachAssetId[entry.key] = ref;
      if (a.isPng) {
        final dims = _readPngSize(a.bytes);
        if (dims != null) attachSize[entry.key] = dims;
      }
    }

    for (var i = 0; i < doc.pages.length; i++) {
      final gp = doc.pages[i];
      final pageId = newId();
      final layerId = newId();

      // Pick a sensible page size + background.
      final spec = _pickSpecFor(gp, attachAssetId, attachSize);
      pages.add(np.NotePage(
        id: pageId, noteId: id, index: i, spec: spec, updatedAt: now,
      ));
      layers[pageId] = [
        Layer(id: layerId, pageId: pageId, z: 0, name: 'Default'),
      ];
      activeLayer[pageId] = layerId;

      final strokes = <Stroke>[];
      final texts = <TextBoxObject>[];
      final base = now.add(Duration(microseconds: i * 1000));
      var z = 0;
      for (final el in gp.elements) {
        final ts = base.add(Duration(microseconds: z++));
        if (el is gn.StrokeElement) {
          final s = _toStroke(el, pageId, layerId, ts);
          if (s != null) strokes.add(s);
        } else if (el is gn.TextElement) {
          final t = _toText(el, pageId, layerId, ts);
          if (t != null) texts.add(t);
        }
      }
      stroke[pageId] = strokes;
      text[pageId] = texts;
    }

    return ImportedGoodNotes(
      title: title,
      pages: pages,
      layersByPage: layers,
      activeLayerByPage: activeLayer,
      strokesByPage: stroke,
      textsByPage: text,
    );
  }

  static String _stripExtension(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  static PageSpec _pickSpecFor(
    gn.Page gp,
    Map<String, AssetRef> attachAssetId,
    Map<String, ({double w, double h})> attachSize,
  ) {
    // If GoodNotes page has a backing PDF/PNG attachment use it as bg.
    final bgId = gp.backgroundAttachmentId;
    if (bgId != null && attachAssetId.containsKey(bgId)) {
      final ref = attachAssetId[bgId]!;
      // Pick page dimensions matching the asset (for PNG we measured;
      // for PDF default to A4 since parsing the PDF dims is heavier).
      final dims = attachSize[bgId];
      final w = dims?.w ?? PaperDimensions.a4.$1;
      final h = dims?.h ?? PaperDimensions.a4.$2;
      if (ref.mime == 'application/pdf') {
        return PageSpec(
          widthPt: w,
          heightPt: h,
          kind: PaperKind.pdfImported,
          background: PageBackground.pdf(assetId: ref.id, pageNo: 1),
        );
      }
      return PageSpec(
        widthPt: w,
        heightPt: h,
        kind: PaperKind.custom,
        background: PageBackground.image(assetId: ref.id),
      );
    }
    return _pickSpecFromContent(gp);
  }

  /// Decode (width, height) from PNG IHDR (8-byte sig + 4-byte len + 4-byte
  /// chunk type, then 4-byte big-endian width + height). Returns null on
  /// any read error.
  static ({double w, double h})? _readPngSize(Uint8List bytes) {
    if (bytes.length < 24) return null;
    if (bytes[0] != 0x89 || bytes[1] != 0x50 ||
        bytes[2] != 0x4e || bytes[3] != 0x47) return null;
    int u32(int o) =>
        (bytes[o] << 24) | (bytes[o + 1] << 16) | (bytes[o + 2] << 8) |
        bytes[o + 3];
    final w = u32(16);
    final h = u32(20);
    if (w <= 0 || h <= 0) return null;
    return (w: w.toDouble(), h: h.toDouble());
  }

  static PageSpec _pickSpecFromContent(gn.Page gp) {
    // Compute bbox over all elements; if too small fall back to A4.
    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    void grow(gn.BBox? b) {
      if (b == null) return;
      if (b.minX < minX) minX = b.minX;
      if (b.minY < minY) minY = b.minY;
      if (b.maxX > maxX) maxX = b.maxX;
      if (b.maxY > maxY) maxY = b.maxY;
    }
    for (final el in gp.elements) {
      grow(el.bbox);
    }
    if (minX == double.infinity) return PageSpec.a4Blank();
    final w = (maxX - minX).clamp(400.0, 1600.0);
    final h = (maxY - minY).clamp(600.0, 2400.0);
    // Prefer A4 if the content fits — better default look.
    final a4 = PageSpec.a4Blank();
    if (w <= a4.widthPt && h <= a4.heightPt) return a4;
    // Otherwise build a blank spec at the content size + small pad.
    return PageSpec(
      widthPt: w + 32,
      heightPt: h + 32,
      kind: PaperKind.custom,
      background: const PageBackground.blank(),
    );
  }

  static Stroke? _toStroke(gn.StrokeElement el, String pageId, String layerId,
      DateTime createdAt) {
    final pts = el.points;
    if (pts.isEmpty) return null;
    final pressures = el.payload?.pressures ?? const <int>[];
    final out = <StrokePoint>[];
    for (var i = 0; i < pts.length; i++) {
      final p = pts[i];
      // Pressure encoded as uint16 0..0xFFFF; map to 0..1, fallback 0.5.
      final pr = i < pressures.length
          ? (pressures[i] / 0xFFFF).clamp(0.0, 1.0)
          : 0.5;
      out.add(StrokePoint(x: p.x, y: p.y, pressure: pr));
    }
    if (out.length < 2) {
      // Single point → duplicate so renderer draws a dot.
      out.add(out.first.copyWith(x: out.first.x + 0.5));
    }
    final tool = _classifyToolKind(el);
    return Stroke(
      id: el.id,
      pageId: pageId,
      layerId: layerId,
      tool: tool,
      colorArgb: el.color.toArgb(),
      widthPt: el.width <= 0 ? 1.5 : el.width,
      opacity: 1.0,
      points: out,
      bbox: el.bbox != null
          ? Bbox(
              minX: el.bbox!.minX, minY: el.bbox!.minY,
              maxX: el.bbox!.maxX, maxY: el.bbox!.maxY,
            )
          : Bbox.fromPoints(out),
      createdAt: createdAt,
    );
  }

  static ToolKind _classifyToolKind(gn.StrokeElement el) {
    // GoodNotes TPL strokeType: 1=pen, 2=highlighter.
    if (el.payload?.strokeType == 2) return ToolKind.highlighter;
    return ToolKind.pen;
  }

  static TextBoxObject? _toText(gn.TextElement el, String pageId,
      String layerId, DateTime createdAt) {
    if (el.text.isEmpty) return null;
    final bb = el.bbox;
    final fs = el.fontSize <= 0 ? 16.0 : el.fontSize;
    // GoodNotes text bboxes are often very narrow (or even degenerate)
    // because the original metrics differ from ours. Fall back to a
    // generous width so wrap doesn't pile characters on top of each other.
    final defaultMinX = bb?.minX ?? 12;
    final defaultMinY = bb?.minY ?? 12;
    final rawW = bb == null ? 0.0 : (bb.maxX - bb.minX);
    final estCharsPerLine = (el.text.length).clamp(8, 80);
    final fallbackW = (estCharsPerLine * fs * 0.62);
    final boxW = rawW < fs * 4 ? fallbackW : rawW;
    final pre = TextBoxObject(
      id: el.id,
      pageId: pageId,
      layerId: layerId,
      text: el.text,
      colorArgb: el.color.toArgb(),
      fontFamily: 'Helvetica Neue',
      fontSizePt: fs,
      fontWeight: 400,
      italic: false,
      textAlign: 0,
      bbox: Bbox(
        minX: defaultMinX,
        minY: defaultMinY,
        maxX: defaultMinX + boxW,
        maxY: defaultMinY + fs * 1.4,
      ),
      createdAt: createdAt,
    );
    // Recompute height with the actual font/text/width so the visible box
    // matches the rendered content.
    return withRemeasuredHeight(pre);
  }
}

// Top-level isolate entry — must be a top-level or static function.
gn.GoodNotesDocument _parseDocBytes(Uint8List bytes) =>
    gn.GoodNotesDocument.openBytes(bytes);
