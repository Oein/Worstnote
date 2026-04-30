// StrokeBuilder collects raw [PointerEvent] samples for one in-progress
// stroke, applies One-Euro smoothing per axis, drops sub-1pt jitter samples,
// and produces a finalized [Stroke] when [finish] is called.
//
// This is a pure-Dart engine class — it does not depend on Flutter widgets.
// Tests can drive it with synthetic samples to verify smoothing and bbox.

import '../../../core/ids.dart';
import '../../../core/one_euro_filter.dart';
import '../../../domain/stroke.dart';

class StrokeBuilder {
  StrokeBuilder({
    required this.pageId,
    required this.layerId,
    required this.tool,
    required this.colorArgb,
    required this.widthPt,
    this.opacity = 1.0,
    this.lineStyle = LineStyle.solid,
    this.dashGap = 1.0,
    /// 0..1 — 0 = barely smooth (raw input), 1 = heavy smoothing.
    /// Maps to the One-Euro filter's beta and minCutoff.
    double smoothing = 0.25,
    OneEuroFilter? xFilter,
    OneEuroFilter? yFilter,
  })  : _xFilter = xFilter ??
            OneEuroFilter(
              minCutoff: 1.0 - 0.85 * smoothing,
              beta: 0.5 - 0.49 * smoothing,
            ),
        _yFilter = yFilter ??
            OneEuroFilter(
              minCutoff: 1.0 - 0.85 * smoothing,
              beta: 0.5 - 0.49 * smoothing,
            );

  final String pageId;
  final String layerId;
  final ToolKind tool;
  final int colorArgb;
  final double widthPt;
  final double opacity;
  final LineStyle lineStyle;
  final double dashGap;

  final OneEuroFilter _xFilter;
  final OneEuroFilter _yFilter;

  final List<StrokePoint> _points = <StrokePoint>[];
  int? _t0Ms;

  /// Drop new samples that moved less than this many points from the previous
  /// retained sample (deduplication guard — filters near-zero floating point
  /// noise without blocking legitimate fine movements at high zoom).
  static const double _minMovePt = 0.1;

  bool get isEmpty => _points.isEmpty;
  int get pointCount => _points.length;

  /// Read-only view of accumulated points, for live painting.
  List<StrokePoint> get points => List.unmodifiable(_points);

  /// Add a raw input sample through the One-Euro filter. Coordinates are page-pt.
  void addPoint({
    required double x,
    required double y,
    required double pressure,
    required double tiltX,
    required double tiltY,
    required int tMs,
  }) {
    _t0Ms ??= tMs;
    final relMs = tMs - _t0Ms!;
    final tSec = relMs / 1000.0;

    final fx = _xFilter.filter(x, tSec);
    final fy = _yFilter.filter(y, tSec);

    if (_points.isNotEmpty) {
      final last = _points.last;
      final dx = fx - last.x;
      final dy = fy - last.y;
      if (dx * dx + dy * dy < _minMovePt * _minMovePt) {
        return;
      }
    }

    _points.add(StrokePoint(
      x: fx,
      y: fy,
      pressure: pressure.clamp(0.0, 1.0),
      tiltX: tiltX,
      tiltY: tiltY,
      tMs: relMs,
    ));
  }

  /// Add a pre-smoothed point bypassing the One-Euro filter.
  /// Used by the leash algorithm which does its own positional smoothing.
  void addRawPoint({
    required double x,
    required double y,
    required double pressure,
    required double tiltX,
    required double tiltY,
    required int tMs,
  }) {
    _t0Ms ??= tMs;
    final relMs = tMs - _t0Ms!;

    if (_points.isNotEmpty) {
      final last = _points.last;
      final dx = x - last.x;
      final dy = y - last.y;
      if (dx * dx + dy * dy < _minMovePt * _minMovePt) return;
    }

    _points.add(StrokePoint(
      x: x,
      y: y,
      pressure: pressure.clamp(0.0, 1.0),
      tiltX: tiltX,
      tiltY: tiltY,
      tMs: relMs,
    ));
  }

  /// Materialize the stroke. Returns null if no points were gathered.
  /// A single-tap produces a dot by duplicating the one point.
  Stroke? finish({DateTime? now, String? createdBy}) {
    if (_points.isEmpty) return null;
    final pts = _points.length == 1
        ? [_points.first, _points.first]
        : _points;
    return Stroke(
      id: newId(),
      pageId: pageId,
      layerId: layerId,
      tool: tool,
      colorArgb: colorArgb,
      widthPt: widthPt,
      opacity: opacity,
      lineStyle: lineStyle,
      dashGap: dashGap,
      points: List<StrokePoint>.unmodifiable(pts),
      bbox: Bbox.fromPoints(pts),
      createdAt: now ?? DateTime.now().toUtc(),
      createdBy: createdBy,
    );
  }
}
