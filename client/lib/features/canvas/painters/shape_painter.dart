// Renders ShapeObjects (rectangle / ellipse / triangle / diamond).

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../domain/page_object.dart';

class ShapePainter extends CustomPainter {
  const ShapePainter({
    required this.shapes,
    required this.layerId,
    this.layerOpacity = 1.0,
    this.scaleFactor = 1.0,
  });

  final List<ShapeObject> shapes;
  final String layerId;
  final double layerOpacity;
  /// Uniform scale applied to coordinates (for cover thumbnails).
  final double scaleFactor;

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in shapes) {
      if (s.deleted) continue;
      if (layerId.isNotEmpty && s.layerId != layerId) continue;
      final base = Color(s.colorArgb);
      final a = (base.a * layerOpacity).clamp(0.0, 1.0);

      final rect = Rect.fromLTRB(
        s.bbox.minX * scaleFactor,
        s.bbox.minY * scaleFactor,
        s.bbox.maxX * scaleFactor,
        s.bbox.maxY * scaleFactor,
      );

      if (s.shape == ShapeKind.arrow || s.shape == ShapeKind.line) {
        final p = Paint()
          ..color = base.withValues(alpha: a)
          ..style = PaintingStyle.stroke
          ..strokeWidth = s.strokeWidthPt * scaleFactor
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true;
        if (s.shape == ShapeKind.arrow) {
          _drawArrow(canvas, rect, s.arrowFlipX, s.arrowFlipY, p);
        } else {
          final aPt = Offset(
            s.arrowFlipX ? rect.right : rect.left,
            s.arrowFlipY ? rect.bottom : rect.top,
          );
          final bPt = Offset(
            s.arrowFlipX ? rect.left : rect.right,
            s.arrowFlipY ? rect.top : rect.bottom,
          );
          canvas.drawLine(aPt, bPt, p);
        }
        continue;
      }

      if (s.filled) {
        final fillColor = s.fillColorArgb != null ? Color(s.fillColorArgb!) : base;
        final fa = (fillColor.a * layerOpacity).clamp(0.0, 1.0);
        final fillPaint = Paint()
          ..color = fillColor.withValues(alpha: fa)
          ..style = PaintingStyle.fill
          ..isAntiAlias = true;
        _drawShape(canvas, s.shape, rect, fillPaint);
      }

      final strokePaint = Paint()
        ..color = base.withValues(alpha: a)
        ..style = PaintingStyle.stroke
        ..strokeWidth = s.strokeWidthPt * scaleFactor
        ..isAntiAlias = true;
      _drawShape(canvas, s.shape, rect, strokePaint);
    }
  }

  static void _drawArrow(
      Canvas canvas, Rect rect, bool flipX, bool flipY, Paint paint) {
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
    canvas.drawLine(tail, head, paint);
    canvas.drawLine(head, Offset(bx + perpX, by + perpY), paint);
    canvas.drawLine(head, Offset(bx - perpX, by - perpY), paint);
  }

  static void _drawShape(Canvas canvas, ShapeKind kind, Rect rect, Paint paint) {
    switch (kind) {
      case ShapeKind.rectangle:
        canvas.drawRect(rect, paint);
      case ShapeKind.ellipse:
        canvas.drawOval(rect, paint);
      case ShapeKind.triangle:
        // Equilateral triangle fitted inside the drawn rect.
        final w = rect.width;
        final h = rect.height;
        final double base, triH;
        if (w * math.sqrt(3) / 2 <= h) {
          base = w;
          triH = w * math.sqrt(3) / 2;
        } else {
          triH = h;
          base = h * 2 / math.sqrt(3);
        }
        final cx = rect.center.dx;
        final ty = rect.center.dy - triH / 2;
        final by_ = rect.center.dy + triH / 2;
        final triPath = Path()
          ..moveTo(cx, ty)
          ..lineTo(cx + base / 2, by_)
          ..lineTo(cx - base / 2, by_)
          ..close();
        canvas.drawPath(triPath, paint);
      case ShapeKind.diamond:
        final path = Path()
          ..moveTo(rect.center.dx, rect.top)
          ..lineTo(rect.right, rect.center.dy)
          ..lineTo(rect.center.dx, rect.bottom)
          ..lineTo(rect.left, rect.center.dy)
          ..close();
        canvas.drawPath(path, paint);
      case ShapeKind.arrow:
      case ShapeKind.line:
        // Arrow/line are rendered before this switch; nothing here.
        break;
    }
  }

  @override
  bool shouldRepaint(covariant ShapePainter old) =>
      !identical(old.shapes, shapes) ||
      old.layerId != layerId ||
      old.scaleFactor != scaleFactor;
}
