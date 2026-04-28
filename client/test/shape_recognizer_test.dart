import 'package:flutter_test/flutter_test.dart';

import 'package:notee/features/canvas/engine/shape_recognizer.dart';

void main() {
  test('rectangle regularize keeps top-left, becomes square (min side)', () {
    final r = regularize(const ShapeRect(10, 20, 110, 80), ShapeKind.rectangle);
    // min side is height = 60
    expect(r.minX, 10);
    expect(r.minY, 20);
    expect(r.width, 60);
    expect(r.height, 60);
  });

  test('ellipse regularize is centered square', () {
    final r = regularize(const ShapeRect(0, 0, 100, 50), ShapeKind.ellipse);
    expect(r.width, 50);
    expect(r.height, 50);
    // Center should be at original (50, 25)
    expect((r.minX + r.maxX) / 2, 50);
    expect((r.minY + r.maxY) / 2, 25);
  });

  test('triangle returns 3 points inscribed in square', () {
    final r = regularize(const ShapeRect(0, 0, 100, 100), ShapeKind.triangle);
    final pts = equilateralTrianglePoints(r);
    expect(pts.length, 3);
    expect(pts[0].y, r.maxY);
    expect(pts[1].y, r.maxY);
    expect(pts[2].y, r.minY);
  });
}
