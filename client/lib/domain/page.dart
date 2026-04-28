// A Page belongs to a Note and carries its own [PageSpec] so that a single
// note can mix sizes (PDF imports, custom sizes, etc.).

import 'package:freezed_annotation/freezed_annotation.dart';

import 'page_spec.dart';

part 'page.freezed.dart';
part 'page.g.dart';

@freezed
class NotePage with _$NotePage {
  const factory NotePage({
    required String id,
    required String noteId,
    required int index,
    required PageSpec spec,
    required DateTime updatedAt,
    @Default(0) int rev,
  }) = _NotePage;

  factory NotePage.fromJson(Map<String, dynamic> json) =>
      _$NotePageFromJson(json);
}
