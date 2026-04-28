// Custom 16px stroke icons matching the design handoff. Each icon is a
// CustomPainter so we can recolor at runtime and stay crisp at any size.

import 'package:flutter/material.dart';

enum NoteeIcon {
  pen,
  highlight,
  eraser,
  lasso,
  shape,
  text,
  undo,
  redo,
  page,
  search,
  plus,
  grid,
  rows,
  chev,
  left,
  gear,
  share,
  star,
  folder,
  home,
  mic,
  check,
  layers,
  tape,
  dot,
  // Pen-only / palm-rejection toggle (matches Material draw / touch_app).
  draw,
  touchApp,
  trash,
}

class NoteeIconWidget extends StatelessWidget {
  const NoteeIconWidget(
    this.icon, {
    super.key,
    this.size = 18,
    this.color,
    this.strokeWidth = 1.4,
  });

  final NoteeIcon icon;
  final double size;
  final Color? color;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final c = color ?? IconTheme.of(context).color ?? const Color(0xFF1A1612);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _NoteeIconPainter(
          icon: icon,
          color: c,
          strokeWidth: strokeWidth,
        ),
      ),
    );
  }
}

class _NoteeIconPainter extends CustomPainter {
  _NoteeIconPainter({
    required this.icon,
    required this.color,
    required this.strokeWidth,
  });

  final NoteeIcon icon;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 20.0; // viewBox is 20x20
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()..color = color;

    void path(void Function(Path p) build) {
      final p = Path();
      build(p);
      canvas.drawPath(p, paint);
    }

    Offset o(double x, double y) => Offset(x * s, y * s);
    Rect r(double x, double y, double w, double h) =>
        Rect.fromLTWH(x * s, y * s, w * s, h * s);

    switch (icon) {
      case NoteeIcon.pen:
        path((p) {
          p.moveTo(14 * s, 3.5 * s);
          p.lineTo(17 * s, 6.5 * s);
          p.lineTo(8 * s, 15.5 * s);
          p.lineTo(4 * s, 16.5 * s);
          p.lineTo(5 * s, 12.5 * s);
          p.close();
        });
        path((p) {
          p.moveTo(12.5 * s, 5 * s);
          p.lineTo(15.5 * s, 8 * s);
        });
      case NoteeIcon.highlight:
        path((p) {
          p.moveTo(5 * s, 14 * s);
          p.lineTo(4 * s, 17 * s);
          p.lineTo(7 * s, 16 * s);
          p.lineTo(16 * s, 7 * s);
          p.lineTo(14 * s, 5 * s);
          p.close();
        });
        path((p) {
          p.moveTo(14 * s, 5 * s);
          p.lineTo(15.5 * s, 3.5 * s);
        });
      case NoteeIcon.eraser:
        path((p) {
          p.moveTo(4 * s, 14 * s);
          p.lineTo(10 * s, 8 * s);
          p.lineTo(16 * s, 14 * s);
          p.lineTo(13 * s, 17 * s);
          p.lineTo(7 * s, 17 * s);
          p.close();
        });
        path((p) {
          p.moveTo(9 * s, 9 * s);
          p.lineTo(14 * s, 14 * s);
        });
      case NoteeIcon.lasso:
        canvas.drawOval(
          Rect.fromCenter(center: o(10, 9), width: 12 * s, height: 8 * s),
          paint,
        );
        path((p) {
          p.moveTo(9 * s, 13 * s);
          p.lineTo(8 * s, 16 * s);
          p.lineTo(10 * s, 15 * s);
        });
      case NoteeIcon.shape:
        canvas.drawRect(r(3, 3, 6, 6), paint);
        canvas.drawCircle(o(14, 6), 3 * s, paint);
        path((p) {
          p.moveTo(3 * s, 16 * s);
          p.lineTo(7 * s, 11 * s);
          p.lineTo(11 * s, 16 * s);
          p.close();
        });
      case NoteeIcon.text:
        path((p) {
          p.moveTo(4 * s, 5 * s);
          p.lineTo(16 * s, 5 * s);
          p.moveTo(10 * s, 5 * s);
          p.lineTo(10 * s, 16 * s);
        });
      case NoteeIcon.undo:
        path((p) {
          p.moveTo(4 * s, 8 * s);
          p.lineTo(13 * s, 8 * s);
          p.cubicTo(13 * s + 4 * s * 0.55, 8 * s, 17 * s, 8 * s + 4 * s * 0.55,
              17 * s, 12 * s);
          p.cubicTo(17 * s, 12 * s + 4 * s * 0.55, 13 * s + 4 * s * 0.55,
              16 * s, 13 * s, 16 * s);
          p.lineTo(7 * s, 16 * s);
          p.moveTo(7 * s, 5 * s);
          p.lineTo(4 * s, 8 * s);
          p.lineTo(7 * s, 11 * s);
        });
      case NoteeIcon.redo:
        path((p) {
          p.moveTo(16 * s, 8 * s);
          p.lineTo(7 * s, 8 * s);
          p.cubicTo(7 * s - 4 * s * 0.55, 8 * s, 3 * s, 8 * s + 4 * s * 0.55,
              3 * s, 12 * s);
          p.cubicTo(3 * s, 12 * s + 4 * s * 0.55, 7 * s - 4 * s * 0.55,
              16 * s, 7 * s, 16 * s);
          p.lineTo(13 * s, 16 * s);
          p.moveTo(13 * s, 5 * s);
          p.lineTo(16 * s, 8 * s);
          p.lineTo(13 * s, 11 * s);
        });
      case NoteeIcon.page:
        path((p) {
          p.moveTo(5 * s, 3 * s);
          p.lineTo(12 * s, 3 * s);
          p.lineTo(15 * s, 6 * s);
          p.lineTo(15 * s, 17 * s);
          p.lineTo(5 * s, 17 * s);
          p.close();
        });
        path((p) {
          p.moveTo(12 * s, 3 * s);
          p.lineTo(12 * s, 6 * s);
          p.lineTo(15 * s, 6 * s);
        });
      case NoteeIcon.search:
        canvas.drawCircle(o(9, 9), 5 * s, paint);
        path((p) {
          p.moveTo(13 * s, 13 * s);
          p.lineTo(17 * s, 17 * s);
        });
      case NoteeIcon.plus:
        path((p) {
          p.moveTo(10 * s, 4 * s);
          p.lineTo(10 * s, 16 * s);
          p.moveTo(4 * s, 10 * s);
          p.lineTo(16 * s, 10 * s);
        });
      case NoteeIcon.grid:
        canvas.drawRect(r(3, 3, 6, 6), paint);
        canvas.drawRect(r(11, 3, 6, 6), paint);
        canvas.drawRect(r(3, 11, 6, 6), paint);
        canvas.drawRect(r(11, 11, 6, 6), paint);
      case NoteeIcon.rows:
        path((p) {
          p.moveTo(3 * s, 4 * s);
          p.lineTo(17 * s, 4 * s);
          p.moveTo(3 * s, 10 * s);
          p.lineTo(17 * s, 10 * s);
          p.moveTo(3 * s, 16 * s);
          p.lineTo(17 * s, 16 * s);
        });
      case NoteeIcon.chev:
        path((p) {
          p.moveTo(6 * s, 5 * s);
          p.lineTo(11 * s, 10 * s);
          p.lineTo(6 * s, 15 * s);
        });
      case NoteeIcon.left:
        path((p) {
          p.moveTo(12 * s, 4 * s);
          p.lineTo(7 * s, 10 * s);
          p.lineTo(12 * s, 16 * s);
        });
      case NoteeIcon.gear:
        canvas.drawCircle(o(10, 10), 2.5 * s, paint);
        path((p) {
          p.moveTo(10 * s, 2 * s);
          p.lineTo(10 * s, 4 * s);
          p.moveTo(10 * s, 16 * s);
          p.lineTo(10 * s, 18 * s);
          p.moveTo(2 * s, 10 * s);
          p.lineTo(4 * s, 10 * s);
          p.moveTo(16 * s, 10 * s);
          p.lineTo(18 * s, 10 * s);
          p.moveTo(4.5 * s, 4.5 * s);
          p.lineTo(5.9 * s, 5.9 * s);
          p.moveTo(14 * s, 14 * s);
          p.lineTo(15.4 * s, 15.4 * s);
          p.moveTo(4.5 * s, 15.5 * s);
          p.lineTo(5.9 * s, 14.1 * s);
          p.moveTo(14 * s, 6 * s);
          p.lineTo(15.4 * s, 4.6 * s);
        });
      case NoteeIcon.share:
        canvas.drawCircle(o(6, 10), 2 * s, paint);
        canvas.drawCircle(o(14, 5), 2 * s, paint);
        canvas.drawCircle(o(14, 15), 2 * s, paint);
        path((p) {
          p.moveTo(8 * s, 9 * s);
          p.lineTo(12 * s, 6 * s);
          p.moveTo(8 * s, 11 * s);
          p.lineTo(12 * s, 14 * s);
        });
      case NoteeIcon.star:
        path((p) {
          p.moveTo(10 * s, 3 * s);
          p.lineTo(12 * s, 8 * s);
          p.lineTo(17 * s, 8.5 * s);
          p.lineTo(13 * s, 12 * s);
          p.lineTo(14 * s, 17 * s);
          p.lineTo(10 * s, 14.5 * s);
          p.lineTo(6 * s, 17 * s);
          p.lineTo(7 * s, 12 * s);
          p.lineTo(3 * s, 8.5 * s);
          p.lineTo(8 * s, 8 * s);
          p.close();
        });
      case NoteeIcon.folder:
        path((p) {
          p.moveTo(3 * s, 5 * s);
          p.lineTo(8 * s, 5 * s);
          p.lineTo(9.5 * s, 6.5 * s);
          p.lineTo(17 * s, 6.5 * s);
          p.lineTo(17 * s, 15.5 * s);
          p.lineTo(3 * s, 15.5 * s);
          p.close();
        });
      case NoteeIcon.home:
        path((p) {
          p.moveTo(3 * s, 10 * s);
          p.lineTo(10 * s, 4 * s);
          p.lineTo(17 * s, 10 * s);
          p.lineTo(17 * s, 16 * s);
          p.lineTo(12 * s, 16 * s);
          p.lineTo(12 * s, 12 * s);
          p.lineTo(8 * s, 12 * s);
          p.lineTo(8 * s, 16 * s);
          p.lineTo(3 * s, 16 * s);
          p.close();
        });
      case NoteeIcon.mic:
        canvas.drawRRect(
          RRect.fromRectAndRadius(r(8, 3, 4, 9), Radius.circular(2 * s)),
          paint,
        );
        path((p) {
          p.moveTo(5 * s, 10 * s);
          p.cubicTo(5 * s, 13 * s, 7 * s, 15 * s, 10 * s, 15 * s);
          p.cubicTo(13 * s, 15 * s, 15 * s, 13 * s, 15 * s, 10 * s);
          p.moveTo(10 * s, 15 * s);
          p.lineTo(10 * s, 18 * s);
        });
      case NoteeIcon.check:
        path((p) {
          p.moveTo(4 * s, 10 * s);
          p.lineTo(8 * s, 14 * s);
          p.lineTo(16 * s, 6 * s);
        });
      case NoteeIcon.layers:
        path((p) {
          p.moveTo(10 * s, 3 * s);
          p.lineTo(17 * s, 7 * s);
          p.lineTo(10 * s, 11 * s);
          p.lineTo(3 * s, 7 * s);
          p.close();
          p.moveTo(3 * s, 11 * s);
          p.lineTo(10 * s, 15 * s);
          p.lineTo(17 * s, 11 * s);
          p.moveTo(3 * s, 14 * s);
          p.lineTo(10 * s, 18 * s);
          p.lineTo(17 * s, 14 * s);
        });
      case NoteeIcon.tape:
        path((p) {
          // sticky tape strip — angled rectangle with torn-feeling ends
          p.moveTo(2 * s, 8 * s);
          p.lineTo(18 * s, 8 * s);
          p.lineTo(18 * s, 12 * s);
          p.lineTo(2 * s, 12 * s);
          p.close();
        });
        canvas.drawLine(
            Offset(6 * s, 8 * s), Offset(6 * s, 12 * s), paint);
        canvas.drawLine(
            Offset(14 * s, 8 * s), Offset(14 * s, 12 * s), paint);
      case NoteeIcon.dot:
        canvas.drawCircle(o(10, 10), 2 * s, fill);
      case NoteeIcon.draw:
        path((p) {
          p.moveTo(13 * s, 4 * s);
          p.lineTo(16 * s, 7 * s);
          p.lineTo(7 * s, 16 * s);
          p.lineTo(3 * s, 17 * s);
          p.lineTo(4 * s, 13 * s);
          p.close();
        });
        path((p) {
          p.moveTo(11 * s, 6 * s);
          p.lineTo(14 * s, 9 * s);
        });
      case NoteeIcon.touchApp:
        canvas.drawCircle(o(10, 8), 3 * s, paint);
        path((p) {
          p.moveTo(10 * s, 11 * s);
          p.lineTo(10 * s, 17 * s);
        });
      case NoteeIcon.trash:
        // Bin body + lid + handle
        path((p) {
          p.moveTo(5 * s, 7 * s);
          p.lineTo(6 * s, 17 * s);
          p.lineTo(14 * s, 17 * s);
          p.lineTo(15 * s, 7 * s);
          p.close();
        });
        // Lid
        path((p) {
          p.moveTo(3 * s, 7 * s);
          p.lineTo(17 * s, 7 * s);
        });
        // Handle
        path((p) {
          p.moveTo(8 * s, 7 * s);
          p.lineTo(8 * s, 5 * s);
          p.lineTo(12 * s, 5 * s);
          p.lineTo(12 * s, 7 * s);
        });
        // Vertical slots inside bin
        path((p) {
          p.moveTo(8.5 * s, 10 * s);
          p.lineTo(8.5 * s, 14.5 * s);
          p.moveTo(11.5 * s, 10 * s);
          p.lineTo(11.5 * s, 14.5 * s);
        });
    }
  }

  @override
  bool shouldRepaint(covariant _NoteeIconPainter old) =>
      old.icon != icon ||
      old.color != color ||
      old.strokeWidth != strokeWidth;
}
