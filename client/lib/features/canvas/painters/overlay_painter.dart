// Paints transient UI: rectangle/lasso selection outlines, tape edit handles,
// shape-snap previews, etc. Cheap to repaint frequently.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../domain/page_object.dart' show ShapeKind;
import '../engine/lasso.dart';

/// Live preview shape kind for shape-tool drawing. When set, [rect] is
/// rendered as the actual shape (filled, with outline) using [previewColor]
/// and [previewFillColor] instead of a plain selection rectangle.
class ShapePreview {
  const ShapePreview({
    required this.kind,
    required this.strokeColor,
    required this.strokeWidth,
    this.fillColor,
    this.arrowFlipX = false,
    this.arrowFlipY = false,
  });
  final ShapeKind kind;
  final Color strokeColor;
  final double strokeWidth;
  final Color? fillColor;
  final bool arrowFlipX;
  final bool arrowFlipY;
}

class OverlayPainter extends CustomPainter {
  const OverlayPainter({
    this.lasso,
    this.rect,
    this.lassoClosed = false,
    this.shapePreview,
  });

  /// Lasso polygon. If [lassoClosed] is true, the path is closed (filled
  /// selection); otherwise only the open trail is drawn (live preview).
  final List<Point2>? lasso;

  /// Rectangle selection (live), or — if [shapePreview] is set — the bbox
  /// of the live shape preview.
  final Rect? rect;

  final bool lassoClosed;

  /// When non-null and [rect] is set, render the rect as this shape kind
  /// (matching the committed render) instead of a selection outline.
  final ShapePreview? shapePreview;

  @override
  void paint(Canvas canvas, Size size) {
    if (rect != null && shapePreview != null) {
      _paintShapePreview(canvas, rect!, shapePreview!);
    } else if (rect != null) {
      final paint = Paint()
        ..color = const Color(0xFF2563EB)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      canvas.drawRect(rect!, paint);
    }

    if (lasso != null && lasso!.length > 1) {
      final paint = Paint()
        ..color = const Color(0xFF2563EB)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      final path = Path()..moveTo(lasso!.first.x, lasso!.first.y);
      for (var i = 1; i < lasso!.length; i++) {
        path.lineTo(lasso![i].x, lasso![i].y);
      }
      if (lassoClosed) path.close();
      canvas.drawPath(path, paint);
    }
  }

  static void _paintShapePreview(Canvas canvas, Rect r, ShapePreview p) {
    final stroke = Paint()
      ..color = p.strokeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = p.strokeWidth
      ..isAntiAlias = true;
    final fill = p.fillColor == null
        ? null
        : (Paint()
          ..color = p.fillColor!
          ..style = PaintingStyle.fill);

    switch (p.kind) {
      case ShapeKind.rectangle:
        if (fill != null) canvas.drawRect(r, fill);
        canvas.drawRect(r, stroke);
      case ShapeKind.ellipse:
        if (fill != null) canvas.drawOval(r, fill);
        canvas.drawOval(r, stroke);
      case ShapeKind.triangle:
        // Equilateral triangle fitted inside r — matches ShapePainter.
        final w = r.width;
        final h = r.height;
        final double base, triH;
        if (w * math.sqrt(3) / 2 <= h) {
          base = w;
          triH = w * math.sqrt(3) / 2;
        } else {
          triH = h;
          base = h * 2 / math.sqrt(3);
        }
        final cx = r.center.dx;
        final ty = r.center.dy - triH / 2;
        final by = r.center.dy + triH / 2;
        final tri = Path()
          ..moveTo(cx, ty)
          ..lineTo(cx + base / 2, by)
          ..lineTo(cx - base / 2, by)
          ..close();
        if (fill != null) canvas.drawPath(tri, fill);
        canvas.drawPath(tri, stroke);
      case ShapeKind.diamond:
        final dia = Path()
          ..moveTo(r.center.dx, r.top)
          ..lineTo(r.right, r.center.dy)
          ..lineTo(r.center.dx, r.bottom)
          ..lineTo(r.left, r.center.dy)
          ..close();
        if (fill != null) canvas.drawPath(dia, fill);
        canvas.drawPath(dia, stroke);
      case ShapeKind.arrow:
        _drawArrowPreview(canvas, r, p.arrowFlipX, p.arrowFlipY, stroke);
      case ShapeKind.line:
        final a = Offset(
          p.arrowFlipX ? r.right : r.left,
          p.arrowFlipY ? r.bottom : r.top,
        );
        final b = Offset(
          p.arrowFlipX ? r.left : r.right,
          p.arrowFlipY ? r.top : r.bottom,
        );
        canvas.drawLine(a, b, stroke);
    }
  }

  static void _drawArrowPreview(
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

  @override
  bool shouldRepaint(covariant OverlayPainter oldDelegate) =>
      oldDelegate.lasso != lasso ||
      oldDelegate.rect != rect ||
      oldDelegate.lassoClosed != lassoClosed ||
      oldDelegate.shapePreview != shapePreview;
}
