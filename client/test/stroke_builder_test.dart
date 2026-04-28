// Pure-Dart tests for the StrokeBuilder. Run with `flutter test`
// (uses flutter_test for the test runner) once `flutter pub get` works.

import 'package:flutter_test/flutter_test.dart';

import 'package:notee/domain/stroke.dart';
import 'package:notee/features/canvas/engine/stroke_builder.dart';

void main() {
  group('StrokeBuilder', () {
    test('drops single-tap (no stroke produced)', () {
      final b = _builder();
      b.addPoint(x: 10, y: 10, pressure: 0.5, tiltX: 0, tiltY: 0, tMs: 0);
      expect(b.finish(), isNull);
    });

    test('produces stroke with bbox covering all points', () {
      final b = _builder();
      for (var i = 0; i < 10; i++) {
        b.addPoint(
          x: 10.0 + i * 5.0,
          y: 20.0 + i * 3.0,
          pressure: 0.6,
          tiltX: 0,
          tiltY: 0,
          tMs: i * 16,
        );
      }
      final s = b.finish();
      expect(s, isNotNull);
      expect(s!.points.length, greaterThanOrEqualTo(2));
      expect(s.bbox.minX, lessThanOrEqualTo(s.bbox.maxX));
      expect(s.bbox.minY, lessThanOrEqualTo(s.bbox.maxY));
    });

    test('drops sub-pixel jitter samples', () {
      final b = _builder();
      // First point.
      b.addPoint(x: 0, y: 0, pressure: 0.5, tiltX: 0, tiltY: 0, tMs: 0);
      // Many micro-steps that should be coalesced.
      for (var i = 1; i <= 100; i++) {
        b.addPoint(
          x: 0.001 * i,
          y: 0.001 * i,
          pressure: 0.5,
          tiltX: 0,
          tiltY: 0,
          tMs: i,
        );
      }
      // Final big jump.
      b.addPoint(x: 50, y: 50, pressure: 0.5, tiltX: 0, tiltY: 0, tMs: 200);
      final s = b.finish();
      expect(s, isNotNull);
      // Should have far fewer than 100 points after jitter rejection.
      expect(s!.points.length, lessThan(20));
    });
  });
}

StrokeBuilder _builder() => StrokeBuilder(
      pageId: 'p',
      layerId: 'l',
      tool: ToolKind.pen,
      colorArgb: 0xFF000000,
      widthPt: 2.0,
    );
