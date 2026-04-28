// Layers live within a page. Every drawable object (Stroke/Shape/TextBox/Tape)
// references exactly one layer via [layerId]. A page always has at least one
// layer (named "Default"). Tape objects are auto-routed to a top "Tape" layer.
//
// Render order is by ascending [z]; lower z draws first (background-most).

import 'package:freezed_annotation/freezed_annotation.dart';

part 'layer.freezed.dart';
part 'layer.g.dart';

@freezed
class Layer with _$Layer {
  const factory Layer({
    required String id,
    required String pageId,
    required int z,
    required String name,
    @Default(true) bool visible,
    @Default(false) bool locked,
    @Default(1.0) double opacity,
    @Default(0) int rev,
  }) = _Layer;

  factory Layer.fromJson(Map<String, dynamic> json) => _$LayerFromJson(json);
}
