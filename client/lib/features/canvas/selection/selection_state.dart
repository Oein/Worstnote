import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/page_object.dart';
import '../engine/lasso.dart' as geom;

@immutable
class SelectionState {
  const SelectionState({
    this.strokeIds = const {},
    this.shapeIds = const {},
    this.textIds = const {},
    this.bbox,
    this.pageId,
  });

  final Set<String> strokeIds;
  final Set<String> shapeIds;
  final Set<String> textIds;
  final Rect? bbox;
  /// Which page this selection belongs to. Other pages render no overlay.
  final String? pageId;

  bool get isEmpty =>
      strokeIds.isEmpty && shapeIds.isEmpty && textIds.isEmpty;

  bool get isNotEmpty => !isEmpty;

  Set<String> get allIds => {...strokeIds, ...shapeIds, ...textIds};

  SelectionState copyWith({
    Set<String>? strokeIds,
    Set<String>? shapeIds,
    Set<String>? textIds,
    Rect? bbox,
    String? pageId,
    bool clearBbox = false,
  }) =>
      SelectionState(
        strokeIds: strokeIds ?? this.strokeIds,
        shapeIds: shapeIds ?? this.shapeIds,
        textIds: textIds ?? this.textIds,
        bbox: clearBbox ? null : (bbox ?? this.bbox),
        pageId: pageId ?? this.pageId,
      );
}

class SelectionNotifier extends Notifier<SelectionState> {
  @override
  SelectionState build() => const SelectionState();

  void clear() => state = const SelectionState();

  void setFromRect({
    required Rect rect,
    required List<Stroke> strokes,
    required List<ShapeObject> shapes,
    required List<TextBoxObject> texts,
    String? pageId,
  }) {
    final sIds = <String>{};
    final shIds = <String>{};
    final tIds = <String>{};

    for (final s in strokes) {
      if (s.deleted) continue;
      if (_strokeHitsRect(s, rect)) sIds.add(s.id);
    }
    for (final s in shapes) {
      if (s.deleted) continue;
      final sb = Rect.fromLTRB(s.bbox.minX, s.bbox.minY, s.bbox.maxX, s.bbox.maxY);
      if (rect.overlaps(sb)) shIds.add(s.id);
    }
    for (final t in texts) {
      if (t.deleted) continue;
      final tb = Rect.fromLTRB(t.bbox.minX, t.bbox.minY, t.bbox.maxX, t.bbox.maxY);
      if (rect.overlaps(tb)) tIds.add(t.id);
    }

    state = SelectionState(
      strokeIds: sIds,
      shapeIds: shIds,
      textIds: tIds,
      bbox: _computeBbox(sIds, shIds, tIds, strokes, shapes, texts),
      pageId: pageId,
    );
  }

  void setFromLasso({
    required List<geom.Point2> polygon,
    required List<Stroke> strokes,
    required List<ShapeObject> shapes,
    required List<TextBoxObject> texts,
    String? pageId,
  }) {
    if (polygon.length < 3) {
      clear();
      return;
    }
    final sIds = <String>{};
    final shIds = <String>{};
    final tIds = <String>{};

    for (final s in strokes) {
      if (s.deleted) continue;
      if (_strokeHitsLasso(s, polygon)) sIds.add(s.id);
    }
    for (final s in shapes) {
      if (s.deleted) continue;
      final center = geom.Point2(
        (s.bbox.minX + s.bbox.maxX) / 2,
        (s.bbox.minY + s.bbox.maxY) / 2,
      );
      if (geom.pointInPolygon(center, polygon)) shIds.add(s.id);
    }
    for (final t in texts) {
      if (t.deleted) continue;
      final center = geom.Point2(
        (t.bbox.minX + t.bbox.maxX) / 2,
        (t.bbox.minY + t.bbox.maxY) / 2,
      );
      if (geom.pointInPolygon(center, polygon)) tIds.add(t.id);
    }

    state = SelectionState(
      strokeIds: sIds,
      shapeIds: shIds,
      textIds: tIds,
      bbox: _computeBbox(sIds, shIds, tIds, strokes, shapes, texts),
      pageId: pageId,
    );
  }

  void updateBbox(Rect bbox) => state = state.copyWith(bbox: bbox);

  /// Replace the entire selection state (e.g. select a single text box
  /// after exiting edit mode).
  void replace(SelectionState next) => state = next;

  static bool _strokeHitsRect(Stroke s, Rect rect) {
    final sb = Rect.fromLTRB(s.bbox.minX, s.bbox.minY, s.bbox.maxX, s.bbox.maxY);
    if (!rect.overlaps(sb)) return false;
    for (final p in s.points) {
      if (rect.contains(Offset(p.x, p.y))) return true;
    }
    return false;
  }

  static bool _strokeHitsLasso(Stroke s, List<geom.Point2> polygon) {
    for (final p in s.points) {
      if (geom.pointInPolygon(geom.Point2(p.x, p.y), polygon)) return true;
    }
    return false;
  }

  static Rect? _computeBbox(
    Set<String> sIds,
    Set<String> shIds,
    Set<String> tIds,
    List<Stroke> strokes,
    List<ShapeObject> shapes,
    List<TextBoxObject> texts,
  ) {
    double minX = double.infinity,
        minY = double.infinity,
        maxX = double.negativeInfinity,
        maxY = double.negativeInfinity;

    for (final s in strokes.where((s) => sIds.contains(s.id))) {
      if (s.bbox.minX < minX) minX = s.bbox.minX;
      if (s.bbox.minY < minY) minY = s.bbox.minY;
      if (s.bbox.maxX > maxX) maxX = s.bbox.maxX;
      if (s.bbox.maxY > maxY) maxY = s.bbox.maxY;
    }
    for (final s in shapes.where((s) => shIds.contains(s.id))) {
      if (s.bbox.minX < minX) minX = s.bbox.minX;
      if (s.bbox.minY < minY) minY = s.bbox.minY;
      if (s.bbox.maxX > maxX) maxX = s.bbox.maxX;
      if (s.bbox.maxY > maxY) maxY = s.bbox.maxY;
    }
    for (final t in texts.where((t) => tIds.contains(t.id))) {
      if (t.bbox.minX < minX) minX = t.bbox.minX;
      if (t.bbox.minY < minY) minY = t.bbox.minY;
      if (t.bbox.maxX > maxX) maxX = t.bbox.maxX;
      if (t.bbox.maxY > maxY) maxY = t.bbox.maxY;
    }

    if (minX == double.infinity) return null;
    // Tight bbox — visual breathing room is added by SelectionOverlayPainter
    // at paint time, so the stored selection bbox matches object bounds and
    // single-text selection handles sit on the actual textbox edges.
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }
}

final selectionProvider =
    NotifierProvider<SelectionNotifier, SelectionState>(SelectionNotifier.new);

/// Currently-editing text box id (set by CanvasView, read by the toolbar's
/// text format bar so font/weight/etc. changes can be applied live to the
/// box being edited rather than only to future text).
final editingTextBoxIdProvider = StateProvider<String?>((_) => null);
