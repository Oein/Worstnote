// Folder — a node in the library tree. `parentId == null` is the root.
// Notebooks (Notes) reference an optional [Note.folderId]; folders nest via
// [Folder.parentId].

import 'package:freezed_annotation/freezed_annotation.dart';

part 'folder.freezed.dart';
part 'folder.g.dart';

@freezed
class Folder with _$Folder {
  const factory Folder({
    required String id,
    String? parentId,
    required String name,
    required DateTime createdAt,
    required DateTime updatedAt,
    @Default(0) int rev,
    @Default(0xFFB0BEC5) int colorArgb,
    @Default('folder') String iconKey,
  }) = _Folder;

  factory Folder.fromJson(Map<String, dynamic> json) => _$FolderFromJson(json);
}
