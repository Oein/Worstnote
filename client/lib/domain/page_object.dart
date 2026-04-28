// PageObject — the sealed union of every drawable thing on a page.
// Stroke is in stroke.dart for historical reasons; this file adds
// Shape / TextBox and re-exports them all under a common supertype
// `PageObject` for unified collections.
//
// Note: "Tape" is *not* a separate object kind. It's a stroke whose
// `tool == ToolKind.tape`; tapping it at runtime toggles its rendered
// opacity between full and ~10% (see CanvasView).
//
// Each subtype has: id, pageId, layerId, bbox, rev, deleted, plus its own
// fields. Bbox is denormalized for selection / hit-testing.

import 'package:freezed_annotation/freezed_annotation.dart';

import 'stroke.dart';

export 'stroke.dart' show Stroke, StrokePoint, ToolKind, Bbox;

part 'page_object.freezed.dart';
part 'page_object.g.dart';

enum ShapeKind { rectangle, ellipse, triangle, diamond, arrow, line }

@freezed
class ShapeObject with _$ShapeObject {
  const factory ShapeObject({
    required String id,
    required String pageId,
    required String layerId,
    required ShapeKind shape,
    required Bbox bbox,
    @Default(0.0) double rotation,
    required int colorArgb,
    required double strokeWidthPt,
    @Default(false) bool filled,
    int? fillColorArgb,
    @Default(false) bool regularized,
    @Default(false) bool arrowFlipX,
    @Default(false) bool arrowFlipY,
    required DateTime createdAt,
    String? createdBy,
    @Default(0) int rev,
    @Default(false) bool deleted,
  }) = _ShapeObject;

  factory ShapeObject.fromJson(Map<String, dynamic> json) =>
      _$ShapeObjectFromJson(json);
}

@freezed
class TextBoxObject with _$TextBoxObject {
  const factory TextBoxObject({
    required String id,
    required String pageId,
    required String layerId,
    required Bbox bbox,
    @Default('') String text,
    @Default('Roboto') String fontFamily,
    @Default(16.0) double fontSizePt,
    @Default(400) int fontWeight,
    @Default(0xFF111827) int colorArgb,
    @Default(false) bool italic,
    @Default(0) int textAlign,
    required DateTime createdAt,
    String? createdBy,
    @Default(1.0) double scaleX,
    @Default(1.0) double scaleY,
    @Default(0) int rev,
    @Default(false) bool deleted,
  }) = _TextBoxObject;

  factory TextBoxObject.fromJson(Map<String, dynamic> json) =>
      _$TextBoxObjectFromJson(json);
}

/// Sealed supertype for collections that hold any drawable.
sealed class PageObject {
  String get id;
  String get pageId;
  String get layerId;
  Bbox get bbox;
  int get rev;
  bool get deleted;
  DateTime get createdAt;
}

/// Adapter to make Stroke implement PageObject without modifying its file.
class StrokePO implements PageObject {
  StrokePO(this.stroke);
  final Stroke stroke;
  @override
  String get id => stroke.id;
  @override
  String get pageId => stroke.pageId;
  @override
  String get layerId => stroke.layerId;
  @override
  Bbox get bbox => stroke.bbox;
  @override
  int get rev => stroke.rev;
  @override
  bool get deleted => stroke.deleted;
  @override
  DateTime get createdAt => stroke.createdAt;
}

class ShapePO implements PageObject {
  ShapePO(this.shape);
  final ShapeObject shape;
  @override
  String get id => shape.id;
  @override
  String get pageId => shape.pageId;
  @override
  String get layerId => shape.layerId;
  @override
  Bbox get bbox => shape.bbox;
  @override
  int get rev => shape.rev;
  @override
  bool get deleted => shape.deleted;
  @override
  DateTime get createdAt => shape.createdAt;
}

class TextPO implements PageObject {
  TextPO(this.text);
  final TextBoxObject text;
  @override
  String get id => text.id;
  @override
  String get pageId => text.pageId;
  @override
  String get layerId => text.layerId;
  @override
  Bbox get bbox => text.bbox;
  @override
  int get rev => text.rev;
  @override
  bool get deleted => text.deleted;
  @override
  DateTime get createdAt => text.createdAt;
}
