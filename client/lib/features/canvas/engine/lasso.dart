// Pure-Dart geometry helpers for selection tools (rectangle and lasso).
//
// Kept dependency-free so they can be unit-tested without Flutter.

class Point2 {
  const Point2(this.x, this.y);
  final double x;
  final double y;
}

/// Ray-casting point-in-polygon test (even-odd rule).
/// [polygon] must have ≥ 3 distinct points; the polygon is treated as closed
/// (last → first edge implied).
bool pointInPolygon(Point2 p, List<Point2> polygon) {
  if (polygon.length < 3) return false;
  bool inside = false;
  final n = polygon.length;
  for (int i = 0, j = n - 1; i < n; j = i++) {
    final pi = polygon[i];
    final pj = polygon[j];
    final intersect = ((pi.y > p.y) != (pj.y > p.y)) &&
        (p.x <
            (pj.x - pi.x) * (p.y - pi.y) / ((pj.y - pi.y) + 1e-12) + pi.x);
    if (intersect) inside = !inside;
  }
  return inside;
}

/// Returns true iff [r1] intersects [r2] (rect bbox-vs-bbox).
bool rectsIntersect(
    double a0x, double a0y, double a1x, double a1y,
    double b0x, double b0y, double b1x, double b1y) {
  return a0x <= b1x && a1x >= b0x && a0y <= b1y && a1y >= b0y;
}

/// Returns true if a circle centered at (cx,cy) radius r intersects segment
/// (x1,y1)-(x2,y2). Used by the area-eraser disk-vs-segment broad phase.
bool circleIntersectsSegment(
    double cx, double cy, double r,
    double x1, double y1, double x2, double y2) {
  final dx = x2 - x1;
  final dy = y2 - y1;
  final lenSq = dx * dx + dy * dy;
  if (lenSq == 0) {
    final d2 = (cx - x1) * (cx - x1) + (cy - y1) * (cy - y1);
    return d2 <= r * r;
  }
  var t = ((cx - x1) * dx + (cy - y1) * dy) / lenSq;
  if (t < 0) {
    t = 0;
  } else if (t > 1) {
    t = 1;
  }
  final px = x1 + t * dx;
  final py = y1 + t * dy;
  final d2 = (cx - px) * (cx - px) + (cy - py) * (cy - py);
  return d2 <= r * r;
}
