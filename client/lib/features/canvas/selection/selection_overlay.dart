import 'package:flutter/material.dart';

// Handle positions: TL, TC, TR, ML, MR, BL, BC, BR
enum SelectionHandle { tl, tc, tr, ml, mr, bl, bc, br }

const _kHandleRadius = 5.0;
const _kHandleHitRadius = 12.0;
/// Visual breathing room around the (tight) selection bbox. The stored
/// selection bbox matches object bounds; the overlay + handles are drawn
/// at this inflation so they don't overlap the content.
const double _kVisualPad = 4.0;

/// Paints the selection bbox with 8 resize handles + 1 rotate handle.
/// [zoom] divides handle/border sizes so they stay visually constant
/// regardless of the canvas zoom factor. [rotation] (radians) rotates the
/// whole bbox + handle layout around the bbox centre — used so the overlay
/// follows the live rotation drag instead of snapping back to axis-aligned.
class SelectionOverlayPainter extends CustomPainter {
  const SelectionOverlayPainter({
    required this.bbox,
    this.zoom = 1.0,
    this.rotation = 0.0,
  });
  final Rect bbox;
  final double zoom;
  final double rotation;

  /// Inflated rect actually drawn / used for handle positions and hit-test.
  static Rect inflatedBbox(Rect bbox, {double zoom = 1.0}) =>
      bbox.inflate(_kVisualPad / zoom);

  static List<(SelectionHandle, Offset)> handles(Rect bbox,
      {double zoom = 1.0}) {
    final r = inflatedBbox(bbox, zoom: zoom);
    return [
      (SelectionHandle.tl, r.topLeft),
      (SelectionHandle.tc, r.topCenter),
      (SelectionHandle.tr, r.topRight),
      (SelectionHandle.ml, r.centerLeft),
      (SelectionHandle.mr, r.centerRight),
      (SelectionHandle.bl, r.bottomLeft),
      (SelectionHandle.bc, r.bottomCenter),
      (SelectionHandle.br, r.bottomRight),
    ];
  }

  /// Position of the rotate handle (above the top-center).
  static Offset rotateHandlePos(Rect bbox, {double zoom = 1.0}) {
    final r = inflatedBbox(bbox, zoom: zoom);
    return Offset(r.center.dx, r.top - 22 / zoom);
  }

  /// Returns which handle (if any) the [point] hits.
  static SelectionHandle? hitHandle(Rect bbox, Offset point,
      {double zoom = 1.0}) {
    final hit = _kHandleHitRadius / zoom;
    for (final (handle, pos) in handles(bbox, zoom: zoom)) {
      if ((point - pos).distance <= hit) return handle;
    }
    return null;
  }

  /// True if [point] hits the rotate handle (the small circle above the bbox).
  static bool hitRotateHandle(Rect bbox, Offset point, {double zoom = 1.0}) {
    final hit = _kHandleHitRadius / zoom;
    return (point - rotateHandlePos(bbox, zoom: zoom)).distance <= hit;
  }

  /// Computes the angle (radians) from bbox center to [point].
  /// Use to derive a rotation delta during a rotate drag.
  static double angleAt(Rect bbox, Offset point) {
    final c = bbox.center;
    return (point - c).direction;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final z = zoom == 0 ? 1.0 : zoom;
    canvas.save();
    if (rotation != 0) {
      final c = bbox.center;
      canvas.translate(c.dx, c.dy);
      canvas.rotate(rotation);
      canvas.translate(-c.dx, -c.dy);
    }
    final borderPaint = Paint()
      ..color = const Color(0xFF2563EB)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 / z;

    final visual = inflatedBbox(bbox, zoom: z);
    // Dashed border
    _drawDashedRect(canvas, visual, borderPaint, z);

    // Resize handles
    final fillPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    final strokePaint = Paint()
      ..color = const Color(0xFF2563EB)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 / z;

    final r = _kHandleRadius / z;
    for (final (_, pos) in handles(bbox, zoom: z)) {
      canvas.drawCircle(pos, r, fillPaint);
      canvas.drawCircle(pos, r, strokePaint);
    }

    // Rotate handle: a small circle above the top-center connected by a line.
    final rotatePos = rotateHandlePos(bbox, zoom: z);
    canvas.drawLine(
        Offset(visual.center.dx, visual.top), rotatePos, borderPaint);
    canvas.drawCircle(rotatePos, r, fillPaint);
    canvas.drawCircle(rotatePos, r, strokePaint);
    canvas.restore();
  }

  void _drawDashedRect(Canvas canvas, Rect rect, Paint paint, double z) {
    final dashLen = 6.0 / z;
    final gapLen = 4.0 / z;
    void drawDashedLine(Offset a, Offset b) {
      final delta = b - a;
      final len = delta.distance;
      final dir = delta / len;
      var pos = 0.0;
      var draw = true;
      while (pos < len) {
        final seg = draw ? dashLen : gapLen;
        final end = (pos + seg).clamp(0.0, len);
        if (draw) {
          canvas.drawLine(a + dir * pos, a + dir * end, paint);
        }
        pos += seg;
        draw = !draw;
      }
    }

    drawDashedLine(rect.topLeft, rect.topRight);
    drawDashedLine(rect.topRight, rect.bottomRight);
    drawDashedLine(rect.bottomRight, rect.bottomLeft);
    drawDashedLine(rect.bottomLeft, rect.topLeft);
  }

  @override
  bool shouldRepaint(covariant SelectionOverlayPainter old) =>
      old.bbox != bbox || old.zoom != zoom || old.rotation != rotation;
}
