// A Notebook (called "Note" here) — the top-level user-owned container.
//
// `scrollAxis` is per-note: the user can choose vertical or horizontal page
// flow at any time, and the [PageScroller] reconfigures accordingly.

import 'package:freezed_annotation/freezed_annotation.dart';

import 'page_spec.dart';

part 'note.freezed.dart';
part 'note.g.dart';

enum ScrollAxis { vertical, horizontal }

/// User preference for what kinds of pointer input draw on the canvas.
/// `any` accepts all pointers (default); `stylusOnly` enables palm rejection
/// — only an Apple Pencil / S-Pen / Wacom stylus draws, fingers and mouse
/// drag the page instead.
enum InputDrawMode { any, stylusOnly }

@freezed
class Note with _$Note {
  const factory Note({
    required String id,
    required String ownerId,
    required String title,
    required ScrollAxis scrollAxis,
    required PageSpec defaultPageSpec,
    required DateTime createdAt,
    required DateTime updatedAt,
    @Default(0) int rev,
    @Default(InputDrawMode.any) InputDrawMode inputDrawMode,
    String? folderId,
    // Tape stroke IDs currently in "revealed" (semi-transparent) state.
    @Default(<String>[]) List<String> revealedTapeIds,
  }) = _Note;

  factory Note.fromJson(Map<String, dynamic> json) => _$NoteFromJson(json);
}
