// Renders a note's pages to a PDF file using syncfusion_flutter_pdf.
// PDF/image backgrounds are embedded directly (vector for PDF sources),
// while strokes, shapes, and text boxes are drawn as vector graphics on top.

import 'dart:math' as math;
import 'dart:typed_data';

import 'export_helper.dart';
import 'package:flutter/material.dart'
    show
        AlertDialog,
        BuildContext,
        Column,
        CrossAxisAlignment,
        LinearProgressIndicator,
        MainAxisSize,
        Navigator,
        Offset,
        Rect,
        Size,
        SizedBox,
        StatelessWidget,
        Text,
        TextStyle,
        ValueListenableBuilder,
        ValueNotifier,
        Widget,
        showDialog;
import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../../domain/page_object.dart';
import '../../domain/page_spec.dart';
import '../../domain/stroke.dart';
import '../import/asset_service.dart';
import '../notebook/notebook_state.dart';

class PdfExporter {
  /// Shows a progress dialog while building the PDF, then presents the OS
  /// save dialog. Returns the saved path, or null if cancelled.
  static Future<String?> exportNoteWithProgress(
    BuildContext context,
    NotebookState state, {
    String? suggestedName,
  }) async {
    final progress = ValueNotifier<({int current, int total})>(
        (current: 0, total: state.pages.length));

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ExportProgressDialog(progress: progress),
    );

    try {
      final bytes = await buildPdfBytes(
        state,
        onProgress: (current, total) =>
            progress.value = (current: current, total: total),
      );

      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();

      final name = (suggestedName ?? state.note.title)
          .replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');
      return await platformSaveBytes(
        bytes,
        suggestedName: name,
        extension: 'pdf',
        typeLabel: 'PDF',
      );
    } catch (_) {
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
      rethrow;
    } finally {
      progress.dispose();
    }
  }

  /// Export without a progress UI (kept for backward-compat / images-ZIP).
  static Future<String?> exportNote(
    NotebookState state, {
    String? suggestedName,
  }) async {
    final bytes = await buildPdfBytes(state);
    final name = (suggestedName ?? state.note.title)
        .replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');
    return await platformSaveBytes(
      bytes,
      suggestedName: name,
      extension: 'pdf',
      typeLabel: 'PDF',
    );
  }

  static Future<Uint8List> buildPdfBytes(
    NotebookState state, {
    void Function(int current, int total)? onProgress,
  }) async {
    final doc = PdfDocument();
    // Remove the default section that the document creates automatically.
    // We'll add one section per page so each can have a custom size.
    doc.pageSettings.margins.all = 0;

    final assetService = AssetService();

    final pages = state.pages;
    for (var idx = 0; idx < pages.length; idx++) {
      final notePage = pages[idx];
      final spec = notePage.spec;

      // Each page gets its own section so the size can differ per page.
      final section = doc.sections!.add();
      section.pageSettings =
          PdfPageSettings(Size(spec.widthPt, spec.heightPt));
      section.pageSettings.margins.all = 0;
      final page = section.pages.add();
      final g = page.graphics;

      final strokes = state.strokesByPage[notePage.id] ?? const [];
      final shapes = state.shapesByPage[notePage.id] ?? const [];
      final texts = state.textsByPage[notePage.id] ?? const [];

      await _paintPage(
        g,
        spec,
        strokes.where((s) => !s.deleted).toList(),
        shapes.where((s) => !s.deleted).toList(),
        texts.where((t) => !t.deleted).toList(),
        assetService,
      );

      onProgress?.call(idx + 1, pages.length);
    }

    final bytes = Uint8List.fromList(await doc.save());
    doc.dispose();
    return bytes;
  }

  // ── Per-page rendering ────────────────────────────────────────────────────

  static Future<void> _paintPage(
    PdfGraphics g,
    PageSpec spec,
    List<Stroke> strokes,
    List<ShapeObject> shapes,
    List<TextBoxObject> texts,
    AssetService assetService,
  ) async {
    final w = spec.widthPt;
    final h = spec.heightPt;

    // Background
    final bg = spec.background;
    if (bg is PdfBackground) {
      // Embed the source PDF page as a vector Form XObject — no rasterisation.
      final file = await assetService.fileFor(bg.assetId);
      if (file != null) {
        try {
          final srcDoc =
              PdfDocument(inputBytes: await file.readAsBytes());
          if (bg.pageNo >= 1 && bg.pageNo <= srcDoc.pages.count) {
            final template = srcDoc.pages[bg.pageNo - 1].createTemplate();
            g.drawPdfTemplate(template, Offset.zero, Size(w, h));
          }
          srcDoc.dispose();
        } catch (_) {
          // Fallback: white fill if the source PDF can't be read.
          g.drawRectangle(
            brush: PdfSolidBrush(PdfColor(255, 255, 255)),
            bounds: Rect.fromLTWH(0, 0, w, h),
          );
        }
      }
    } else if (bg is ImageBackground) {
      final file = await assetService.fileFor(bg.assetId);
      if (file != null) {
        try {
          final img = PdfBitmap(await file.readAsBytes());
          g.drawImage(img, Rect.fromLTWH(0, 0, w, h));
        } catch (_) {}
      }
    } else {
      // Blank / vector backgrounds: draw white fill first.
      g.drawRectangle(
        brush: PdfSolidBrush(PdfColor(255, 255, 255)),
        bounds: Rect.fromLTWH(0, 0, w, h),
      );
      if (bg is GridBackground) {
        final pen =
            PdfPen(PdfColor(0xE5, 0xE7, 0xEB), width: 0.5);
        final sp = bg.spacingPt;
        for (double x = sp; x < w; x += sp) {
          g.drawLine(pen, Offset(x, 0), Offset(x, h));
        }
        for (double y = sp; y < h; y += sp) {
          g.drawLine(pen, Offset(0, y), Offset(w, y));
        }
      } else if (bg is RuledBackground) {
        final pen =
            PdfPen(PdfColor(0xD1, 0xD5, 0xDB), width: 0.5);
        final sp = bg.spacingPt;
        for (double y = sp; y < h; y += sp) {
          g.drawLine(pen, Offset(0, y), Offset(w, y));
        }
      } else if (bg is DotBackground) {
        final brush =
            PdfSolidBrush(PdfColor(0xCB, 0xD5, 0xE1));
        final sp = bg.spacingPt;
        for (double x = sp; x < w; x += sp) {
          for (double y = sp; y < h; y += sp) {
            g.drawEllipse(
              Rect.fromCenter(center: Offset(x, y), width: 0.8, height: 0.8),
              brush: brush,
            );
          }
        }
      }
    }

    // Strokes — drawn as connected polylines.
    // syncfusion uses top-left origin so no Y-flip needed.
    for (final stroke in strokes) {
      if (stroke.points.length < 2) continue;

      final color = _sColor(stroke.colorArgb, stroke.opacity);
      final pen = PdfPen(
        color,
        width: stroke.widthPt,
        lineCap: PdfLineCap.round,
        lineJoin: PdfLineJoin.round,
      );

      if (stroke.lineStyle == LineStyle.dashed) {
        final w = stroke.widthPt;
        pen.dashStyle = PdfDashStyle.custom;
        pen.dashPattern = [w * 5, w * 3 * stroke.dashGap];
      } else if (stroke.lineStyle == LineStyle.dotted) {
        final w = stroke.widthPt;
        pen.dashStyle = PdfDashStyle.custom;
        pen.dashPattern = [w, w * 2 * stroke.dashGap];
      }

      // Build a single connected path: first point is MoveTo, rest are LineTo.
      final pts = stroke.points
          .map((p) => Offset(p.x, p.y))
          .toList();
      final types = List<int>.generate(
        pts.length,
        (i) => i == 0 ? 0 : 1, // 0 = start, 1 = line
      );
      final path = PdfPath();
      path.addPath(pts, types);
      g.drawPath(path, pen: pen);
    }

    // Shapes
    for (final shape in shapes) {
      final r = shape.bbox;
      final bounds = Rect.fromLTWH(
        r.minX, r.minY, r.maxX - r.minX, r.maxY - r.minY);

      PdfBrush? fillBrush;
      if (shape.filled) {
        final fillArgb = shape.fillColorArgb ?? shape.colorArgb;
        fillBrush = PdfSolidBrush(_sColor(fillArgb, 1.0));
      }
      final strokePen =
          PdfPen(_sColor(shape.colorArgb, 1.0), width: shape.strokeWidthPt);

      switch (shape.shape) {
        case ShapeKind.rectangle:
          g.drawRectangle(
              pen: strokePen, brush: fillBrush, bounds: bounds);
        case ShapeKind.ellipse:
          g.drawEllipse(bounds, pen: strokePen, brush: fillBrush);
        case ShapeKind.triangle:
          final pts = [
            Offset(r.minX + (r.maxX - r.minX) / 2, r.minY),
            Offset(r.maxX, r.maxY),
            Offset(r.minX, r.maxY),
          ];
          g.drawPolygon(pts, pen: strokePen, brush: fillBrush);
        case ShapeKind.diamond:
          final cx = (r.minX + r.maxX) / 2;
          final cy = (r.minY + r.maxY) / 2;
          final pts = [
            Offset(cx, r.minY),
            Offset(r.maxX, cy),
            Offset(cx, r.maxY),
            Offset(r.minX, cy),
          ];
          g.drawPolygon(pts, pen: strokePen, brush: fillBrush);
        case ShapeKind.arrow:
          final tail = Offset(
            shape.arrowFlipX ? r.maxX : r.minX,
            shape.arrowFlipY ? r.maxY : r.minY,
          );
          final head = Offset(
            shape.arrowFlipX ? r.minX : r.maxX,
            shape.arrowFlipY ? r.minY : r.maxY,
          );
          final dx = head.dx - tail.dx;
          final dy = head.dy - tail.dy;
          final len = math.sqrt(dx * dx + dy * dy);
          if (len >= 1) {
            final ux = dx / len;
            final uy = dy / len;
            final hl = (len * 0.18).clamp(6.0, 28.0);
            final hw = hl * 0.55;
            final bx = head.dx - ux * hl;
            final by = head.dy - uy * hl;
            g.drawLine(strokePen, tail, Offset(bx, by));
            final fillBrushArrow = PdfSolidBrush(
                _sColor(shape.colorArgb, 1.0));
            g.drawPolygon([
              head,
              Offset(bx + (-uy * hw), by + (ux * hw)),
              Offset(bx - (-uy * hw), by - (ux * hw)),
            ], brush: fillBrushArrow);
          }
        case ShapeKind.line:
          final a = Offset(
            shape.arrowFlipX ? r.maxX : r.minX,
            shape.arrowFlipY ? r.maxY : r.minY,
          );
          final b = Offset(
            shape.arrowFlipX ? r.minX : r.maxX,
            shape.arrowFlipY ? r.minY : r.maxY,
          );
          g.drawLine(strokePen, a, b);
      }
    }

    // Text boxes
    for (final tb in texts) {
      if (tb.text.isEmpty) continue;
      final font = _fontFor(tb.text, tb.fontSizePt, tb.fontWeight >= 700);
      final brush = PdfSolidBrush(_sColor(tb.colorArgb, 1.0));
      final bounds = Rect.fromLTWH(
        tb.bbox.minX,
        tb.bbox.minY,
        math.max(1, tb.bbox.maxX - tb.bbox.minX),
        math.max(1, tb.bbox.maxY - tb.bbox.minY),
      );
      g.drawString(
        tb.text,
        font,
        brush: brush,
        bounds: bounds,
        format: PdfStringFormat(
          alignment: _textAlign(tb.textAlign),
          lineAlignment: PdfVerticalAlignment.top,
        ),
      );
    }
  }

  /// Returns an appropriate PDF font for [text].
  ///
  /// `PdfStandardFont` (Helvetica) only supports ASCII/Latin-1. Any text that
  /// contains characters outside that range (Korean, CJK, etc.) must use a
  /// `PdfCjkStandardFont`, which uses the PDF standard CJK composite-font
  /// mechanism and covers the full Unicode Hangul + Latin range.
  static PdfFont _fontFor(String text, double size, bool bold) {
    final hasCjk = text.codeUnits.any((c) => c > 0x00FF);
    if (hasCjk) {
      return PdfCjkStandardFont(
        bold
            ? PdfCjkFontFamily.hanyangSystemsShinMyeongJoMedium
            : PdfCjkFontFamily.hanyangSystemsGothicMedium,
        size,
      );
    }
    return PdfStandardFont(
      PdfFontFamily.helvetica,
      size,
      style: bold ? PdfFontStyle.bold : PdfFontStyle.regular,
    );
  }

  static PdfColor _sColor(int argb, double opacity) {
    final a = ((argb >> 24) & 0xFF);
    final r = ((argb >> 16) & 0xFF);
    final gr = ((argb >> 8) & 0xFF);
    final b = (argb & 0xFF);
    return PdfColor(r, gr, b, (a * opacity).round().clamp(0, 255));
  }

  static PdfTextAlignment _textAlign(int align) {
    switch (align) {
      case 1:
        return PdfTextAlignment.center;
      case 2:
        return PdfTextAlignment.right;
      default:
        return PdfTextAlignment.left;
    }
  }
}

// ── Progress dialog ───────────────────────────────────────────────────────────

class _ExportProgressDialog extends StatelessWidget {
  const _ExportProgressDialog({required this.progress});

  final ValueNotifier<({int current, int total})> progress;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: progress,
      builder: (ctx, v, _) {
        final frac = v.total > 0 ? v.current / v.total : 0.0;
        return AlertDialog(
          title: const Text('PDF 내보내기'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(value: frac),
              const SizedBox(height: 10),
              Text(
                '${v.current} / ${v.total} 페이지',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        );
      },
    );
  }
}
