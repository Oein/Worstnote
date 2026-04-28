// Draws the page background (blank / grid / ruled / dot / image / pdf).
//
// PDF and image kinds delegate to the [Import] feature for raster supply;
// in P0 we only implement the geometric backgrounds (blank, grid, ruled, dot)
// and stub the others.

import 'package:flutter/material.dart';

import '../../../domain/page_spec.dart';

class BackgroundPainter extends CustomPainter {
  const BackgroundPainter({required this.background});

  final PageBackground background;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = Colors.white);

    switch (background) {
      case BlankBackground():
        return;

      case GridBackground(:final spacingPt):
        final paint = Paint()
          ..color = const Color(0xFFE5E7EB)
          ..strokeWidth = 0.5;
        for (double x = spacingPt; x < size.width; x += spacingPt) {
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
        }
        for (double y = spacingPt; y < size.height; y += spacingPt) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
        }

      case RuledBackground(:final spacingPt):
        final paint = Paint()
          ..color = const Color(0xFFD1D5DB)
          ..strokeWidth = 0.5;
        for (double y = spacingPt; y < size.height; y += spacingPt) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
        }

      case DotBackground(:final spacingPt):
        final paint = Paint()..color = const Color(0xFFCBD5E1);
        for (double x = spacingPt; x < size.width; x += spacingPt) {
          for (double y = spacingPt; y < size.height; y += spacingPt) {
            canvas.drawCircle(Offset(x, y), 0.8, paint);
          }
        }

      case ImageBackground():
      case PdfBackground():
        // Rendered by import feature; placeholder here.
        return;
    }
  }

  @override
  bool shouldRepaint(covariant BackgroundPainter oldDelegate) =>
      oldDelegate.background != background;
}
