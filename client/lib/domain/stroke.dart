// Vector stroke — the core drawable for pen, highlighter, and stroke-eraser
// trails (eraser strokes are persisted as a `tool: eraserStroke` so undo
// works uniformly).
//
// A stroke is an array of [StrokePoint]s with pressure/tilt/time. Rendering
// uses pressure-modulated thickness; raw points are smoothed with a One-Euro
// filter and Catmull-Rom interpolation in the canvas engine before paint.

import 'package:freezed_annotation/freezed_annotation.dart';

part 'stroke.freezed.dart';
part 'stroke.g.dart';

enum LineStyle { solid, dashed, dotted }

enum ToolKind {
  pen,
  highlighter,
  eraserStroke,
  eraserArea,
  /// Mnemonic tape: a thick opaque stroke. Tapping the stroke at runtime
  /// toggles its rendered opacity between full (covered) and ~10% (peek).
  /// The toggle state is *not* persisted; it lives in CanvasView.
  tape,
}

/// Axis-aligned bounding box in page-pt coordinates.
@freezed
class Bbox with _$Bbox {
  const factory Bbox({
    required double minX,
    required double minY,
    required double maxX,
    required double maxY,
  }) = _Bbox;

  factory Bbox.fromJson(Map<String, dynamic> json) => _$BboxFromJson(json);

  factory Bbox.fromPoints(Iterable<StrokePoint> pts) {
    var minX = double.infinity, minY = double.infinity;
    var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final p in pts) {
      if (p.x < minX) minX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.x > maxX) maxX = p.x;
      if (p.y > maxY) maxY = p.y;
    }
    return Bbox(minX: minX, minY: minY, maxX: maxX, maxY: maxY);
  }
}

@freezed
class StrokePoint with _$StrokePoint {
  const factory StrokePoint({
    required double x,
    required double y,
    @Default(0.5) double pressure,
    @Default(0.0) double tiltX,
    @Default(0.0) double tiltY,
    @Default(0) int tMs,
  }) = _StrokePoint;

  factory StrokePoint.fromJson(Map<String, dynamic> json) =>
      _$StrokePointFromJson(json);
}

@freezed
class Stroke with _$Stroke {
  const factory Stroke({
    required String id,
    required String pageId,
    required String layerId,
    required ToolKind tool,
    required int colorArgb,
    required double widthPt,
    @Default(1.0) double opacity,
    @Default(LineStyle.solid) LineStyle lineStyle,
    @Default(1.0) double dashGap,
    required List<StrokePoint> points,
    required Bbox bbox,
    required DateTime createdAt,
    String? createdBy,
    @Default(0) int rev,
    @Default(false) bool deleted,
  }) = _Stroke;

  factory Stroke.fromJson(Map<String, dynamic> json) => _$StrokeFromJson(json);
}
