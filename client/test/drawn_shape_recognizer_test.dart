// Synthetic-stroke verification of recognizeStroke.
//
// Each test generates a List<StrokePoint> for a known shape (perfect or
// jittered with a seeded Random), runs the recognizer, and asserts the
// classification. Run with `flutter test test/drawn_shape_recognizer_v2_test.dart`.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:notee/domain/stroke.dart';
import 'package:notee/features/canvas/engine/drawn_shape_recognizer.dart';

void main() {
  group('recognizeStroke', () {
    test('1. perfect line', () {
      final pts = _genLine(100, 100, 300, 280, 50, 0, 1);
      final r = recognizeStroke(pts);
      expect(r?.kind, DrawnShapeKind.line);
    });

    test('2. wobbly line (3% noise)', () {
      final pts = _genLine(100, 100, 300, 280, 60, 0.03, 2);
      final r = recognizeStroke(pts);
      expect(r?.kind, DrawnShapeKind.line);
    });

    test('3. open quarter-arc → null', () {
      final pts = _genArc(200, 200, 80, 0, math.pi / 2, 40, 0, 3);
      final r = recognizeStroke(pts);
      expect(r, isNull);
    });

    test('4. perfect circle', () {
      final pts = _genCircle(200, 200, 80, 200, 0, 4);
      final r = recognizeStroke(pts);
      expect(r?.kind, DrawnShapeKind.circle);
    });

    test('5. circle 5% radial jitter', () {
      final pts = _genCircle(200, 200, 80, 160, 0.05, 5);
      final r = recognizeStroke(pts);
      expect(r?.kind, DrawnShapeKind.circle);
    });

    test('6. wobbly oval never becomes polygon', () {
      final pts = _genEllipse(200, 200, 100, 60, 120, 0.08, 6);
      final r = recognizeStroke(pts);
      // Either circle or null is acceptable — but never a polygon.
      expect(
        r?.kind,
        anyOf(equals(DrawnShapeKind.circle), isNull),
      );
    });

    test('7. perfect equilateral triangle', () {
      final pts = _genPolygon(200, 200, 100, 3, 30, 0, 7, startDeg: -90);
      final r = recognizeStroke(pts);
      expect(r?.kind, DrawnShapeKind.triangle);
    });

    test('8. triangle 5% edge noise', () {
      final pts = _genPolygon(200, 200, 100, 3, 36, 0.04, 8, startDeg: -90);
      final r = recognizeStroke(pts);
      expect(r?.kind, DrawnShapeKind.triangle);
    });

    test('9. perfect axis-aligned square', () {
      final pts = _genPolygon(200, 200, 100, 4, 40, 0, 9, startDeg: -45);
      final r = recognizeStroke(pts);
      expect(r?.kind, DrawnShapeKind.quad);
    });

    test('10. square 4% noise + corner overshoot is NOT a pentagon', () {
      final pts = _genPolygon(200, 200, 100, 4, 60, 0.04, 10, startDeg: -45);
      final r = recognizeStroke(pts);
      expect(r?.kind, DrawnShapeKind.quad);
    });

    test('11. tall narrow rectangle (3:1)', () {
      final pts = _genRect(200, 200, 60, 180, 60, 0.02, 11);
      final r = recognizeStroke(pts);
      expect(r?.kind, DrawnShapeKind.quad);
    });

    test('12. perfect regular pentagon', () {
      final pts = _genPolygon(200, 200, 100, 5, 50, 0, 12, startDeg: -90);
      final r = recognizeStroke(pts);
      expect(r?.kind, DrawnShapeKind.pentagon);
    });

    test('13. perfect regular hexagon', () {
      final pts = _genPolygon(200, 200, 100, 6, 60, 0, 13, startDeg: 0);
      final r = recognizeStroke(pts);
      expect(r?.kind, DrawnShapeKind.hexagon);
    });

    test('14. perfect 5-pointed star', () {
      final pts = _genStar(200, 200, 100, 42, 60, 0, 14);
      final r = recognizeStroke(pts);
      expect(r?.kind, DrawnShapeKind.star5);
    });

    test('15. jittered 5-pointed star', () {
      final pts = _genStar(200, 200, 100, 42, 60, 0.03, 15);
      final r = recognizeStroke(pts);
      expect(r?.kind, DrawnShapeKind.star5);
    });

    test('16. random closed squiggle → null', () {
      final pts = _genSquiggle(200, 200, 80, 100, 16);
      final r = recognizeStroke(pts);
      expect(r?.kind, isNot(DrawnShapeKind.circle));
      // We accept null OR a non-confident classification; main thing is
      // we don't snap arbitrary scribbles to neat polygons.
      // For this test we strictly require null:
      expect(r, isNull);
    });

    test('17. tiny stroke → null', () {
      final pts = _genCircle(50, 50, 4, 60, 0, 17);
      final r = recognizeStroke(pts);
      expect(r, isNull);
    });

    test('18. unclosed circle (~330° sweep) → circle', () {
      final pts = _genArc(200, 200, 80, 0, 330 * math.pi / 180, 80, 0, 18);
      final r = recognizeStroke(pts);
      expect(r?.kind, DrawnShapeKind.circle);
    });

    test('19. soft 5-star (gentle inner valleys) → star5', () {
      final pts = _genStar(200, 200, 100, 65, 80, 0, 19);
      final r = recognizeStroke(pts);
      expect(r?.kind, DrawnShapeKind.star5);
    });

    test('21. sloppy square (endpoint 25% off) → quad', () {
      final pts = _genPolygon(200, 200, 100, 4, 60, 0, 21, startDeg: -45);
      // Drop the final closing point and trim ~3 pts so gap is large.
      pts.removeLast();
      pts.removeLast();
      pts.removeLast();
      pts.removeLast();
      final r = recognizeStroke(pts);
      expect(r?.kind, DrawnShapeKind.quad);
    });

    test('22. sloppy triangle (endpoint 20% off) → triangle', () {
      final pts = _genPolygon(200, 200, 100, 3, 36, 0, 22, startDeg: -90);
      pts.removeLast();
      pts.removeLast();
      pts.removeLast();
      final r = recognizeStroke(pts);
      expect(r?.kind, DrawnShapeKind.triangle);
    });

    test('20. tilted square (10°) snaps to axis-aligned', () {
      final pts = _genPolygon(
        200, 200, 100, 4, 60, 0, 20,
        startDeg: -45 + 10,
      );
      final r = recognizeStroke(pts);
      expect(r?.kind, DrawnShapeKind.quad);
      final first = r!.points.first;
      expect((first.x - 270.71).abs() < 5, isTrue,
          reason: 'first.x=${first.x} not near 270.71');
      expect((first.y - 129.29).abs() < 5, isTrue,
          reason: 'first.y=${first.y} not near 129.29');
    });
  });
}

// ── Synthetic generators ────────────────────────────────────────────────

List<StrokePoint> _genLine(
  double x0,
  double y0,
  double x1,
  double y1,
  int n,
  double noise,
  int seed,
) {
  final rng = math.Random(seed);
  final dx = x1 - x0, dy = y1 - y0;
  final len = math.sqrt(dx * dx + dy * dy);
  // Perpendicular unit vector.
  final px = -dy / len, py = dx / len;
  final out = <StrokePoint>[];
  for (var i = 0; i < n; i++) {
    final t = i / (n - 1);
    final jitter = (rng.nextDouble() - 0.5) * 2 * noise * len;
    out.add(StrokePoint(
      x: x0 + dx * t + px * jitter,
      y: y0 + dy * t + py * jitter,
    ));
  }
  return out;
}

List<StrokePoint> _genArc(
  double cx,
  double cy,
  double r,
  double startRad,
  double sweepRad,
  int n,
  double noise,
  int seed,
) {
  final rng = math.Random(seed);
  final out = <StrokePoint>[];
  for (var i = 0; i < n; i++) {
    final t = i / (n - 1);
    final a = startRad + sweepRad * t;
    final rr = r * (1 + (rng.nextDouble() - 0.5) * 2 * noise);
    out.add(StrokePoint(x: cx + rr * math.cos(a), y: cy + rr * math.sin(a)));
  }
  return out;
}

List<StrokePoint> _genCircle(
  double cx,
  double cy,
  double r,
  int n,
  double noise,
  int seed,
) {
  final rng = math.Random(seed);
  final out = <StrokePoint>[];
  for (var i = 0; i < n; i++) {
    final a = 2 * math.pi * i / n;
    final rr = r * (1 + (rng.nextDouble() - 0.5) * 2 * noise);
    out.add(StrokePoint(x: cx + rr * math.cos(a), y: cy + rr * math.sin(a)));
  }
  // Close the loop back to start so isClosed kicks in.
  out.add(out.first);
  return out;
}

List<StrokePoint> _genEllipse(
  double cx,
  double cy,
  double rx,
  double ry,
  int n,
  double noise,
  int seed,
) {
  final rng = math.Random(seed);
  final out = <StrokePoint>[];
  for (var i = 0; i < n; i++) {
    final a = 2 * math.pi * i / n;
    final jx = (rng.nextDouble() - 0.5) * 2 * noise * rx;
    final jy = (rng.nextDouble() - 0.5) * 2 * noise * ry;
    out.add(StrokePoint(
      x: cx + rx * math.cos(a) + jx,
      y: cy + ry * math.sin(a) + jy,
    ));
  }
  out.add(out.first);
  return out;
}

List<StrokePoint> _genPolygon(
  double cx,
  double cy,
  double r,
  int sides,
  int totalPts,
  double noise,
  int seed, {
  double startDeg = 0,
}) {
  final rng = math.Random(seed);
  final start = startDeg * math.pi / 180;
  // Compute corner positions, then evenly interpolate along each edge.
  final corners = <Offset>[];
  for (var k = 0; k < sides; k++) {
    final a = start + 2 * math.pi * k / sides;
    corners.add(Offset(cx + r * math.cos(a), cy + r * math.sin(a)));
  }
  final perEdge = totalPts ~/ sides;
  final out = <StrokePoint>[];
  for (var k = 0; k < sides; k++) {
    final a = corners[k];
    final b = corners[(k + 1) % sides];
    for (var j = 0; j < perEdge; j++) {
      final t = j / perEdge;
      final edgeLen = (b - a).distance;
      final jitter = (rng.nextDouble() - 0.5) * 2 * noise * edgeLen;
      // Perpendicular to edge.
      final dx = b.dx - a.dx, dy = b.dy - a.dy;
      final px = -dy / edgeLen, py = dx / edgeLen;
      out.add(StrokePoint(
        x: a.dx + dx * t + px * jitter,
        y: a.dy + dy * t + py * jitter,
      ));
    }
  }
  out.add(StrokePoint(x: corners[0].dx, y: corners[0].dy));
  return out;
}

List<StrokePoint> _genRect(
  double cx,
  double cy,
  double w,
  double h,
  int totalPts,
  double noise,
  int seed,
) {
  final rng = math.Random(seed);
  final corners = [
    Offset(cx - w / 2, cy - h / 2),
    Offset(cx + w / 2, cy - h / 2),
    Offset(cx + w / 2, cy + h / 2),
    Offset(cx - w / 2, cy + h / 2),
  ];
  final perEdge = totalPts ~/ 4;
  final out = <StrokePoint>[];
  for (var k = 0; k < 4; k++) {
    final a = corners[k];
    final b = corners[(k + 1) % 4];
    final edgeLen = (b - a).distance;
    final dx = b.dx - a.dx, dy = b.dy - a.dy;
    final px = -dy / edgeLen, py = dx / edgeLen;
    for (var j = 0; j < perEdge; j++) {
      final t = j / perEdge;
      final jitter = (rng.nextDouble() - 0.5) * 2 * noise * edgeLen;
      out.add(StrokePoint(
        x: a.dx + dx * t + px * jitter,
        y: a.dy + dy * t + py * jitter,
      ));
    }
  }
  out.add(StrokePoint(x: corners[0].dx, y: corners[0].dy));
  return out;
}

List<StrokePoint> _genStar(
  double cx,
  double cy,
  double outerR,
  double innerR,
  int totalPts,
  double noise,
  int seed,
) {
  final rng = math.Random(seed);
  // 10 vertices alternating outer/inner.
  const v = 10;
  final verts = <Offset>[];
  for (var k = 0; k < v; k++) {
    final r = k.isEven ? outerR : innerR;
    final a = -math.pi / 2 + 2 * math.pi * k / v;
    verts.add(Offset(cx + r * math.cos(a), cy + r * math.sin(a)));
  }
  final perEdge = totalPts ~/ v;
  final out = <StrokePoint>[];
  for (var k = 0; k < v; k++) {
    final a = verts[k];
    final b = verts[(k + 1) % v];
    final edgeLen = (b - a).distance;
    final dx = b.dx - a.dx, dy = b.dy - a.dy;
    final px = -dy / edgeLen, py = dx / edgeLen;
    for (var j = 0; j < perEdge; j++) {
      final t = j / perEdge;
      final jitter = (rng.nextDouble() - 0.5) * 2 * noise * edgeLen;
      out.add(StrokePoint(
        x: a.dx + dx * t + px * jitter,
        y: a.dy + dy * t + py * jitter,
      ));
    }
  }
  out.add(StrokePoint(x: verts[0].dx, y: verts[0].dy));
  return out;
}

List<StrokePoint> _genSquiggle(
  double cx,
  double cy,
  double r,
  int n,
  int seed,
) {
  final rng = math.Random(seed);
  final out = <StrokePoint>[];
  // Random walk that returns near origin at end.
  var x = cx, y = cy;
  for (var i = 0; i < n; i++) {
    final t = i / n;
    // Bias toward returning to start by the end.
    final tx = cx + r * math.cos(2 * math.pi * t * 1.5);
    final ty = cy + r * math.sin(2 * math.pi * t * 2.3);
    final jx = (rng.nextDouble() - 0.5) * r * 0.4;
    final jy = (rng.nextDouble() - 0.5) * r * 0.4;
    x = tx + jx;
    y = ty + jy;
    out.add(StrokePoint(x: x, y: y));
  }
  // Close.
  out.add(out.first);
  return out;
}
