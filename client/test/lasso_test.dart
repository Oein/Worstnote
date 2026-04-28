import 'package:flutter_test/flutter_test.dart';

import 'package:notee/features/canvas/engine/lasso.dart';

void main() {
  group('pointInPolygon', () {
    const square = [
      Point2(0, 0),
      Point2(10, 0),
      Point2(10, 10),
      Point2(0, 10),
    ];

    test('inside is true', () {
      expect(pointInPolygon(const Point2(5, 5), square), isTrue);
    });

    test('outside is false', () {
      expect(pointInPolygon(const Point2(20, 5), square), isFalse);
      expect(pointInPolygon(const Point2(-1, 5), square), isFalse);
    });

    test('handles concave shapes', () {
      // L-shape
      const l = [
        Point2(0, 0),
        Point2(10, 0),
        Point2(10, 5),
        Point2(5, 5),
        Point2(5, 10),
        Point2(0, 10),
      ];
      expect(pointInPolygon(const Point2(2, 2), l), isTrue); // inside main
      expect(pointInPolygon(const Point2(7, 7), l), isFalse); // in notch
    });
  });

  group('circleIntersectsSegment', () {
    test('endpoint inside', () {
      expect(circleIntersectsSegment(0, 0, 1.0, -2, 0, 0.5, 0), isTrue);
    });
    test('miss', () {
      expect(circleIntersectsSegment(0, 0, 0.5, 5, 5, 6, 6), isFalse);
    });
    test('grazes segment middle', () {
      expect(circleIntersectsSegment(5, 1, 1.0, 0, 0, 10, 0), isTrue);
    });
  });

  group('rectsIntersect', () {
    test('overlap', () {
      expect(rectsIntersect(0, 0, 5, 5, 3, 3, 8, 8), isTrue);
    });
    test('disjoint', () {
      expect(rectsIntersect(0, 0, 1, 1, 2, 2, 3, 3), isFalse);
    });
  });
}
