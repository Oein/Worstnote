// Bridges the in-memory NotebookState (Riverpod) to the local SQLite DB
// (drift). Save is row-level — every object lives in its own row in
// page_objects, layers/pages/notes have their own tables. JSON-encoded
// columns hold the freezed model bodies so we can evolve the schema
// without per-field migrations early on.

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/folder.dart';
import '../../domain/layer.dart';
import '../../domain/note.dart';
import '../../domain/page.dart';
import '../../domain/page_object.dart';
import '../../domain/page_spec.dart';
import '../../features/notebook/notebook_state.dart';
import 'notee_database.dart';

/// Lightweight summary of a Note for the library grid.
/// Includes the first page's background spec, strokes, shapes, and texts so
/// the cover thumbnail can render actual content.
class NoteSummary {
  NoteSummary({
    required this.id,
    required this.title,
    required this.folderId,
    required this.createdAt,
    required this.updatedAt,
    required this.pageCount,
    this.firstPageSpec,
    this.firstPageStrokes = const [],
    this.firstPageShapes = const [],
    this.firstPageTexts = const [],
    this.isFavorite = false,
  });
  final String id;
  final String title;
  final String? folderId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int pageCount;
  final PageSpec? firstPageSpec;
  final List<Stroke> firstPageStrokes;
  final List<ShapeObject> firstPageShapes;
  final List<TextBoxObject> firstPageTexts;
  final bool isFavorite;
}

class NotebookRepository {
  NotebookRepository(this.db);
  final NoteeDatabase db;

  // ── Folders ──────────────────────────────────────────────────────
  Future<List<Folder>> listFolders() async {
    final rows = await db.select(db.folders).get();

    // color_argb and icon_key are added via migration — not in Drift schema.
    final extras = <String, (int, String)>{};
    try {
      final extRows = await db
          .customSelect('SELECT id, color_argb, icon_key FROM folders')
          .get();
      for (final r in extRows) {
        extras[r.read<String>('id')] = (
          r.read<int>('color_argb'),
          r.read<String>('icon_key'),
        );
      }
    } catch (_) {}

    return rows
        .map((r) => Folder(
              id: r.id,
              parentId: r.parentId,
              name: r.name,
              createdAt: r.createdAt,
              updatedAt: r.updatedAt,
              rev: r.rev,
              colorArgb: extras[r.id]?.$1 ?? 0xFFB0BEC5,
              iconKey: extras[r.id]?.$2 ?? 'folder',
            ))
        .toList();
  }

  Future<void> upsertFolder(Folder f) async {
    await db.into(db.folders).insertOnConflictUpdate(FoldersCompanion(
          id: Value(f.id),
          parentId: Value(f.parentId),
          name: Value(f.name),
          rev: Value(f.rev),
          createdAt: Value(f.createdAt),
          updatedAt: Value(f.updatedAt),
        ));
    // Write color/icon separately (columns outside Drift schema).
    await db.customStatement(
      'UPDATE folders SET color_argb = ?, icon_key = ? WHERE id = ?',
      [f.colorArgb, f.iconKey, f.id],
    );
  }

  Future<void> updateFolderAppearance(
      String folderId, int colorArgb, String iconKey) async {
    await db.customStatement(
      'UPDATE folders SET color_argb = ?, icon_key = ?, updated_at = ? WHERE id = ?',
      [colorArgb, iconKey, DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000, folderId],
    );
  }

  /// Recursive delete: drops the folder, its children, and any notes
  /// (with all pages/layers/objects) inside. Returns the IDs of every
  /// note that was deleted so the caller can sync tombstones to the server.
  Future<List<String>> deleteFolder(String folderId) async {
    final deletedNoteIds = <String>[];
    await db.transaction(() async {
      final allFolders = await listFolders();
      // Collect descendants.
      final stack = <String>[folderId];
      final toDelete = <String>{folderId};
      while (stack.isNotEmpty) {
        final cur = stack.removeLast();
        for (final f in allFolders) {
          if (f.parentId == cur && !toDelete.contains(f.id)) {
            toDelete.add(f.id);
            stack.add(f.id);
          }
        }
      }
      for (final fid in toDelete) {
        final notes = await (db.select(db.notes)
              ..where((n) => n.folderId.equals(fid)))
            .get();
        for (final n in notes) {
          deletedNoteIds.add(n.id);
          await deleteNote(n.id);
        }
        await (db.delete(db.folders)..where((t) => t.id.equals(fid))).go();
      }
    });
    return deletedNoteIds;
  }

  // ── Notebooks (notes) summary ────────────────────────────────────

  Future<List<NoteSummary>> listNoteSummaries() async {
    // Fetch all notes and pages in two bulk queries to avoid N+1.
    final notes = await db.select(db.notes).get();
    final pages = await db.select(db.pages).get();

    // Group pages by noteId; sort by idx to identify the first page cheaply.
    final pagesByNote = <String, List<PageRow>>{};
    for (final p in pages) {
      pagesByNote.putIfAbsent(p.noteId, () => []).add(p);
    }
    for (final list in pagesByNote.values) {
      list.sort((a, b) => a.idx.compareTo(b.idx));
    }

    // Batch-read favorite flags via raw SQL (column not in Drift schema).
    final favMap = <String, bool>{};
    try {
      final favRows = await db
          .customSelect('SELECT id, is_favorite FROM notes')
          .get();
      for (final r in favRows) {
        favMap[r.read<String>('id')] =
            r.read<int>('is_favorite') != 0;
      }
    } catch (_) {
      // Column missing on very old DBs before migration — default all false.
    }

    // Collect first-page IDs so we can batch-load strokes in one SQL query.
    final firstPageIds = <String>[];
    for (final notePages in pagesByNote.values) {
      if (notePages.isNotEmpty) firstPageIds.add(notePages.first.id);
    }

    // Batch-load up to 30 strokes/shapes/texts per first-page in one query.
    final strokesByFirstPage = <String, List<Stroke>>{};
    final shapesByFirstPage = <String, List<ShapeObject>>{};
    final textsByFirstPage = <String, List<TextBoxObject>>{};
    if (firstPageIds.isNotEmpty) {
      final quoted = firstPageIds.map((id) => "'$id'").join(',');
      try {
        final objRows = await db.customSelect(
          'SELECT page_id, kind, data FROM page_objects '
          "WHERE page_id IN ($quoted) AND deleted=0 "
          "AND kind IN ('stroke','shape','text') "
          'ORDER BY page_id, rev',
        ).get();
        for (final row in objRows) {
          final pageId = row.read<String>('page_id');
          final kind = row.read<String>('kind');
          final json = jsonDecode(row.read<String>('data')) as Map<String, dynamic>;
          try {
            if (kind == 'stroke') {
              final list = strokesByFirstPage.putIfAbsent(pageId, () => []);
              if (list.length < 30) list.add(Stroke.fromJson(json));
            } else if (kind == 'shape') {
              final list = shapesByFirstPage.putIfAbsent(pageId, () => []);
              if (list.length < 50) list.add(ShapeObject.fromJson(json));
            } else if (kind == 'text') {
              final list = textsByFirstPage.putIfAbsent(pageId, () => []);
              if (list.length < 50) list.add(TextBoxObject.fromJson(json));
            }
          } catch (_) {}
        }
      } catch (_) {}
    }

    return notes.map((n) {
      final notePages = pagesByNote[n.id] ?? [];
      PageSpec? firstPageSpec;
      if (notePages.isNotEmpty) {
        try {
          firstPageSpec = PageSpec.fromJson(
            jsonDecode(notePages.first.spec) as Map<String, dynamic>,
          );
        } catch (_) {}
      }
      final firstPageId = notePages.isNotEmpty ? notePages.first.id : null;
      return NoteSummary(
        id: n.id,
        title: n.title,
        folderId: n.folderId,
        createdAt: n.createdAt,
        updatedAt: n.updatedAt,
        pageCount: notePages.length,
        firstPageSpec: firstPageSpec,
        firstPageStrokes:
            firstPageId != null ? strokesByFirstPage[firstPageId] ?? [] : [],
        firstPageShapes:
            firstPageId != null ? shapesByFirstPage[firstPageId] ?? [] : [],
        firstPageTexts:
            firstPageId != null ? textsByFirstPage[firstPageId] ?? [] : [],
        isFavorite: favMap[n.id] ?? false,
      );
    }).toList();
  }

  // ── Note locking ──────────────────────────────────────────────────────

  Future<void> lockNote(String noteId, String sessionId) async {
    await db.customStatement(
      'UPDATE notes SET locked_by = ? WHERE id = ?',
      [sessionId, noteId],
    );
  }

  /// Atomic compare-and-set: only locks if currently unlocked.
  /// Returns true if we got the lock.
  Future<bool> tryLockIfFree(String noteId, String sessionId) async {
    final rows = await db.customUpdate(
      'UPDATE notes SET locked_by = ? WHERE id = ? AND locked_by IS NULL',
      variables: [
        Variable.withString(sessionId),
        Variable.withString(noteId),
      ],
    );
    return rows > 0;
  }

  Future<void> unlockNote(String noteId, String sessionId) async {
    await db.customStatement(
      'UPDATE notes SET locked_by = NULL WHERE id = ? AND locked_by = ?',
      [noteId, sessionId],
    );
  }

  Future<void> forceUnlockNote(String noteId) async {
    await db.customStatement(
      'UPDATE notes SET locked_by = NULL WHERE id = ?',
      [noteId],
    );
  }

  Future<void> releaseAllLocks(String sessionId) async {
    await db.customStatement(
      'UPDATE notes SET locked_by = NULL WHERE locked_by = ?',
      [sessionId],
    );
  }

  Future<String?> getNoteLock(String noteId) async {
    final rows = await db.customSelect(
      'SELECT locked_by FROM notes WHERE id = ?',
      variables: [Variable.withString(noteId)],
    ).get();
    if (rows.isEmpty) return null;
    return rows.first.read<String?>('locked_by');
  }

  Stream<Map<String, String>> watchLockedNotes() {
    return db.customSelect('SELECT id, locked_by FROM notes WHERE locked_by IS NOT NULL')
        .watch()
        .map((rows) => {
              for (final r in rows)
                r.read<String>('id'): r.read<String>('locked_by'),
            });
  }

  /// Toggle the `is_favorite` flag for a note. Persists immediately.
  Future<void> toggleFavorite(String noteId, {required bool value}) async {
    await db.customStatement(
      'UPDATE notes SET is_favorite = ? WHERE id = ?',
      [value ? 1 : 0, noteId],
    );
  }

  Future<void> deleteNote(String noteId) async {
    await db.transaction(() async {
      final pageRows = await (db.select(db.pages)
            ..where((p) => p.noteId.equals(noteId)))
          .get();
      for (final p in pageRows) {
        await (db.delete(db.layers)..where((l) => l.pageId.equals(p.id))).go();
        await (db.delete(db.pageObjects)
              ..where((o) => o.pageId.equals(p.id)))
            .go();
      }
      await (db.delete(db.pages)..where((p) => p.noteId.equals(noteId))).go();
      await (db.delete(db.notes)..where((n) => n.id.equals(noteId))).go();
    });
  }

  Future<void> moveNoteToFolder(String noteId, String? folderId) async {
    await (db.update(db.notes)..where((n) => n.id.equals(noteId)))
        .write(NotesCompanion(folderId: Value(folderId)));
  }

  Future<void> moveFolderTo(String folderId, String? parentId) async {
    await db.customStatement(
      'UPDATE folders SET parent_id = ?, updated_at = ? WHERE id = ?',
      [parentId, DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000, folderId],
    );
  }

  Future<void> updateNoteTitle(String noteId, String title) async {
    await (db.update(db.notes)..where((n) => n.id.equals(noteId)))
        .write(NotesCompanion(
          title: Value(title),
          updatedAt: Value(DateTime.now().toUtc()),
        ));
  }

  /// Deep-clones a note (note + pages + layers + objects) under fresh IDs and
  /// returns the new note id. Title gets a "(복사본)" suffix.
  Future<String> duplicateNote(String noteId) async {
    final loaded = await loadByNoteId(noteId);
    if (loaded == null) throw StateError('note not found');

    int counter = 0;
    String mkId() {
      counter++;
      return '${DateTime.now().microsecondsSinceEpoch}-${counter.toRadixString(16)}-'
          '${(loaded.note.id.hashCode ^ identityHashCode(this)).toRadixString(16)}';
    }

    final newNoteId = mkId();
    final now = DateTime.now().toUtc();

    // page id remap
    final pageMap = <String, String>{};
    for (final p in loaded.pages) {
      pageMap[p.id] = mkId();
    }
    // layer id remap (same key namespace)
    final layerMap = <String, String>{};
    for (final layers in loaded.layersByPage.values) {
      for (final l in layers) {
        layerMap[l.id] = mkId();
      }
    }

    final clonedNote = loaded.note.copyWith(
      id: newNoteId,
      title: '${loaded.note.title} (복사본)',
      createdAt: now,
      updatedAt: now,
      rev: 0,
    );

    final clonedPages = [
      for (final p in loaded.pages)
        p.copyWith(
          id: pageMap[p.id]!,
          noteId: newNoteId,
          updatedAt: now,
          rev: 0,
        ),
    ];

    final clonedLayersByPage = <String, List<Layer>>{};
    final clonedStrokesByPage = <String, List<Stroke>>{};
    final clonedShapesByPage = <String, List<ShapeObject>>{};
    final clonedTextsByPage = <String, List<TextBoxObject>>{};
    final clonedActiveLayer = <String, String>{};

    for (final p in loaded.pages) {
      final newPid = pageMap[p.id]!;
      final layers = (loaded.layersByPage[p.id] ?? const <Layer>[])
          .map((l) => l.copyWith(
                id: layerMap[l.id]!,
                pageId: newPid,
                rev: 0,
              ))
          .toList();
      clonedLayersByPage[newPid] = layers;
      if (layers.isNotEmpty) clonedActiveLayer[newPid] = layers.first.id;

      clonedStrokesByPage[newPid] = (loaded.strokesByPage[p.id] ?? const <Stroke>[])
          .map((s) => s.copyWith(
                id: mkId(),
                pageId: newPid,
                layerId: layerMap[s.layerId] ?? layers.first.id,
                rev: 0,
              ))
          .toList();
      clonedShapesByPage[newPid] = (loaded.shapesByPage[p.id] ?? const <ShapeObject>[])
          .map((s) => s.copyWith(
                id: mkId(),
                pageId: newPid,
                layerId: layerMap[s.layerId] ?? layers.first.id,
                rev: 0,
              ))
          .toList();
      clonedTextsByPage[newPid] = (loaded.textsByPage[p.id] ?? const <TextBoxObject>[])
          .map((t) => t.copyWith(
                id: mkId(),
                pageId: newPid,
                layerId: layerMap[t.layerId] ?? layers.first.id,
                rev: 0,
              ))
          .toList();
    }

    final cloned = NotebookState(
      note: clonedNote,
      pages: clonedPages,
      layersByPage: clonedLayersByPage,
      strokesByPage: clonedStrokesByPage,
      shapesByPage: clonedShapesByPage,
      textsByPage: clonedTextsByPage,
      activeLayerByPage: clonedActiveLayer,
    );
    await saveAll(cloned);
    return newNoteId;
  }

  // ── Save ──────────────────────────────────────────────────────────
  Future<void> saveAll(NotebookState s) async {
    await db.transaction(() async {
      // Note
      await db.into(db.notes).insertOnConflictUpdate(NotesCompanion(
            id: Value(s.note.id),
            ownerId: Value(s.note.ownerId),
            title: Value(s.note.title),
            scrollAxis: Value(s.note.scrollAxis.name),
            inputDrawMode: Value(s.note.inputDrawMode.name),
            defaultPageSpec:
                Value(jsonEncode(s.note.defaultPageSpec.toJson())),
            folderId: Value(s.note.folderId),
            rev: Value(s.note.rev),
            createdAt: Value(s.note.createdAt),
            updatedAt: Value(s.note.updatedAt),
            revealedTapeIds: Value(jsonEncode(s.note.revealedTapeIds)),
          ));

      // Wipe pages/layers/objects belonging to this note then re-insert.
      // For MVP this is acceptable; granular incremental writes land in P9.
      final existingPages = await (db.select(db.pages)
            ..where((p) => p.noteId.equals(s.note.id)))
          .get();
      for (final p in existingPages) {
        await (db.delete(db.layers)..where((l) => l.pageId.equals(p.id))).go();
        await (db.delete(db.pageObjects)
              ..where((o) => o.pageId.equals(p.id)))
            .go();
      }
      await (db.delete(db.pages)..where((p) => p.noteId.equals(s.note.id))).go();

      for (final p in s.pages) {
        await db.into(db.pages).insertOnConflictUpdate(PagesCompanion(
              id: Value(p.id),
              noteId: Value(p.noteId),
              idx: Value(p.index),
              spec: Value(jsonEncode(p.spec.toJson())),
              rev: Value(p.rev),
              updatedAt: Value(p.updatedAt),
            ));
        final layers = s.layersByPage[p.id] ?? const <Layer>[];
        for (final l in layers) {
          await db.into(db.layers).insertOnConflictUpdate(LayersCompanion(
                id: Value(l.id),
                pageId: Value(l.pageId),
                z: Value(l.z),
                name: Value(l.name),
                visible: Value(l.visible),
                locked: Value(l.locked),
                opacity: Value(l.opacity),
                rev: Value(l.rev),
              ));
        }
        for (final o in s.strokesByPage[p.id] ?? const <Stroke>[]) {
          await _putObject(o.id, o.pageId, o.layerId, 'stroke',
              jsonEncode(o.toJson()), o.bbox, o.rev, o.deleted, o.createdBy);
        }
        for (final o in s.shapesByPage[p.id] ?? const <ShapeObject>[]) {
          await _putObject(o.id, o.pageId, o.layerId, 'shape',
              jsonEncode(o.toJson()), o.bbox, o.rev, o.deleted, o.createdBy);
        }
        for (final o in s.textsByPage[p.id] ?? const <TextBoxObject>[]) {
          await _putObject(o.id, o.pageId, o.layerId, 'text',
              jsonEncode(o.toJson()), o.bbox, o.rev, o.deleted, o.createdBy);
        }
      }
    });
  }

  Future<void> _putObject(
    String id,
    String pageId,
    String layerId,
    String kind,
    String data,
    Bbox bbox,
    int rev,
    bool deleted,
    String? createdBy,
  ) async {
    await db.into(db.pageObjects).insertOnConflictUpdate(PageObjectsCompanion(
          id: Value(id),
          pageId: Value(pageId),
          layerId: Value(layerId),
          kind: Value(kind),
          data: Value(data),
          bboxMinX: Value(bbox.minX),
          bboxMinY: Value(bbox.minY),
          bboxMaxX: Value(bbox.maxX),
          bboxMaxY: Value(bbox.maxY),
          rev: Value(rev),
          deleted: Value(deleted),
          updatedAt: Value(DateTime.now().toUtc()),
        ));
  }

  // ── Apply server pull response ─────────────────────────────────────
  /// Saves a pull response (from GET /sync/{noteId}/pull?since=0) into the
  /// local DB. Used to hydrate notes that exist on the server but not locally.
  Future<void> applyServerPull(
    Map<String, dynamic> pullData, {
    required String ownerId,
  }) async {
    final now = DateTime.now().toUtc();
    final noteJson = pullData['note'] as Map<String, dynamic>?;
    if (noteJson == null) return;
    final noteId = noteJson['id'] as String;

    await db.transaction(() async {
      await db.into(db.notes).insertOnConflictUpdate(NotesCompanion(
        id: Value(noteId),
        ownerId: Value(ownerId),
        title: Value(noteJson['title'] as String? ?? 'Untitled'),
        scrollAxis: Value(noteJson['scrollAxis'] as String? ?? 'vertical'),
        inputDrawMode:
            Value(noteJson['inputDrawMode'] as String? ?? 'any'),
        defaultPageSpec: Value(
            jsonEncode(noteJson['defaultPageSpec'] ?? {})),
        rev: Value((noteJson['rev'] as num?)?.toInt() ?? 1),
        createdAt: Value(now),
        updatedAt: Value(
            DateTime.tryParse(noteJson['updatedAt'] as String? ?? '') ??
                now),
      ));

      for (final p in (pullData['pages'] as List? ?? const [])) {
        final pm = p as Map<String, dynamic>;
        await db.into(db.pages).insertOnConflictUpdate(PagesCompanion(
          id: Value(pm['id'] as String),
          noteId: Value(pm['noteId'] as String? ?? noteId),
          idx: Value((pm['index'] as num?)?.toInt() ?? 0),
          spec: Value(jsonEncode(pm['spec'] ?? {})),
          rev: Value((pm['rev'] as num?)?.toInt() ?? 1),
          updatedAt: Value(
              DateTime.tryParse(pm['updatedAt'] as String? ?? '') ?? now),
        ));
      }

      for (final l in (pullData['layers'] as List? ?? const [])) {
        final lm = l as Map<String, dynamic>;
        await db.into(db.layers).insertOnConflictUpdate(LayersCompanion(
          id: Value(lm['id'] as String),
          pageId: Value(lm['pageId'] as String),
          z: Value((lm['z'] as num?)?.toInt() ?? 0),
          name: Value(lm['name'] as String? ?? ''),
          visible: Value(lm['visible'] as bool? ?? true),
          locked: Value(lm['locked'] as bool? ?? false),
          opacity:
              Value((lm['opacity'] as num?)?.toDouble() ?? 1.0),
          rev: Value((lm['rev'] as num?)?.toInt() ?? 1),
        ));
      }

      for (final c in (pullData['changes'] as List? ?? const [])) {
        final cm = c as Map<String, dynamic>;
        final bboxList = cm['bbox'] as List?;
        final bbox = (bboxList != null && bboxList.length >= 4)
            ? Bbox(
                minX: (bboxList[0] as num).toDouble(),
                minY: (bboxList[1] as num).toDouble(),
                maxX: (bboxList[2] as num).toDouble(),
                maxY: (bboxList[3] as num).toDouble(),
              )
            : const Bbox(minX: 0, minY: 0, maxX: 0, maxY: 0);
        await _putObject(
          cm['id'] as String,
          cm['pageId'] as String,
          cm['layerId'] as String,
          cm['kind'] as String,
          jsonEncode(cm['data']),
          bbox,
          (cm['rev'] as num?)?.toInt() ?? 1,
          cm['deleted'] as bool? ?? false,
          null,
        );
      }
    });
  }

  // ── Load ──────────────────────────────────────────────────────────
  Future<NotebookState?> loadByNoteId(String noteId) async {
    final noteRow = await (db.select(db.notes)
          ..where((n) => n.id.equals(noteId)))
        .getSingleOrNull();
    if (noteRow == null) return null;

    List<String> _decodeIds(String raw) {
      try {
        return (jsonDecode(raw) as List).cast<String>();
      } catch (_) {
        return const [];
      }
    }

    final note = Note(
      id: noteRow.id,
      ownerId: noteRow.ownerId,
      title: noteRow.title,
      scrollAxis: ScrollAxis.values
          .firstWhere((a) => a.name == noteRow.scrollAxis),
      inputDrawMode: InputDrawMode.values
          .firstWhere((m) => m.name == noteRow.inputDrawMode),
      defaultPageSpec: PageSpec.fromJson(
          jsonDecode(noteRow.defaultPageSpec) as Map<String, dynamic>),
      folderId: noteRow.folderId,
      createdAt: noteRow.createdAt,
      updatedAt: noteRow.updatedAt,
      rev: noteRow.rev,
      revealedTapeIds: _decodeIds(noteRow.revealedTapeIds),
    );

    final pageRows = await (db.select(db.pages)
          ..where((p) => p.noteId.equals(noteId))
          ..orderBy([(p) => OrderingTerm(expression: p.idx)]))
        .get();

    final pages = <NotePage>[];
    final layersByPage = <String, List<Layer>>{};
    final strokesByPage = <String, List<Stroke>>{};
    final shapesByPage = <String, List<ShapeObject>>{};
    final textsByPage = <String, List<TextBoxObject>>{};
    final activeByPage = <String, String>{};

    for (final p in pageRows) {
      pages.add(NotePage(
        id: p.id,
        noteId: p.noteId,
        index: p.idx,
        spec: PageSpec.fromJson(jsonDecode(p.spec) as Map<String, dynamic>),
        updatedAt: p.updatedAt,
        rev: p.rev,
      ));
      final layerRows = await (db.select(db.layers)
            ..where((l) => l.pageId.equals(p.id))
            ..orderBy([(l) => OrderingTerm(expression: l.z)]))
          .get();
      final layers = layerRows
          .map((l) => Layer(
                id: l.id,
                pageId: l.pageId,
                z: l.z,
                name: l.name,
                visible: l.visible,
                locked: l.locked,
                opacity: l.opacity,
                rev: l.rev,
              ))
          .toList();
      layersByPage[p.id] = layers;
      activeByPage[p.id] = layers
          .firstWhere(
            (l) => !l.locked,
            orElse: () => layers.first,
          )
          .id;

      final objRows = await (db.select(db.pageObjects)
            ..where((o) => o.pageId.equals(p.id)))
          .get();
      strokesByPage[p.id] = [];
      shapesByPage[p.id] = [];
      textsByPage[p.id] = [];
      for (final o in objRows) {
        final json = jsonDecode(o.data) as Map<String, dynamic>;
        switch (o.kind) {
          case 'stroke':
            strokesByPage[p.id]!.add(Stroke.fromJson(json));
          case 'shape':
            shapesByPage[p.id]!.add(ShapeObject.fromJson(json));
          case 'text':
            textsByPage[p.id]!.add(TextBoxObject.fromJson(json));
          // 'tape' rows from older schema versions are silently dropped —
          // tape is now expressed as ToolKind.tape on a stroke.
        }
      }
    }

    return NotebookState(
      note: note,
      pages: pages,
      layersByPage: layersByPage,
      strokesByPage: strokesByPage,
      shapesByPage: shapesByPage,
      textsByPage: textsByPage,
      activeLayerByPage: activeByPage,
    );
  }
}

/// Debouncer used to coalesce rapid mutations into a single save call.
class Debouncer {
  Debouncer(this.duration);
  final Duration duration;
  Timer? _t;

  void schedule(void Function() fn) {
    _t?.cancel();
    _t = Timer(duration, fn);
  }

  void flush(void Function() fn) {
    _t?.cancel();
    _t = null;
    fn();
  }

  void cancel() { _t?.cancel(); _t = null; }
  void dispose() => _t?.cancel();
}
