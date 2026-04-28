// Paints the currently in-progress stroke. This is the only painter that
// repaints every frame while the user is drawing — committed strokes live
// in their layer's cached ui.Picture.

import 'package:flutter/material.dart';

import '../../../domain/stroke.dart';
import 'stroke_path.dart';

class ActiveStrokePainter extends CustomPainter {
  const ActiveStrokePainter({
    required this.points,
    required this.tool,
    required this.colorArgb,
    required this.widthPt,
    this.opacity = 1.0,
    this.lineStyle = LineStyle.solid,
    this.dashGap = 1.0,
  });

  final List<StrokePoint> points;
  final ToolKind tool;
  final int colorArgb;
  final double widthPt;
  final double opacity;
  final LineStyle lineStyle;
  final double dashGap;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;

    final rawPath = buildStrokePath(points);
    final path = lineStyle == LineStyle.solid
        ? rawPath
        : _dashPath(rawPath, widthPt, lineStyle, dashGap);

    if (tool == ToolKind.highlighter) {
      // The highlighter color carries its own alpha from the palette.
      // Use saveLayer so that self-overlapping parts of the in-progress
      // stroke don't accumulate opacity — the whole stroke is composited
      // as one transparent entity.
      final colorAlpha = Color(colorArgb).a * opacity;
      canvas.saveLayer(
        null,
        Paint()..color = Color.fromARGB(
            (colorAlpha * 255).round(), 255, 255, 255),
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = Color(colorArgb).withValues(alpha: 1.0)
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = widthPt
          ..blendMode = BlendMode.srcOver
          ..isAntiAlias = true,
      );
      canvas.restore();
      return;
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = Color(colorArgb).withValues(alpha: opacity)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = widthPt
        ..blendMode = BlendMode.srcOver
        ..isAntiAlias = true,
    );
  }

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
  bool shouldRepaint(covariant ActiveStrokePainter oldDelegate) => true;
}
