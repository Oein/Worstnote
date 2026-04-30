// Shared utility for building a Path from StrokePoint lists.
// Uses quadratic Bézier curves through midpoints for C¹ smooth splines.

import 'package:flutter/painting.dart';

import '../../../domain/stroke.dart';

Path buildStrokePath(List<StrokePoint> points) {
  if (points.isEmpty) return Path();
  final path = Path()..moveTo(points.first.x, points.first.y);
  if (points.length == 2) {
    path.lineTo(points.last.x, points.last.y);
    return path;
  }

  // Move to midpoint of the first segment (first on-curve anchor).
  path.lineTo(
    (points[0].x + points[1].x) / 2,
    (points[0].y + points[1].y) / 2,
  );

  // For each interior sample: draw a quadratic Bézier whose control point
  // is the sample itself and whose endpoint is the midpoint to the next
  // sample.  Consecutive curves share tangents at every midpoint → C¹.
  for (int i = 1; i < points.length - 1; i++) {
    path.quadraticBezierTo(
      points[i].x,
      points[i].y,
      (points[i].x + points[i + 1].x) / 2,
      (points[i].y + points[i + 1].y) / 2,
    );
  }

  // Connect to the actual last point.
  path.lineTo(points.last.x, points.last.y);
  return path;
}
