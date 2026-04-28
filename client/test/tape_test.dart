// Tape semantics: it's a stroke (ToolKind.tape). The CanvasView holds a
// runtime Set<String> of "revealed" tape ids to flip render alpha between
// 100% and 10%. This test verifies hit-testing logic against tape strokes.

import 'package:flutter_test/flutter_test.dart';

import 'package:notee/domain/stroke.dart';
import 'package:notee/features/canvas/engine/lasso.dart';

Stroke _tapeStroke({
  required String id,
  required List<(double, double)> pts,
  double width = 24,
}) {
  final points = [
    for (final p in pts)
      StrokePoint(x: p.$1, y: p.$2, pressure: 0.5, tiltX: 0, tiltY: 0, tMs: 0),
  ];
  return Stroke(
    id: id,
    pageId: 'p',
    layerId: 'l',
    tool: ToolKind.tape,
    colorArgb: 0xFFFFCC80,
    widthPt: width,
    opacity: 1,
    points: points,
    bbox: Bbox.fromPoints(points),
    createdAt: DateTime.utc(2026, 1, 1),
  );
}

void main() {
  test('tape stroke has tool == ToolKind.tape', () {
    final s = _tapeStroke(id: 't1', pts: const [(0, 0), (50, 0)]);
    expect(s.tool, ToolKind.tape);
  });

  test('tap-on-tape hit zone covers stroke width', () {
    // A 24pt-thick tape stroke from (0,0) to (100,0) — verify a tap close to
    // the line hits, far from the line misses.
    // A tap at (50, 8) should intersect the stroke (8pt above the line, with
    // half-width 12).
    expect(
      circleIntersectsSegment(50, 8, 12 + 4, 0, 0, 100, 0),
      isTrue,
    );
    // A tap at (50, 50) clearly misses.
    expect(
      circleIntersectsSegment(50, 50, 12 + 4, 0, 0, 100, 0),
      isFalse,
    );
  });
}
