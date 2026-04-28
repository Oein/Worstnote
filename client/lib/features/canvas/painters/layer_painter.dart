// Paints all committed objects of a single [Layer]. The painter caches a
// `ui.Picture` per layer; only the active stroke painter repaints every
// frame. Cache invalidation is signalled by either:
//   1. Replacing the strokes list reference (any state.copyWith does this).
//   2. Calling [LayerCache.invalidate] directly (e.g. after deleting strokes
//      or toggling tape opacity).
//
// Tape strokes (tool == ToolKind.tape) render at full opacity by default
// and at 0.10 when their id is in [revealedTapeIds].

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../domain/layer.dart';
import '../../../domain/page_object.dart' show ShapeObject, ShapeKind;
import '../../../domain/stroke.dart';
import 'stroke_path.dart';

class LayerCache {
  ui.Picture? picture;
  Size? cachedSize;
  int generation = 0;

  void invalidate() {
    picture = null;
    generation++;
  }
}

Path _dashPathHelper(Path source, double width, LineStyle style,
    [double gap = 1.0]) {
  final on = style == LineStyle.dashed ? width * 5 : width;
  final off = (style == LineStyle.dashed ? width * 3 : width * 2) * gap;
  final result = Path();
  for (final metric in source.computeMetrics()) {
    var dist = 0.0;
    var drawing = true;
    while (dist < metric.length) {
      final seg = drawing ? on : off;
      if (drawing) {
        final end = (dist + seg).clamp(0.0, metric.length);
        result.addPath(metric.extractPath(dist, end), Offset.zero);
      }
      dist += seg;
      drawing = !drawing;
    }
  }
  return result;
}

/// Renders shapes + non-tape strokes interleaved by createdAt so the user
/// can freely re-order them via bring-forward / send-back. Tape and text
/// remain in their own passes.
class CombinedLayerPainter extends CustomPainter {
  CombinedLayerPainter({
    required this.shapes,
    required this.strokes,
    required this.layerOpacity,
  });
  final List<ShapeObject> shapes;
  final List<Stroke> strokes;
  final double layerOpacity;

  @override
  void paint(Canvas canvas, Size size) {
    // Build a unified ordered list. Each entry is (createdAt, isShape, obj).
    final entries = <(DateTime, int, Object)>[];
    for (final s in strokes) {
      if (s.deleted) continue;
      if (s.tool == ToolKind.tape) continue;
      entries.add((s.createdAt, 0, s));
    }
    for (final shape in shapes) {
      if (shape.deleted) continue;
      entries.add((shape.createdAt, 1, shape));
    }
    entries.sort((a, b) => a.$1.compareTo(b.$1));

    for (final e in entries) {
      if (e.$2 == 0) {
        _paintStroke(canvas, e.$3 as Stroke);
      } else {
        _paintShape(canvas, e.$3 as ShapeObject);
      }
    }
  }

  void _paintStroke(Canvas canvas, Stroke s) {
    if (s.points.length < 2) return;
    final raw = buildStrokePath(s.points);
    final path = s.lineStyle == LineStyle.solid
        ? raw
        : _dashPathHelper(raw, s.widthPt, s.lineStyle, s.dashGap);

    if (s.tool == ToolKind.highlighter) {
      // The highlighter color carries its own alpha. saveLayer prevents
      // self-overlapping segments from accumulating opacity.
      final colorAlpha = (Color(s.colorArgb).a * layerOpacity).clamp(0.0, 1.0);
      canvas.saveLayer(
        null,
        Paint()..color = Color.fromARGB(
            (colorAlpha * 255).round(), 255, 255, 255),
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = Color(s.colorArgb).withValues(alpha: 1.0)
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = s.widthPt
          ..blendMode = BlendMode.srcOver
          ..isAntiAlias = true,
      );
      canvas.restore();
      return;
    }

    final alpha = s.opacity * layerOpacity;
    canvas.drawPath(
      path,
      Paint()
        ..color = Color(s.colorArgb).withValues(alpha: alpha)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = s.widthPt
        ..blendMode = BlendMode.srcOver
        ..isAntiAlias = true,
    );
  }

  void _paintShape(Canvas canvas, ShapeObject s) {
    final base = Color(s.colorArgb);
    final a = (base.a * layerOpacity).clamp(0.0, 1.0);
    final rect = Rect.fromLTRB(
      s.bbox.minX, s.bbox.minY,
      s.bbox.maxX, s.bbox.maxY,
    );
    if (s.shape == ShapeKind.arrow || s.shape == ShapeKind.line) {
      final stroke = Paint()
        ..color = base.withValues(alpha: a)
        ..style = PaintingStyle.stroke
        ..strokeWidth = s.strokeWidthPt
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true;
      if (s.shape == ShapeKind.arrow) {
        _drawArrow(canvas, rect, s.arrowFlipX, s.arrowFlipY, stroke);
      } else {
        _drawLine(canvas, rect, s.arrowFlipX, s.arrowFlipY, stroke);
      }
      return;
    }
    if (s.filled) {
      final fc = s.fillColorArgb;
      final fillColor = fc != null ? Color(fc) : base;
      final fa = (fillColor.a * layerOpacity).clamp(0.0, 1.0);
      _drawShapeKind(canvas, s.shape, rect,
          Paint()
            ..color = fillColor.withValues(alpha: fa)
            ..style = PaintingStyle.fill
            ..isAntiAlias = true);
    }
    _drawShapeKind(canvas, s.shape, rect,
        Paint()
          ..color = base.withValues(alpha: a)
          ..style = PaintingStyle.stroke
          ..strokeWidth = s.strokeWidthPt
          ..isAntiAlias = true);
  }

  static void _drawLine(
      Canvas canvas, Rect rect, bool flipX, bool flipY, Paint stroke) {
    final a = Offset(
      flipX ? rect.right : rect.left,
      flipY ? rect.bottom : rect.top,
    );
    final b = Offset(
      flipX ? rect.left : rect.right,
      flipY ? rect.top : rect.bottom,
    );
    canvas.drawLine(a, b, stroke);
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
    // Fixed-size open arrowhead: always 18×9px regardless of arrow length.
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

  static void _drawShapeKind(
      Canvas canvas, ShapeKind kind, Rect rect, Paint paint) {
    if (kind == ShapeKind.rectangle) {
      canvas.drawRect(rect, paint);
    } else if (kind == ShapeKind.ellipse) {
      canvas.drawOval(rect, paint);
    } else if (kind == ShapeKind.triangle) {
      final w = rect.width;
      final h = rect.height;
      final double base, triH;
      const sqrt3 = 1.7320508075688772;
      if (w * sqrt3 / 2 <= h) {
        base = w; triH = w * sqrt3 / 2;
      } else {
        triH = h; base = h * 2 / sqrt3;
      }
      final cx = rect.center.dx;
      final ty = rect.center.dy - triH / 2;
      final by = rect.center.dy + triH / 2;
      final p = Path()
        ..moveTo(cx, ty)
        ..lineTo(cx + base / 2, by)
        ..lineTo(cx - base / 2, by)
        ..close();
      canvas.drawPath(p, paint);
    } else if (kind == ShapeKind.diamond) {
      final p = Path()
        ..moveTo(rect.center.dx, rect.top)
        ..lineTo(rect.right, rect.center.dy)
        ..lineTo(rect.center.dx, rect.bottom)
        ..lineTo(rect.left, rect.center.dy)
        ..close();
      canvas.drawPath(p, paint);
    }
    // arrow is handled by _drawArrow above
  }

  @override
  bool shouldRepaint(covariant CombinedLayerPainter old) =>
      !identical(old.shapes, shapes) ||
      !identical(old.strokes, strokes) ||
      old.layerOpacity != layerOpacity;
}

enum LayerTapeMode {
  /// Default: render every stroke including tape.
  all,
  /// Render every non-tape stroke (tape is drawn by a separate top pass).
  excludeTape,
  /// Render only tape strokes (top-most pass).
  tapeOnly,
}

class LayerPainter extends CustomPainter {
  LayerPainter({
    required this.layer,
    required this.strokes,
    required this.cache,
    this.revealedTapeIds = const {},
    this.tapeMode = LayerTapeMode.all,
    this.tapeRevealedOpacity = 0.30,
  });

  final Layer layer;
  final List<Stroke> strokes;
  final LayerCache cache;

  final Set<String> revealedTapeIds;
  final LayerTapeMode tapeMode;
  final double tapeRevealedOpacity;

  @override
  void paint(Canvas canvas, Size size) {
    if (!layer.visible) return;

    if (cache.picture == null || cache.cachedSize != size) {
      final recorder = ui.PictureRecorder();
      final c = Canvas(recorder, Offset.zero & size);
      _paintAll(c);
      cache.picture = recorder.endRecording();
      cache.cachedSize = size;
    }

    if (layer.opacity < 1.0) {
      canvas.saveLayer(
        Offset.zero & size,
        Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: layer.opacity),
      );
      canvas.drawPicture(cache.picture!);
      canvas.restore();
    } else {
      canvas.drawPicture(cache.picture!);
    }
  }

  void _paintAll(Canvas canvas) {
    for (final s in strokes) {
      if (s.deleted) continue;
      if (tapeMode == LayerTapeMode.excludeTape && s.tool == ToolKind.tape) {
        continue;
      }
      if (tapeMode == LayerTapeMode.tapeOnly && s.tool != ToolKind.tape) {
        continue;
      }

      // For highlighter: color carries its own alpha; s.opacity is 1.0.
      double alpha = s.tool == ToolKind.highlighter
          ? Color(s.colorArgb).a
          : s.opacity;
      var blend = BlendMode.srcOver;

      if (s.tool == ToolKind.highlighter) {
        blend = BlendMode.multiply;
      } else if (s.tool == ToolKind.tape) {
        // Tape is revealed (semi-transparent) when its ID is in revealedTapeIds.
        alpha = revealedTapeIds.contains(s.id) ? tapeRevealedOpacity : 1.0;
      }

      final paint = Paint()
        ..color = Color(s.colorArgb).withValues(alpha: alpha)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = s.widthPt
        ..blendMode = blend
        ..isAntiAlias = true;

      if (s.points.length < 2) continue;

      final rawPath = buildStrokePath(s.points);

      final path = s.lineStyle == LineStyle.solid
          ? rawPath
          : _dashPath(rawPath, s.widthPt, s.lineStyle, s.dashGap);
      // Tape: draw a soft shadow below the tape for a lifted-paper effect.
      // When the tape is revealed (semi-transparent), tint the shadow with
      // the tape color so it remains visible without being a hard black halo.
      if (s.tool == ToolKind.tape) {
        final shadowPath = rawPath.shift(const Offset(0, 1.8));
        final shadowColor = alpha < 0.5
            ? Color(s.colorArgb).withValues(alpha: 0.35)
            : Colors.black.withValues(alpha: 0.20);
        canvas.drawPath(
          shadowPath,
          Paint()
            ..color = shadowColor
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..strokeWidth = s.widthPt + 1
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.8),
        );
      }

      canvas.drawPath(path, paint);

      // Tape: overlay periodic perpendicular ticks for a masking-tape texture.
      if (s.tool == ToolKind.tape && alpha > 0.15) {
        _paintTapeTexture(canvas, rawPath, s.widthPt, Color(s.colorArgb));
      }
    }
  }

  /// Draws diagonal hatching along [path] to give tape a textured appearance.
  static void _paintTapeTexture(
      Canvas canvas, Path path, double width, Color baseColor) {
    final hsl = HSLColor.fromColor(baseColor);
    final darker = hsl
        .withLightness((hsl.lightness - 0.18).clamp(0.0, 1.0))
        .toColor()
        .withValues(alpha: 0.28);
    final tickPaint = Paint()
      ..color = darker
      ..strokeWidth = (width / 10).clamp(0.5, 2.0)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt;

    final halfW = width * 0.38;
    final spacing = width * 1.4;

    for (final metric in path.computeMetrics()) {
      var dist = spacing * 0.5;
      while (dist < metric.length) {
        final tangent = metric.getTangentForOffset(dist);
        if (tangent != null) {
          // Normal (perpendicular to path)
          final nx = -tangent.vector.dy;
          final ny = tangent.vector.dx;
          final cx = tangent.position.dx;
          final cy = tangent.position.dy;
          // Slight diagonal: 30° off the normal
          final tx = tangent.vector.dx;
          final ty = tangent.vector.dy;
          final ax = nx * 0.87 + tx * 0.5;
          final ay = ny * 0.87 + ty * 0.5;
          canvas.drawLine(
            Offset(cx - ax * halfW, cy - ay * halfW),
            Offset(cx + ax * halfW, cy + ay * halfW),
            tickPaint,
          );
        }
        dist += spacing;
      }
    }
  }

  /// Produces a dashed or dotted version of [source].
  static Path _dashPath(Path source, double width, LineStyle style,
      [double gap = 1.0]) {
    final on = style == LineStyle.dashed ? width * 5 : width;
    final off = (style == LineStyle.dashed ? width * 3 : width * 2) * gap;
    final result = Path();
    for (final metric in source.computeMetrics()) {
      var dist = 0.0;
      var drawing = true;
      while (dist < metric.length) {
        final seg = drawing ? on : off;
        if (drawing) {
          final end = (dist + seg).clamp(0.0, metric.length);
          result.addPath(metric.extractPath(dist, end), Offset.zero);
        }
        dist += seg;
        drawing = !drawing;
      }
    }
    return result;
  }

  @override
  bool shouldRepaint(covariant LayerPainter oldDelegate) {
    if (oldDelegate.layer != layer) return true;
    if (!identical(oldDelegate.strokes, strokes)) {
      cache.invalidate();
      return true;
    }
    if (!identical(oldDelegate.revealedTapeIds, revealedTapeIds) ||
        oldDelegate.tapeMode != tapeMode ||
        oldDelegate.tapeRevealedOpacity != tapeRevealedOpacity) {
      cache.invalidate();
      return true;
    }
    if (cache.picture == null) return true;
    return false;
  }
}
