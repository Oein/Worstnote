// V2: Resampling + turning-angle (curvature) shape recognizer.
//
// Pipeline (closed strokes):
//   1. Arc-length resample to N=64 points
//   2. Window-3 moving average smoothing
//   3. Turning angles (k=3 lookahead): atan2(cross, dot)
//   4. Corner peaks: |angle| >= ~35°, NMS window N/12
//   5. Total absolute turning, radial CV, edge-straightness check
//
// Each shape passes only when MULTIPLE independent criteria agree.
// A noisy square does not produce 5 corner peaks, so it cannot become a
// pentagon by accident — that is the structural fix vs. the v1 DP approach.

import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../../domain/stroke.dart';

enum DrawnShapeKind { line, circle, triangle, quad, pentagon, hexagon, star5 }

class DrawnShapeResult {
  const DrawnShapeResult(this.kind, this.points);
  final DrawnShapeKind kind;
  final List<StrokePoint> points;
}

/// Recognizes an open stroke as either a straight line or a smooth curve.
/// Used for pen/highlighter/tape "draw and hold" correction.
///
/// Returns non-null when the stroke is clean enough to idealize:
/// - straight line: maxDeviation < 10% of chord length
/// - smooth curve: no sharp kinks, sufficient length
///
/// [isStraight] distinguishes the two cases.
class LineOrCurveResult {
  const LineOrCurveResult({required this.isStraight, required this.points});
  final bool isStraight;
  final List<StrokePoint> points;
}

LineOrCurveResult? recognizeLineOrCurve(List<StrokePoint> pts) {
  if (pts.length < 6) return null;
  final os = pts.map((p) => Offset(p.x, p.y)).toList();
  final (minX, minY, maxX, maxY) = _bounds(os);
  final w = maxX - minX, h = maxY - minY;
  final diag = math.sqrt(w * w + h * h);
  if (diag < 10) return null;

  // 1. Try straight line first.
  final lineResult = _tryLine(os);
  if (lineResult != null) {
    return LineOrCurveResult(isStraight: true, points: lineResult.points);
  }

  // 2. Resample to uniform spacing for curve analysis.
  final resampled = _resample(os, 24);
  if (resampled.length < 8) return null;

  // 3. Check for sharp kinks — if any segment turns more than ~95°
  //    relative to the previous, the stroke is too chaotic to snap.
  const kinkThreshold = 1.65; // ~95° in radians
  for (var i = 1; i < resampled.length - 1; i++) {
    final v1x = resampled[i].dx - resampled[i - 1].dx;
    final v1y = resampled[i].dy - resampled[i - 1].dy;
    final v2x = resampled[i + 1].dx - resampled[i].dx;
    final v2y = resampled[i + 1].dy - resampled[i].dy;
    final cross = (v1x * v2y - v1y * v2x).abs();
    final dot = v1x * v2x + v1y * v2y;
    final angle = math.atan2(cross, dot.abs());
    if (angle > kinkThreshold) return null;
  }

  // 4. Smooth the resampled points (open-stroke moving average).
  const window = 5;
  const half = window ~/ 2;
  final n = resampled.length;
  final smoothed = <Offset>[];
  for (var i = 0; i < n; i++) {
    var sx = 0.0, sy = 0.0, cnt = 0;
    for (var j = math.max(0, i - half);
        j <= math.min(n - 1, i + half);
        j++) {
      sx += resampled[j].dx;
      sy += resampled[j].dy;
      cnt++;
    }
    smoothed.add(Offset(sx / cnt, sy / cnt));
  }

  final result = smoothed
      .map((o) => StrokePoint(x: o.dx, y: o.dy))
      .toList();
  return LineOrCurveResult(isStraight: false, points: result);
}

const int _kN = 64;
const double _kCornerThresh = 0.61; // ~35°
const double _kCircleCv = 0.13;
const double _kEdgeStraightTol = 0.085; // 8.5% of chord
const double _kStarTotalTurn = 4.5 * math.pi;
// Endpoints within this fraction of bbox-diagonal count as "closed enough"
// for polygon / circle / star detection. Larger = more forgiving.
const double _kClosedGapFrac = 0.40;

DrawnShapeResult? recognizeStroke(List<StrokePoint> pts) {
  if (pts.length < 8) return null;

  final os = pts.map((p) => Offset(p.x, p.y)).toList();
  final (minX, minY, maxX, maxY) = _bounds(os);
  final w = maxX - minX, h = maxY - minY;
  final diag = math.sqrt(w * w + h * h);
  if (diag < 12) return null;

  final gap = (os.first - os.last).distance;
  final isClosed = gap < diag * _kClosedGapFrac;

  if (!isClosed) {
    // First try: did the user trace most of a circle but fail to close?
    // If radii from centroid are uniform and angular sweep covers > 270°,
    // accept as circle even though the start/end gap is large.
    final openCircle = _tryOpenCircle(os, diag);
    if (openCircle != null) return openCircle;
    return _tryLine(os);
  }

  // Bridge the closure seam: interpolate points from os.last back to
  // os.first so circular smoothing/peak-finding doesn't see an artificial
  // discontinuity at the seam (the dominant source of spurious peaks).
  final bridged = _bridgeClosure(os, gap);

  // Resample + smooth.
  final resampled = _resample(bridged, _kN);
  if (resampled.length < _kN) return null;
  final smoothed = _smooth(resampled, 3);

  // Wide-window turning (k=3) for stable peak detection.
  final wideAngles = _turningAngles(smoothed, k: 3);
  final absAngles = wideAngles.map((a) => a.abs()).toList();
  // Single-segment turning (k=1) sums to true winding integral (2π for a
  // simple closed loop, 6π for a 5-pointed star). The k=3 sum overcounts.
  final segAngles = _turningAngles(smoothed, k: 1);
  final totalTurn = segAngles.fold<double>(0, (s, a) => s + a.abs());

  // Centroid + radii.
  final center = _centroid(smoothed);
  final radii = smoothed.map((p) => (p - center).distance).toList();
  final avgR = radii.reduce((a, b) => a + b) / radii.length;
  if (avgR < 6) return null;
  final variance =
      radii.map((r) => (r - avgR) * (r - avgR)).reduce((a, b) => a + b) /
          radii.length;
  final cv = math.sqrt(variance) / avgR;

  // Corner peaks (in resampled-index space).
  final peaks = _findPeaks(absAngles, _kCornerThresh, _kN ~/ 12);
  final n = peaks.length;

  // ── Circle ───────────────────────────────────────────────────────────
  // Low radial CV is the strongest circle signal. Allow up to 2 spurious
  // corner peaks (residual seam noise even after bridging), and accept
  // even more peaks when the radii are very uniform (cv < 0.10) — real
  // polygons can't be that round.
  if ((n <= 2 && cv < _kCircleCv) || (n <= 4 && cv < 0.10)) {
    return DrawnShapeResult(DrawnShapeKind.circle, _circlePoints(center, avgR));
  }

  // ── 5-pointed Star (radial-pattern detection) ───────────────────────
  // Check BEFORE polygon: a star has 5 outer + 5 inner radial extrema, which
  // is a stronger signal than corner-peak counting (the inner valleys are
  // sometimes too gentle to register as turning-angle peaks → was being
  // misclassified as pentagon). Require ≥5 corner peaks so a noisy triangle
  // can't masquerade as a star via random radii oscillation.
  if (peaks.length >= 5) {
    final star = _tryStarByRadii(smoothed, radii, center, avgR);
    if (star != null) return star;
  }

  // Fallback: corner-peak based star (covers very sharp star input).
  if (n >= 9 && n <= 11 && totalTurn > _kStarTotalTurn) {
    final s = _tryStar(smoothed, peaks, radii, center, avgR);
    if (s != null) return s;
  }

  // ── Polygon (3..6 corners) ──────────────────────────────────────────
  if (n >= 3 && n <= 6) {
    final straight = _edgesAreStraight(smoothed, peaks, _kEdgeStraightTol);
    if (straight) {
      // Use mean radius at corners for a tighter fit.
      final cornerR = peaks.map((i) => radii[i]).reduce((a, b) => a + b) /
          peaks.length;
      final firstCorner = smoothed[peaks.first];
      var startAngle = math.atan2(
        firstCorner.dy - center.dy,
        firstCorner.dx - center.dx,
      );
      // Snap a slightly tilted polygon to its canonical orientation.
      startAngle = _snapPolygonAngle(startAngle, n);
      final kind = const [
        DrawnShapeKind.triangle,
        DrawnShapeKind.quad,
        DrawnShapeKind.pentagon,
        DrawnShapeKind.hexagon,
      ][n - 3];
      return DrawnShapeResult(
        kind,
        _regularPolygon(center, cornerR, n, startAngle),
      );
    }
  }

  return null;
}

// Snap a polygon's first-vertex angle to the canonical orientation when the
// drawn angle is within ±15° of axis-alignment (modulo n-fold symmetry).
double _snapPolygonAngle(double startAngle, int n) {
  // Canonical first-vertex angle for each polygon — chosen so the shape
  // looks "upright" / axis-aligned.
  const canonicals = <int, double>{
    3: -math.pi / 2, // triangle: top vertex points up
    4: -math.pi / 4, // square: edges horizontal & vertical
    5: -math.pi / 2, // pentagon: top vertex points up
    6: 0.0, // hexagon: flat top (vertex on right)
  };
  final c = canonicals[n] ?? 0.0;
  final step = 2 * math.pi / n;
  // Distance from startAngle to the nearest c + k*step.
  var diff = (startAngle - c) % step;
  if (diff > step / 2) diff -= step;
  if (diff < -step / 2) diff += step;
  const tol = 15 * math.pi / 180; // 15°
  if (diff.abs() < tol) {
    return startAngle - diff;
  }
  return startAngle;
}

// ── Open-stroke circle detection ────────────────────────────────────────
//
// User drew most of a circle but didn't close it cleanly. If the radii from
// the centroid are uniform AND the angular sweep covers most of the circle,
// snap to a perfect circle anyway.
DrawnShapeResult? _tryOpenCircle(List<Offset> os, double diag) {
  final resampled = _resample(os, _kN);
  if (resampled.length < _kN) return null;
  final smoothed = _smooth(resampled, 3);
  final center = _centroid(smoothed);
  final radii = smoothed.map((p) => (p - center).distance).toList();
  final avgR = radii.reduce((a, b) => a + b) / radii.length;
  if (avgR < 6) return null;
  final variance =
      radii.map((r) => (r - avgR) * (r - avgR)).reduce((a, b) => a + b) /
          radii.length;
  final cv = math.sqrt(variance) / avgR;
  // Slightly looser CV than the closed-circle gate.
  if (cv > 0.18) return null;

  // Total signed angular sweep around centroid.
  var sweep = 0.0;
  for (var i = 1; i < smoothed.length; i++) {
    final p1 = smoothed[i - 1] - center;
    final p2 = smoothed[i] - center;
    final cross = p1.dx * p2.dy - p1.dy * p2.dx;
    final dot = p1.dx * p2.dx + p1.dy * p2.dy;
    sweep += math.atan2(cross, dot);
  }
  // Need at least 270° of arc to call it a circle.
  if (sweep.abs() < 270 * math.pi / 180) return null;

  return DrawnShapeResult(DrawnShapeKind.circle, _circlePoints(center, avgR));
}

// ── Star-by-radial-pattern ──────────────────────────────────────────────
//
// A 5-pointed star has 5 outer peaks AND 5 inner troughs in the radius-
// versus-arc-length signal. This works even when the inner concavities are
// too gentle to be detected as turning-angle corners (which was the cause
// of star→pentagon misclassification).
DrawnShapeResult? _tryStarByRadii(
  List<Offset> smoothed,
  List<double> radii,
  Offset center,
  double avgR,
) {
  // Local maxima / minima in the closed-loop radii signal. NMS to avoid
  // double-counting wiggles. A 5-pointed star is uniquely identified by
  // EXACTLY 5 outer peaks and 5 inner troughs — squares have 4+4,
  // hexagons have 6+6, etc.
  final n = radii.length;
  final hi = avgR * 1.03;
  final lo = avgR * 0.97;
  final negRadii = radii.map((r) => -r).toList();
  final maxima = _findPeaks(radii, hi, n ~/ 12);
  final minima = _findPeaks(negRadii, -lo, n ~/ 12);
  if (maxima.length != 5 || minima.length != 5) return null;

  // Verify alternation by sorting indices and walking.
  final all = <int>[...maxima, ...minima]..sort();
  final isMax = {for (final i in maxima) i: true, for (final i in minima) i: false};
  for (var i = 1; i < all.length; i++) {
    if (isMax[all[i]] == isMax[all[i - 1]]) return null;
  }

  final ro = maxima.map((i) => radii[i]).reduce((a, b) => a + b) / maxima.length;
  final ri = minima.map((i) => radii[i]).reduce((a, b) => a + b) / minima.length;
  if (ri < 1e-6) return null;
  final ratio = ro / ri;
  if (ratio < 1.3 || ratio > 4.0) return null;

  // Start angle from the strongest outer peak.
  final firstOuter = maxima.reduce((a, b) => radii[a] >= radii[b] ? a : b);
  final fp = smoothed[firstOuter];
  final startAngle = math.atan2(fp.dy - center.dy, fp.dx - center.dx);

  return DrawnShapeResult(
    DrawnShapeKind.star5,
    _starPoints(center, ro, ri, startAngle),
  );
}

// ── Line ────────────────────────────────────────────────────────────────

DrawnShapeResult? _tryLine(List<Offset> os) {
  final a = os.first, b = os.last;
  final dist = (b - a).distance;
  if (dist < 10) return null;

  double maxDev = 0;
  for (final p in os) {
    final d = _ptLineDist(p, a, b);
    if (d > maxDev) maxDev = d;
  }
  if (maxDev / dist > 0.10) return null;

  return DrawnShapeResult(DrawnShapeKind.line, [
    StrokePoint(x: a.dx, y: a.dy),
    StrokePoint(x: b.dx, y: b.dy),
  ]);
}

// ── Star helper ─────────────────────────────────────────────────────────

DrawnShapeResult? _tryStar(
  List<Offset> smoothed,
  List<int> peaks,
  List<double> radii,
  Offset center,
  double avgR,
) {
  // Classify each peak as outer (>avg) or inner (<avg).
  final outerR = <double>[];
  final innerR = <double>[];
  for (final i in peaks) {
    if (radii[i] > avgR) {
      outerR.add(radii[i]);
    } else {
      innerR.add(radii[i]);
    }
  }
  if (outerR.length < 4 || innerR.length < 4) return null;
  if ((outerR.length - innerR.length).abs() > 2) return null;

  final ro = outerR.reduce((a, b) => a + b) / outerR.length;
  final ri = innerR.reduce((a, b) => a + b) / innerR.length;
  if (ri < 1e-6) return null;
  final ratio = ro / ri;
  if (ratio < 1.5 || ratio > 3.5) return null;

  // Start angle from first outer peak.
  int firstOuter = peaks.first;
  for (final i in peaks) {
    if (radii[i] > avgR) {
      firstOuter = i;
      break;
    }
  }
  final fp = smoothed[firstOuter];
  final startAngle = math.atan2(fp.dy - center.dy, fp.dx - center.dx);

  return DrawnShapeResult(
    DrawnShapeKind.star5,
    _starPoints(center, ro, ri, startAngle),
  );
}

// ── Geometry helpers ────────────────────────────────────────────────────

(double, double, double, double) _bounds(List<Offset> os) {
  var minX = os[0].dx, maxX = os[0].dx;
  var minY = os[0].dy, maxY = os[0].dy;
  for (final o in os) {
    if (o.dx < minX) minX = o.dx;
    if (o.dx > maxX) maxX = o.dx;
    if (o.dy < minY) minY = o.dy;
    if (o.dy > maxY) maxY = o.dy;
  }
  return (minX, minY, maxX, maxY);
}

Offset _centroid(List<Offset> os) {
  var sx = 0.0, sy = 0.0;
  for (final o in os) {
    sx += o.dx;
    sy += o.dy;
  }
  return Offset(sx / os.length, sy / os.length);
}

double _ptLineDist(Offset p, Offset a, Offset b) {
  final dx = b.dx - a.dx, dy = b.dy - a.dy;
  final len2 = dx * dx + dy * dy;
  if (len2 == 0) return (p - a).distance;
  final t = ((p.dx - a.dx) * dx + (p.dy - a.dy) * dy) / len2;
  final proj = Offset(a.dx + t * dx, a.dy + t * dy);
  return (p - proj).distance;
}

/// Append interpolated points from os.last → os.first so circular operations
/// (smoothing, peak-finding) don't see a discontinuity at the closure seam.
List<Offset> _bridgeClosure(List<Offset> os, double gap) {
  if (gap < 1) return os;
  final a = os.last, b = os.first;
  final extra = math.max(2, (gap / 3).round());
  final out = List<Offset>.from(os);
  for (var i = 1; i < extra; i++) {
    final t = i / extra;
    out.add(Offset(a.dx + t * (b.dx - a.dx), a.dy + t * (b.dy - a.dy)));
  }
  return out;
}

List<Offset> _resample(List<Offset> pts, int n) {
  if (pts.length < 2) return List.of(pts);
  // Total path length.
  double total = 0.0;
  for (var i = 1; i < pts.length; i++) {
    total += (pts[i] - pts[i - 1]).distance;
  }
  if (total <= 0) return List.of(pts);

  final step = total / (n - 1);
  final out = <Offset>[pts.first];
  double accumulated = 0.0;
  var i = 1;
  var prev = pts[0];

  while (out.length < n && i < pts.length) {
    final curr = pts[i];
    final segLen = (curr - prev).distance;
    if (segLen < 1e-9) {
      i++;
      continue;
    }
    if (accumulated + segLen >= step) {
      final t = (step - accumulated) / segLen;
      final q = Offset(
        prev.dx + t * (curr.dx - prev.dx),
        prev.dy + t * (curr.dy - prev.dy),
      );
      out.add(q);
      prev = q;
      accumulated = 0.0;
    } else {
      accumulated += segLen;
      prev = curr;
      i++;
    }
  }
  while (out.length < n) {
    out.add(pts.last);
  }
  return out;
}

List<Offset> _smooth(List<Offset> pts, int window) {
  // Closed-loop moving average.
  final n = pts.length;
  final half = window ~/ 2;
  final out = <Offset>[];
  for (var i = 0; i < n; i++) {
    var sx = 0.0, sy = 0.0;
    for (var j = -half; j <= half; j++) {
      final p = pts[(i + j + n) % n];
      sx += p.dx;
      sy += p.dy;
    }
    out.add(Offset(sx / window, sy / window));
  }
  return out;
}

List<double> _turningAngles(List<Offset> pts, {required int k}) {
  final n = pts.length;
  final out = List<double>.filled(n, 0.0);
  for (var i = 0; i < n; i++) {
    final a = pts[(i - k + n) % n];
    final b = pts[i];
    final c = pts[(i + k) % n];
    final v1x = b.dx - a.dx, v1y = b.dy - a.dy;
    final v2x = c.dx - b.dx, v2y = c.dy - b.dy;
    final cross = v1x * v2y - v1y * v2x;
    final dot = v1x * v2x + v1y * v2y;
    out[i] = math.atan2(cross, dot);
  }
  return out;
}

/// Find peaks of |arr|: local maxima above [minVal] with non-max suppression
/// in [nmsWindow] radius. Treats the array as circular.
List<int> _findPeaks(List<double> arr, double minVal, int nmsWindow) {
  final n = arr.length;
  // Sort indices by value descending; greedily keep peaks not within
  // nmsWindow of an already-kept stronger peak.
  final candidates = <int>[];
  for (var i = 0; i < n; i++) {
    if (arr[i] >= minVal) candidates.add(i);
  }
  candidates.sort((a, b) => arr[b].compareTo(arr[a]));
  final kept = <int>[];
  for (final i in candidates) {
    var ok = true;
    for (final j in kept) {
      // Circular distance.
      final d = (i - j).abs();
      final cd = d < n - d ? d : n - d;
      if (cd <= nmsWindow) {
        ok = false;
        break;
      }
    }
    if (ok) kept.add(i);
  }
  kept.sort();
  return kept;
}

bool _edgesAreStraight(List<Offset> pts, List<int> corners, double tol) {
  final n = pts.length;
  final m = corners.length;
  for (var k = 0; k < m; k++) {
    final a = corners[k];
    final b = corners[(k + 1) % m];
    // Walk i = a+1..b-1 (mod n), measure perpendicular distance to chord ab.
    final pa = pts[a], pb = pts[b];
    final chord = (pb - pa).distance;
    if (chord < 1e-6) continue;
    var maxD = 0.0;
    var i = (a + 1) % n;
    var safety = 0;
    while (i != b && safety++ < n) {
      final d = _ptLineDist(pts[i], pa, pb);
      if (d > maxD) maxD = d;
      i = (i + 1) % n;
    }
    if (maxD / chord > tol) return false;
  }
  return true;
}

// ── Perfect shape generators ────────────────────────────────────────────

List<StrokePoint> _regularPolygon(
  Offset center,
  double radius,
  int n,
  double startAngle,
) {
  final result = <StrokePoint>[];
  for (var i = 0; i <= n; i++) {
    final a = startAngle + (i % n) * 2 * math.pi / n;
    result.add(StrokePoint(
      x: center.dx + radius * math.cos(a),
      y: center.dy + radius * math.sin(a),
    ));
  }
  return result;
}

List<StrokePoint> _circlePoints(
  Offset center,
  double radius, {
  int segments = 80,
}) {
  final result = <StrokePoint>[];
  for (var i = 0; i <= segments; i++) {
    final a = (i % segments) * 2 * math.pi / segments;
    result.add(StrokePoint(
      x: center.dx + radius * math.cos(a),
      y: center.dy + radius * math.sin(a),
    ));
  }
  return result;
}

List<StrokePoint> _starPoints(
  Offset center,
  double outerR,
  double innerR,
  double startAngle,
) {
  const n = 5;
  final result = <StrokePoint>[];
  for (var i = 0; i <= n * 2; i++) {
    final a = startAngle + i * math.pi / n;
    final r = i.isEven ? outerR : innerR;
    result.add(StrokePoint(
      x: center.dx + r * math.cos(a),
      y: center.dy + r * math.sin(a),
    ));
  }
  return result;
}
