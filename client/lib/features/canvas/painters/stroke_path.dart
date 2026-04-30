// Shared utility for building a Path from StrokePoint lists.
// Uses Catmull-Rom spline so every recorded point lies exactly on the curve,
// preserving direction changes (e.g. corners in handwriting) while remaining
// C¹ smooth between samples.

import 'package:flutter/painting.dart';

import '../../../domain/stroke.dart';

Path buildStrokePath(List<StrokePoint> points) {
  if (points.isEmpty) return Path();
  final path = Path()..moveTo(points.first.x, points.first.y);
  if (points.length == 2) {
    path.lineTo(points.last.x, points.last.y);
    return path;
  }

  // Catmull-Rom → cubic Bézier conversion.
  // For each segment i→i+1, control points are derived from the four
  // surrounding samples so the curve passes through every sample point.
  // Phantom points mirror the first/last segment to handle endpoints.
  final n = points.length;
  for (int i = 0; i < n - 1; i++) {
    final p0 = i == 0 ? _mirror(points[1], points[0]) : points[i - 1];
    final p1 = points[i];
    final p2 = points[i + 1];
    final p3 = i + 2 < n ? points[i + 2] : _mirror(points[n - 2], points[n - 1]);

    // Catmull-Rom control points (tension = 0.5).
    final cp1x = p1.x + (p2.x - p0.x) / 6.0;
    final cp1y = p1.y + (p2.y - p0.y) / 6.0;
    final cp2x = p2.x - (p3.x - p1.x) / 6.0;
    final cp2y = p2.y - (p3.y - p1.y) / 6.0;

    path.cubicTo(cp1x, cp1y, cp2x, cp2y, p2.x, p2.y);
  }

  return path;
}

// Returns a phantom point mirrored across [anchor] from [neighbor].
StrokePoint _mirror(StrokePoint neighbor, StrokePoint anchor) {
  return StrokePoint(
    x: 2 * anchor.x - neighbor.x,
    y: 2 * anchor.y - neighbor.y,
    pressure: anchor.pressure,
    tiltX: anchor.tiltX,
    tiltY: anchor.tiltY,
    tMs: anchor.tMs,
  );
}
