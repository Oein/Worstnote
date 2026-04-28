// Lightweight shape recognizer for the "draw, hold, snap" gesture (mobile)
// and Shift-snap (macOS). Given a stroke's bounding box and intended kind,
// returns the regularized rectangle to render: square, equilateral triangle
// inscribed in a square, or circle (square bbox).
//
// More sophisticated recognition (auto-classify free-form to △/□/○) lives
// in P4; this file is the snap geometry side that's stable enough to ship
// in P0 as a tested helper.

import 'lasso.dart';

enum ShapeKind { triangle, rectangle, ellipse }

class ShapeRect {
  const ShapeRect(this.minX, this.minY, this.maxX, this.maxY);
  final double minX, minY, maxX, maxY;
  double get width => maxX - minX;
  double get height => maxY - minY;
}

/// Snap the bbox to a regular form for [kind].
/// - rectangle → square (preserve top-left corner)
/// - ellipse   → circle (square bbox, preserve center)
/// - triangle  → equilateral fitted to a square bbox (preserve center)
ShapeRect regularize(ShapeRect r, ShapeKind kind) {
  final size = (r.width.abs() < r.height.abs()) ? r.width.abs() : r.height.abs();
  switch (kind) {
    case ShapeKind.rectangle:
      // Anchor at the original drag start corner: keep top-left.
      return ShapeRect(r.minX, r.minY, r.minX + size, r.minY + size);
    case ShapeKind.ellipse:
    case ShapeKind.triangle:
      // Center-preserving square.
      final cx = (r.minX + r.maxX) / 2;
      final cy = (r.minY + r.maxY) / 2;
      final h = size / 2;
      return ShapeRect(cx - h, cy - h, cx + h, cy + h);
  }
}

/// Returns the three points of an equilateral triangle inscribed in a square
/// bbox: bottom-left, bottom-right, top-center.
List<Point2> equilateralTrianglePoints(ShapeRect r) {
  return <Point2>[
    Point2(r.minX, r.maxY),
    Point2(r.maxX, r.maxY),
    Point2((r.minX + r.maxX) / 2, r.minY),
  ];
}
