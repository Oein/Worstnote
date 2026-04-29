// In-memory state model for the entire notebook (Riverpod). Holds the
// active note, its pages, layers per page, and page objects per page.
//
// Persistence: the controller writes through to a NotebookRepository
// (drift-backed) on every mutation, debounced 500ms.
//
// Note: "tape" is *not* a separate object kind — it's a stroke whose
// `tool == ToolKind.tape`. Tap-to-toggle behavior lives in CanvasView.

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../data/db/notee_database.dart';
import '../../data/db/repository.dart';
import '../../domain/layer.dart';
import '../../domain/note.dart';
import '../../domain/page.dart';
import '../../domain/page_object.dart';
import '../../domain/page_spec.dart';
import '../library/thumbnail_service.dart';

@immutable
class NotebookState {
  const NotebookState({
    required this.note,
    required this.pages,
    required this.layersByPage,
    required this.strokesByPage,
    required this.shapesByPage,
    required this.textsByPage,
    required this.activeLayerByPage,
  });

  final Note note;
  final List<NotePage> pages;
  final Map<String, List<Layer>> layersByPage;
  final Map<String, List<Stroke>> strokesByPage;
  final Map<String, List<ShapeObject>> shapesByPage;
  final Map<String, List<TextBoxObject>> textsByPage;
  final Map<String, String> activeLayerByPage;

  NotebookState copyWith({
    Note? note,
    List<NotePage>? pages,
    Map<String, List<Layer>>? layersByPage,
    Map<String, List<Stroke>>? strokesByPage,
    Map<String, List<ShapeObject>>? shapesByPage,
    Map<String, List<TextBoxObject>>? textsByPage,
    Map<String, String>? activeLayerByPage,
  }) =>
      NotebookState(
        note: note ?? this.note,
        pages: pages ?? this.pages,
        layersByPage: layersByPage ?? this.layersByPage,
        strokesByPage: strokesByPage ?? this.strokesByPage,
        shapesByPage: shapesByPage ?? this.shapesByPage,
        textsByPage: textsByPage ?? this.textsByPage,
        activeLayerByPage: activeLayerByPage ?? this.activeLayerByPage,
      );
}

/// Builds a fresh notebook with a single A4 page and a single "Default"
/// layer. (No separate Tape layer — tape is a stroke type.)
NotebookState bootstrapNotebook({
  String ownerId = 'local-user',
  String title = 'Untitled',
  String? folderId,
  String? noteId,
}) {
  final now = DateTime.now().toUtc();
  final id = noteId ?? newId();
  final pageId = newId();
  final defaultLayerId = newId();

  return NotebookState(
    note: Note(
      id: id,
      ownerId: ownerId,
      title: title,
      scrollAxis: ScrollAxis.vertical,
      defaultPageSpec: PageSpec.a4Blank(),
      createdAt: now,
      updatedAt: now,
      folderId: folderId,
    ),
    pages: [
      NotePage(
        id: pageId,
        noteId: id,
        index: 0,
        spec: PageSpec.a4Blank(),
        updatedAt: now,
      ),
    ],
    layersByPage: {
      pageId: [
        Layer(id: defaultLayerId, pageId: pageId, z: 0, name: 'Default'),
      ],
    },
    strokesByPage: {pageId: const []},
    shapesByPage: {pageId: const []},
    textsByPage: {pageId: const []},
    activeLayerByPage: {pageId: defaultLayerId},
  );
}

/// Provider for the underlying drift database singleton. Tests can override
/// with an in-memory variant via ProviderScope.overrides.
final databaseProvider = Provider<NoteeDatabase>(
  (ref) {
    final db = NoteeDatabase();
    ref.onDispose(db.close);
    return db;
  },
);

final repositoryProvider = Provider<NotebookRepository>(
  (ref) => NotebookRepository(ref.watch(databaseProvider)),
);

/// Currently-open note id. Library screen sets this to navigate into the
/// editor; the editor reads it via [notebookProvider].
final currentNoteIdProvider = StateProvider<String?>((ref) => null);

class NotebookController extends Notifier<NotebookState> {
  Debouncer? _saveDebouncer;
  bool _persistEnabled = false;

  // Undo/redo
  final List<NotebookState> _undoStack = [];
  final List<NotebookState> _redoStack = [];
  static const int _maxHistory = 50;
  bool _pauseHistory = false;

  void _pushUndo() {
    if (_pauseHistory) return;
    _undoStack.add(state);
    if (_undoStack.length > _maxHistory) _undoStack.removeAt(0);
    _redoStack.clear();
    ref.read(_canUndoProvider.notifier).state = true;
    ref.read(_canRedoProvider.notifier).state = false;
  }

  void undo() {
    if (_undoStack.isEmpty) return;
    _pauseHistory = true;
    _redoStack.add(state);
    state = _undoStack.removeLast();
    _pauseHistory = false;
    ref.read(_canUndoProvider.notifier).state = _undoStack.isNotEmpty;
    ref.read(_canRedoProvider.notifier).state = true;
  }

  void redo() {
    if (_redoStack.isEmpty) return;
    _pauseHistory = true;
    _undoStack.add(state);
    state = _redoStack.removeLast();
    _pauseHistory = false;
    ref.read(_canUndoProvider.notifier).state = true;
    ref.read(_canRedoProvider.notifier).state = _redoStack.isNotEmpty;
  }

  @override
  NotebookState build() {
    // Every time the note changes (currentNoteIdProvider flips), build() is
    // called again on the SAME Notifier instance. Clear history so undo/redo
    // from the previous note never leaks into the new one.
    _undoStack.clear();
    _redoStack.clear();
    // CRITICAL: also reset persistence flag. Otherwise, when a previous note
    // had set _persistEnabled = true, exiting (noteId → null) would let the
    // listenSelf save a fresh bootstrap to the DB as a new note.
    _persistEnabled = false;
    // Riverpod forbids modifying other providers during build(). Defer the
    // reset to the next microtask so build() has returned first.
    Future<void>.microtask(() {
      try {
        ref.read(_canUndoProvider.notifier).state = false;
        ref.read(_canRedoProvider.notifier).state = false;
      } catch (_) {}
    });

    _saveDebouncer = Debouncer(const Duration(milliseconds: 500));
    ref.onDispose(() => _saveDebouncer?.dispose());
    // Auto-save on every state change (debounced).
    listenSelf((_, __) => _scheduleSave());

    final noteId = ref.watch(currentNoteIdProvider);
    if (noteId == null) {
      // No note selected — return a placeholder but keep persistence OFF so
      // the bootstrap is never written to disk.
      return bootstrapNotebook();
    }
    final initial = bootstrapNotebook(noteId: noteId);
    _hydrate(noteId);
    return initial;
  }

  Future<void> _hydrate(String noteId) async {
    try {
      final repo = ref.read(repositoryProvider);
      final loaded = await repo.loadByNoteId(noteId);
      if (loaded != null) {
        state = loaded;
      } else {
        await repo.saveAll(state);
      }
    } catch (_) {/* keep bootstrap state on persistence error */}
    finally {
      _persistEnabled = true;
    }
  }

  void _scheduleSave() {
    if (!_persistEnabled) return;
    _saveDebouncer?.schedule(() async {
      try {
        await ref.read(repositoryProvider).saveAll(state);
        _scheduleThumbnail();
      } catch (_) {/* ignore */}
    });
  }

  void _scheduleThumbnail() {
    if (state.pages.isEmpty) return;
    final firstPage = state.pages.first;
    // Note cover thumbnail (library screen)
    ThumbnailService.instance.schedule(
      noteId: state.note.id,
      spec: firstPage.spec,
      strokes: state.strokesByPage[firstPage.id] ?? const [],
      shapes: state.shapesByPage[firstPage.id] ?? const [],
      texts: state.textsByPage[firstPage.id] ?? const [],
    );
    // Per-page thumbnails (canvas scroll preview)
    for (final page in state.pages) {
      ThumbnailService.instance.schedulePage(
        pageId: page.id,
        spec: page.spec,
        strokes: state.strokesByPage[page.id] ?? const [],
        shapes: state.shapesByPage[page.id] ?? const [],
        texts: state.textsByPage[page.id] ?? const [],
      );
    }
  }

  /// Flush any pending debounced save immediately.
  /// Also schedules a thumbnail regeneration so the library cover is up-to-date
  /// when the user navigates back from the editor.
  Future<void> flushDebounce() async {
    if (!_persistEnabled) return;
    final repo = ref.read(repositoryProvider);
    _saveDebouncer?.flush(() async {
      try { await repo.saveAll(state); } catch (_) {}
    });
    // Invalidate the stale cached thumbnail so the library shows a spinner
    // while the new one renders, rather than showing the old image.
    ThumbnailService.instance.invalidate(state.note.id);
    _scheduleThumbnail();
  }

  // ── Note settings ─────────────────────────────────────────────────────
  void setTitle(String t) => state = state.copyWith(
        note: state.note.copyWith(
          title: t,
          updatedAt: DateTime.now().toUtc(),
        ),
      );

  void setScrollAxis(ScrollAxis axis) => state = state.copyWith(
        note: state.note.copyWith(
          scrollAxis: axis,
          updatedAt: DateTime.now().toUtc(),
        ),
      );

  void setInputDrawMode(InputDrawMode mode) => state = state.copyWith(
        note: state.note.copyWith(
          inputDrawMode: mode,
          updatedAt: DateTime.now().toUtc(),
        ),
      );

  void toggleTapeRevealed(String strokeId) {
    final ids = Set<String>.from(state.note.revealedTapeIds);
    if (ids.contains(strokeId)) {
      ids.remove(strokeId);
    } else {
      ids.add(strokeId);
    }
    state = state.copyWith(
      note: state.note.copyWith(
        revealedTapeIds: ids.toList(),
        updatedAt: DateTime.now().toUtc(),
      ),
    );
  }

  void showAllTapes() {
    final tapeIds = <String>[];
    for (final strokes in state.strokesByPage.values) {
      for (final s in strokes) {
        if (!s.deleted && s.tool == ToolKind.tape) tapeIds.add(s.id);
      }
    }
    state = state.copyWith(
      note: state.note.copyWith(
        revealedTapeIds: tapeIds,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
  }

  void hideAllTapes() => state = state.copyWith(
        note: state.note.copyWith(
          revealedTapeIds: const [],
          updatedAt: DateTime.now().toUtc(),
        ),
      );

  void setActiveLayer(String pageId, String layerId) {
    final next = Map<String, String>.from(state.activeLayerByPage);
    next[pageId] = layerId;
    state = state.copyWith(activeLayerByPage: next);
  }

  // ── Pages ────────────────────────────────────────────────────────────
  void addPage({PageSpec? spec, int? at}) {
    final s = spec ?? state.note.defaultPageSpec;
    final pageId = newId();
    final defaultLayerId = newId();
    final pages = [...state.pages];
    final idx = at ?? pages.length;
    final now = DateTime.now().toUtc();
    pages.insert(
      idx,
      NotePage(
        id: pageId,
        noteId: state.note.id,
        index: idx,
        spec: s,
        updatedAt: now,
      ),
    );
    for (var i = 0; i < pages.length; i++) {
      pages[i] = pages[i].copyWith(index: i);
    }
    _pushUndo();
    state = state.copyWith(
      pages: pages,
      layersByPage: {
        ...state.layersByPage,
        pageId: [
          Layer(id: defaultLayerId, pageId: pageId, z: 0, name: 'Default'),
        ],
      },
      strokesByPage: {...state.strokesByPage, pageId: const []},
      shapesByPage: {...state.shapesByPage, pageId: const []},
      textsByPage: {...state.textsByPage, pageId: const []},
      activeLayerByPage: {
        ...state.activeLayerByPage,
        pageId: defaultLayerId,
      },
    );
  }

  void removePage(String pageId) {
    if (state.pages.length <= 1) return; // keep at least one
    final pages = state.pages.where((p) => p.id != pageId).toList();
    for (var i = 0; i < pages.length; i++) {
      pages[i] = pages[i].copyWith(index: i);
    }
    final layers = Map<String, List<Layer>>.from(state.layersByPage)
      ..remove(pageId);
    final strokes = Map<String, List<Stroke>>.from(state.strokesByPage)
      ..remove(pageId);
    final shapes = Map<String, List<ShapeObject>>.from(state.shapesByPage)
      ..remove(pageId);
    final texts = Map<String, List<TextBoxObject>>.from(state.textsByPage)
      ..remove(pageId);
    final actives = Map<String, String>.from(state.activeLayerByPage)
      ..remove(pageId);
    _pushUndo();
    state = state.copyWith(
      pages: pages,
      layersByPage: layers,
      strokesByPage: strokes,
      shapesByPage: shapes,
      textsByPage: texts,
      activeLayerByPage: actives,
    );
  }

  void reorderPage(int oldIndex, int newIndex) {
    final pages = [...state.pages];
    if (oldIndex < 0 || oldIndex >= pages.length) return;
    if (newIndex < 0 || newIndex >= pages.length) return;
    if (oldIndex == newIndex) return;
    final page = pages.removeAt(oldIndex);
    pages.insert(newIndex, page);
    for (var i = 0; i < pages.length; i++) {
      pages[i] = pages[i].copyWith(index: i);
    }
    _pushUndo();
    state = state.copyWith(pages: pages);
    _scheduleSave();
  }

  void setPageSpec(String pageId, PageSpec spec) {
    final pages = state.pages.map((p) {
      if (p.id != pageId) return p;
      return p.copyWith(spec: spec, updatedAt: DateTime.now().toUtc());
    }).toList();
    state = state.copyWith(pages: pages);
  }

  // ── Layers ───────────────────────────────────────────────────────────
  void addLayer(String pageId, {String? name}) {
    final layers = [...?state.layersByPage[pageId]];
    final maxZ = layers.fold<int>(0, (m, l) => l.z > m ? l.z : m);
    layers.add(Layer(
      id: newId(),
      pageId: pageId,
      z: maxZ + 1,
      name: name ?? 'Layer ${layers.length + 1}',
    ));
    state = state.copyWith(
      layersByPage: {...state.layersByPage, pageId: layers},
    );
  }

  void removeLayer(String pageId, String layerId) {
    final layers = state.layersByPage[pageId];
    if (layers == null || layers.length <= 1) return;
    final next = layers.where((l) => l.id != layerId).toList();
    final actives = Map<String, String>.from(state.activeLayerByPage);
    if (actives[pageId] == layerId) {
      actives[pageId] = next.first.id;
    }
    final strokes = (state.strokesByPage[pageId] ?? const <Stroke>[])
        .where((o) => o.layerId != layerId)
        .toList();
    final shapes = (state.shapesByPage[pageId] ?? const <ShapeObject>[])
        .where((o) => o.layerId != layerId)
        .toList();
    final texts = (state.textsByPage[pageId] ?? const <TextBoxObject>[])
        .where((o) => o.layerId != layerId)
        .toList();
    state = state.copyWith(
      layersByPage: {...state.layersByPage, pageId: next},
      strokesByPage: {...state.strokesByPage, pageId: strokes},
      shapesByPage: {...state.shapesByPage, pageId: shapes},
      textsByPage: {...state.textsByPage, pageId: texts},
      activeLayerByPage: actives,
    );
  }

  void mutateLayer(String pageId, String layerId, Layer Function(Layer) fn) {
    final layers = state.layersByPage[pageId];
    if (layers == null) return;
    final next = layers.map((l) => l.id == layerId ? fn(l) : l).toList();
    state = state.copyWith(
      layersByPage: {...state.layersByPage, pageId: next},
    );
  }

  void toggleLayerVisible(String pageId, String layerId) =>
      mutateLayer(pageId, layerId,
          (l) => l.copyWith(visible: !l.visible, rev: l.rev + 1));

  void toggleLayerLocked(String pageId, String layerId) =>
      mutateLayer(pageId, layerId,
          (l) => l.copyWith(locked: !l.locked, rev: l.rev + 1));

  void setLayerOpacity(String pageId, String layerId, double opacity) =>
      mutateLayer(pageId, layerId,
          (l) => l.copyWith(opacity: opacity, rev: l.rev + 1));

  void renameLayer(String pageId, String layerId, String name) =>
      mutateLayer(pageId, layerId,
          (l) => l.copyWith(name: name, rev: l.rev + 1));

  void reorderLayers(String pageId, List<String> orderedIds) {
    final layers = state.layersByPage[pageId];
    if (layers == null) return;
    final byId = {for (final l in layers) l.id: l};
    final next = <Layer>[];
    for (var i = 0; i < orderedIds.length; i++) {
      final l = byId[orderedIds[i]];
      if (l != null) next.add(l.copyWith(z: i, rev: l.rev + 1));
    }
    state = state.copyWith(
      layersByPage: {...state.layersByPage, pageId: next},
    );
  }

  // ── Objects (strokes/shapes/text) ──────────────────────────────────
  String _resolveTargetLayer(String pageId) {
    final layers = state.layersByPage[pageId] ?? const <Layer>[];
    if (layers.isEmpty) return '';
    final activeId = state.activeLayerByPage[pageId];
    final active = layers.firstWhere(
      (l) => l.id == activeId,
      orElse: () => layers.first,
    );
    if (!active.locked) return active.id;
    final candidates = layers.where((l) => !l.locked).toList()
      ..sort((a, b) => b.z.compareTo(a.z));
    return candidates.isNotEmpty ? candidates.first.id : active.id;
  }

  void addStroke(Stroke s) {
    final list = [
      ...?state.strokesByPage[s.pageId],
      s.copyWith(layerId: _resolveTargetLayer(s.pageId)),
    ];
    _pushUndo();
    state = state.copyWith(
      strokesByPage: {...state.strokesByPage, s.pageId: list},
    );
  }

  void removeStrokes(String pageId, Set<String> ids) {
    final cur = state.strokesByPage[pageId] ?? const <Stroke>[];
    final next = cur
        .map((s) => ids.contains(s.id) ? s.copyWith(deleted: true) : s)
        .toList();
    _pushUndo();
    state = state.copyWith(
      strokesByPage: {...state.strokesByPage, pageId: next},
    );
  }

  /// For partial-erase by the Standard eraser: delete every stroke in
  /// [deleteIds] and append [adds] in one state update (single undo entry).
  void replaceStrokes(
      String pageId, Set<String> deleteIds, List<Stroke> adds) {
    if (deleteIds.isEmpty && adds.isEmpty) return;
    final cur = state.strokesByPage[pageId] ?? const <Stroke>[];
    final kept = cur
        .map((s) => deleteIds.contains(s.id) ? s.copyWith(deleted: true) : s)
        .toList();
    final next = [...kept, ...adds];
    state = state.copyWith(
      strokesByPage: {...state.strokesByPage, pageId: next},
    );
  }

  void addShape(ShapeObject s) {
    final list = [
      ...?state.shapesByPage[s.pageId],
      s.copyWith(layerId: _resolveTargetLayer(s.pageId)),
    ];
    _pushUndo();
    state = state.copyWith(
      shapesByPage: {...state.shapesByPage, s.pageId: list},
    );
  }

  void addText(TextBoxObject t) {
    final list = [
      ...?state.textsByPage[t.pageId],
      t.copyWith(layerId: _resolveTargetLayer(t.pageId)),
    ];
    _pushUndo();
    state = state.copyWith(
      textsByPage: {...state.textsByPage, t.pageId: list},
    );
  }

  void updateText(TextBoxObject t) {
    final list = (state.textsByPage[t.pageId] ?? const <TextBoxObject>[])
        .map((x) => x.id == t.id ? t : x)
        .toList();
    state = state.copyWith(
      textsByPage: {...state.textsByPage, t.pageId: list},
    );
  }

  /// Reorder selected objects across the unified layer-1 z-order
  /// (shapes + non-tape strokes share a single z-order based on createdAt).
  /// Within-list order is also adjusted so cross-type ordering works.
  /// [direction]: -1=backward, 0=to back, +1=forward, +2=to front.
  void reorderObjects(
      String pageId, Set<String> ids, int direction) {
    if (ids.isEmpty) return;
    _bumpCreatedAtForReorder(pageId, ids, direction);
    List<T> reorder<T>(List<T> list, bool Function(T) isSelected) {
      final selectedIdx = <int>[];
      for (var i = 0; i < list.length; i++) {
        if (isSelected(list[i])) selectedIdx.add(i);
      }
      if (selectedIdx.isEmpty) return list;
      final result = List<T>.from(list);
      if (direction == 2) {
        // bring to front: move selected to end, in original order
        final selected = selectedIdx.map((i) => list[i]).toList();
        result.removeWhere(isSelected);
        result.addAll(selected);
      } else if (direction == 0) {
        // send to back: move selected to start, in original order
        final selected = selectedIdx.map((i) => list[i]).toList();
        result.removeWhere(isSelected);
        result.insertAll(0, selected);
      } else if (direction == 1) {
        // forward by one: walk from the back so swaps don't collide
        for (var k = selectedIdx.length - 1; k >= 0; k--) {
          final i = selectedIdx[k];
          if (i < result.length - 1 && !isSelected(result[i + 1])) {
            final tmp = result[i + 1];
            result[i + 1] = result[i];
            result[i] = tmp;
          }
        }
      } else if (direction == -1) {
        for (var k = 0; k < selectedIdx.length; k++) {
          final i = selectedIdx[k];
          if (i > 0 && !isSelected(result[i - 1])) {
            final tmp = result[i - 1];
            result[i - 1] = result[i];
            result[i] = tmp;
          }
        }
      }
      return result;
    }

    final strokes =
        reorder(state.strokesByPage[pageId] ?? const <Stroke>[],
            (s) => ids.contains(s.id));
    final shapes =
        reorder(state.shapesByPage[pageId] ?? const <ShapeObject>[],
            (s) => ids.contains(s.id));
    final texts =
        reorder(state.textsByPage[pageId] ?? const <TextBoxObject>[],
            (t) => ids.contains(t.id));
    _pushUndo();
    state = state.copyWith(
      strokesByPage: {...state.strokesByPage, pageId: strokes},
      shapesByPage: {...state.shapesByPage, pageId: shapes},
      textsByPage: {...state.textsByPage, pageId: texts},
    );
  }

  /// Mutate `createdAt` so the unified renderer (which sorts by createdAt)
  /// shows the selected objects at the requested z-position.
  void _bumpCreatedAtForReorder(
      String pageId, Set<String> ids, int direction) {
    final strokes = state.strokesByPage[pageId] ?? const <Stroke>[];
    final shapes = state.shapesByPage[pageId] ?? const <ShapeObject>[];
    final texts = state.textsByPage[pageId] ?? const <TextBoxObject>[];
    // Build (id, createdAt) pairs across all three types.
    final all = <(String, DateTime)>[];
    for (final s in strokes) {
      if (!s.deleted) all.add((s.id, s.createdAt));
    }
    for (final s in shapes) {
      if (!s.deleted) all.add((s.id, s.createdAt));
    }
    for (final t in texts) {
      if (!t.deleted) all.add((t.id, t.createdAt));
    }
    if (all.isEmpty) return;
    all.sort((a, b) => a.$2.compareTo(b.$2));

    // Compute new createdAt for selected items.
    final newAt = <String, DateTime>{};
    if (direction == 2) {
      // bring to front: bump well above the current max
      final base = all.last.$2.add(const Duration(seconds: 1));
      var i = 0;
      for (final id in ids) {
        newAt[id] = base.add(Duration(microseconds: i++));
      }
    } else if (direction == 0) {
      // send to back: well below current min
      final base = all.first.$2.subtract(Duration(seconds: ids.length + 1));
      var i = 0;
      for (final id in ids) {
        newAt[id] = base.add(Duration(microseconds: i++));
      }
    } else {
      // forward / backward by 1: swap createdAt with adjacent non-selected
      final indexed =
          all.indexed.map((e) => (e.$1, e.$2.$1, e.$2.$2)).toList();
      final selectedIndices = <int>[];
      for (var k = 0; k < indexed.length; k++) {
        if (ids.contains(indexed[k].$2)) selectedIndices.add(k);
      }
      if (direction == 1) {
        // walk from the back so swaps don't collide
        for (var k = selectedIndices.length - 1; k >= 0; k--) {
          final idx = selectedIndices[k];
          if (idx < indexed.length - 1 &&
              !ids.contains(indexed[idx + 1].$2)) {
            final tmp = indexed[idx + 1].$3;
            newAt[indexed[idx + 1].$2] = indexed[idx].$3;
            newAt[indexed[idx].$2] = tmp;
            indexed[idx + 1] =
                (indexed[idx + 1].$1, indexed[idx + 1].$2, indexed[idx].$3);
            indexed[idx] = (indexed[idx].$1, indexed[idx].$2, tmp);
          }
        }
      } else {
        // direction == -1
        for (var k = 0; k < selectedIndices.length; k++) {
          final idx = selectedIndices[k];
          if (idx > 0 && !ids.contains(indexed[idx - 1].$2)) {
            final tmp = indexed[idx - 1].$3;
            newAt[indexed[idx - 1].$2] = indexed[idx].$3;
            newAt[indexed[idx].$2] = tmp;
            indexed[idx - 1] =
                (indexed[idx - 1].$1, indexed[idx - 1].$2, indexed[idx].$3);
            indexed[idx] = (indexed[idx].$1, indexed[idx].$2, tmp);
          }
        }
      }
    }

    if (newAt.isEmpty) return;
    final outStrokes = strokes
        .map((s) => newAt.containsKey(s.id)
            ? s.copyWith(createdAt: newAt[s.id]!)
            : s)
        .toList();
    final outShapes = shapes
        .map((s) => newAt.containsKey(s.id)
            ? s.copyWith(createdAt: newAt[s.id]!)
            : s)
        .toList();
    final outTexts = texts
        .map((t) => newAt.containsKey(t.id)
            ? t.copyWith(createdAt: newAt[t.id]!)
            : t)
        .toList();
    state = state.copyWith(
      strokesByPage: {...state.strokesByPage, pageId: outStrokes},
      shapesByPage: {...state.shapesByPage, pageId: outShapes},
      textsByPage: {...state.textsByPage, pageId: outTexts},
    );
  }

  /// Duplicate the selected objects (offset slightly). Returns the new IDs.
  Set<String> duplicateObjects(String pageId, Set<String> ids) {
    if (ids.isEmpty) return const {};
    const off = 12.0;
    final newIds = <String>{};
    final strokesIn = state.strokesByPage[pageId] ?? const <Stroke>[];
    final shapesIn = state.shapesByPage[pageId] ?? const <ShapeObject>[];
    final textsIn = state.textsByPage[pageId] ?? const <TextBoxObject>[];

    final addStrokes = <Stroke>[];
    for (final s in strokesIn) {
      if (!ids.contains(s.id)) continue;
      final id = newId();
      newIds.add(id);
      addStrokes.add(s.copyWith(
        id: id,
        points: s.points
            .map((p) => p.copyWith(x: p.x + off, y: p.y + off))
            .toList(),
        bbox: Bbox(
          minX: s.bbox.minX + off,
          minY: s.bbox.minY + off,
          maxX: s.bbox.maxX + off,
          maxY: s.bbox.maxY + off,
        ),
      ));
    }
    final addShapes = <ShapeObject>[];
    for (final s in shapesIn) {
      if (!ids.contains(s.id)) continue;
      final id = newId();
      newIds.add(id);
      addShapes.add(s.copyWith(
        id: id,
        bbox: Bbox(
          minX: s.bbox.minX + off,
          minY: s.bbox.minY + off,
          maxX: s.bbox.maxX + off,
          maxY: s.bbox.maxY + off,
        ),
      ));
    }
    final addTexts = <TextBoxObject>[];
    for (final t in textsIn) {
      if (!ids.contains(t.id)) continue;
      final id = newId();
      newIds.add(id);
      addTexts.add(t.copyWith(
        id: id,
        bbox: Bbox(
          minX: t.bbox.minX + off,
          minY: t.bbox.minY + off,
          maxX: t.bbox.maxX + off,
          maxY: t.bbox.maxY + off,
        ),
      ));
    }

    _pushUndo();
    state = state.copyWith(
      strokesByPage: {
        ...state.strokesByPage,
        pageId: [...strokesIn, ...addStrokes],
      },
      shapesByPage: {
        ...state.shapesByPage,
        pageId: [...shapesIn, ...addShapes],
      },
      textsByPage: {
        ...state.textsByPage,
        pageId: [...textsIn, ...addTexts],
      },
    );
    return newIds;
  }

  void deleteObjects(String pageId, Set<String> ids) {
    final strokes = (state.strokesByPage[pageId] ?? const <Stroke>[])
        .map((s) => ids.contains(s.id) ? s.copyWith(deleted: true) : s)
        .toList();
    final shapes = (state.shapesByPage[pageId] ?? const <ShapeObject>[])
        .map((s) => ids.contains(s.id) ? s.copyWith(deleted: true) : s)
        .toList();
    final texts = (state.textsByPage[pageId] ?? const <TextBoxObject>[])
        .map((s) => ids.contains(s.id) ? s.copyWith(deleted: true) : s)
        .toList();
    _pushUndo();
    state = state.copyWith(
      strokesByPage: {...state.strokesByPage, pageId: strokes},
      shapesByPage: {...state.shapesByPage, pageId: shapes},
      textsByPage: {...state.textsByPage, pageId: texts},
    );
  }

  /// Translate selected objects by [delta] (in page-space points).
  /// Pushes an undo entry — use [translateObjectsLive] for incremental
  /// drag moves to avoid flooding the undo stack.
  void translateObjects(
      String pageId, Set<String> strokeIds, Set<String> shapeIds,
      Set<String> textIds, Offset delta) {
    _pushUndo();
    _applyTranslate(pageId, strokeIds, shapeIds, textIds, delta);
  }

  /// Like [translateObjects] but does NOT push an undo entry.
  /// Caller is responsible for calling [pushUndo] exactly once before
  /// the first incremental move.
  void translateObjectsLive(
      String pageId, Set<String> strokeIds, Set<String> shapeIds,
      Set<String> textIds, Offset delta) {
    _applyTranslate(pageId, strokeIds, shapeIds, textIds, delta);
  }

  /// Push an undo checkpoint without changing state (call before a live drag).
  void pushUndo() => _pushUndo();

  /// Scale selected objects from [oldBbox] to [newBbox] (page-space rects).
  /// Live counterpart — does NOT push undo. Caller must [pushUndo] before
  /// the first call of a drag.
  void scaleObjectsLive(
    String pageId, Set<String> strokeIds, Set<String> shapeIds,
    Set<String> textIds, Rect oldBbox, Rect newBbox,
  ) {
    if (oldBbox.width <= 0 || oldBbox.height <= 0) return;
    final sx = newBbox.width / oldBbox.width;
    final sy = newBbox.height / oldBbox.height;
    final ox = oldBbox.left;
    final oy = oldBbox.top;
    final nx = newBbox.left;
    final ny = newBbox.top;

    double mapX(double x) => nx + (x - ox) * sx;
    double mapY(double y) => ny + (y - oy) * sy;
    Bbox mapBbox(Bbox b) {
      final x1 = mapX(b.minX), y1 = mapY(b.minY);
      final x2 = mapX(b.maxX), y2 = mapY(b.maxY);
      return Bbox(
        minX: x1 < x2 ? x1 : x2,
        minY: y1 < y2 ? y1 : y2,
        maxX: x1 > x2 ? x1 : x2,
        maxY: y1 > y2 ? y1 : y2,
      );
    }

    final strokes = (state.strokesByPage[pageId] ?? const <Stroke>[])
        .map((s) {
      if (!strokeIds.contains(s.id)) return s;
      final pts = s.points
          .map((p) => p.copyWith(x: mapX(p.x), y: mapY(p.y)))
          .toList();
      return s.copyWith(points: pts, bbox: mapBbox(s.bbox));
    }).toList();

    final shapes = (state.shapesByPage[pageId] ?? const <ShapeObject>[])
        .map((s) {
      if (!shapeIds.contains(s.id)) return s;
      return s.copyWith(bbox: mapBbox(s.bbox));
    }).toList();

    // Text: when the selection contains only text (no strokes/shapes), resize
    // the bbox freely (non-uniform X/Y) and keep font size so text reflows.
    // When mixed with strokes/shapes, use uniform scale with font resize.
    final onlyText = strokeIds.isEmpty && shapeIds.isEmpty;
    final texts = (state.textsByPage[pageId] ?? const <TextBoxObject>[])
        .map((t) {
      if (!textIds.contains(t.id)) return t;
      if (onlyText) {
        return t.copyWith(bbox: mapBbox(t.bbox));
      }
      final uniform = sx > sy ? sx : sy;
      final relX = t.bbox.minX - oldBbox.left;
      final relY = t.bbox.minY - oldBbox.top;
      final newMinX = newBbox.left + relX * uniform;
      final newMinY = newBbox.top + relY * uniform;
      final w = (t.bbox.maxX - t.bbox.minX) * uniform;
      final h = (t.bbox.maxY - t.bbox.minY) * uniform;
      return t.copyWith(
        bbox: Bbox(
          minX: newMinX, minY: newMinY,
          maxX: newMinX + w, maxY: newMinY + h,
        ),
        fontSizePt: (t.fontSizePt * uniform).clamp(4.0, 400.0),
      );
    }).toList();

    state = state.copyWith(
      strokesByPage: {...state.strokesByPage, pageId: strokes},
      shapesByPage: {...state.shapesByPage, pageId: shapes},
      textsByPage: {...state.textsByPage, pageId: texts},
    );
  }

  /// Rotate strokes in [strokeIds] by [deltaRad] radians around [center].
  /// Live counterpart — caller pushes undo before drag-start.
  ///
  /// Shapes and text boxes do not yet have a rotation field; they are
  /// translated so their bbox center moves with the rotation, but their
  /// orientation stays axis-aligned.
  void rotateObjectsLive(
    String pageId,
    Set<String> strokeIds,
    Set<String> shapeIds,
    Set<String> textIds,
    Offset center,
    double deltaRad,
  ) {
    final cosA = math.cos(deltaRad);
    final sinA = math.sin(deltaRad);
    Offset rot(Offset p) {
      final dx = p.dx - center.dx;
      final dy = p.dy - center.dy;
      return Offset(
        center.dx + dx * cosA - dy * sinA,
        center.dy + dx * sinA + dy * cosA,
      );
    }

    Bbox bboxFromPoints(Iterable<Offset> pts) {
      double minX = double.infinity, minY = double.infinity;
      double maxX = -double.infinity, maxY = -double.infinity;
      for (final p in pts) {
        if (p.dx < minX) minX = p.dx;
        if (p.dy < minY) minY = p.dy;
        if (p.dx > maxX) maxX = p.dx;
        if (p.dy > maxY) maxY = p.dy;
      }
      return Bbox(minX: minX, minY: minY, maxX: maxX, maxY: maxY);
    }

    final strokes = (state.strokesByPage[pageId] ?? const <Stroke>[])
        .map((s) {
      if (!strokeIds.contains(s.id)) return s;
      final newPts = s.points.map((p) {
        final r = rot(Offset(p.x, p.y));
        return p.copyWith(x: r.dx, y: r.dy);
      }).toList();
      return s.copyWith(
        points: newPts,
        bbox: bboxFromPoints(newPts.map((p) => Offset(p.x, p.y))),
      );
    }).toList();

    Bbox rotateBboxCorners(Bbox b) {
      final corners = [
        rot(Offset(b.minX, b.minY)),
        rot(Offset(b.maxX, b.minY)),
        rot(Offset(b.minX, b.maxY)),
        rot(Offset(b.maxX, b.maxY)),
      ];
      return bboxFromPoints(corners);
    }

    final shapes = (state.shapesByPage[pageId] ?? const <ShapeObject>[])
        .map((s) {
      if (!shapeIds.contains(s.id)) return s;
      return s.copyWith(bbox: rotateBboxCorners(s.bbox));
    }).toList();

    final texts = (state.textsByPage[pageId] ?? const <TextBoxObject>[])
        .map((t) {
      if (!textIds.contains(t.id)) return t;
      return t.copyWith(bbox: rotateBboxCorners(t.bbox));
    }).toList();

    state = state.copyWith(
      strokesByPage: {...state.strokesByPage, pageId: strokes},
      shapesByPage: {...state.shapesByPage, pageId: shapes},
      textsByPage: {...state.textsByPage, pageId: texts},
    );
  }

  void _applyTranslate(
      String pageId, Set<String> strokeIds, Set<String> shapeIds,
      Set<String> textIds, Offset delta) {
    if (delta == Offset.zero) return;
    final dx = delta.dx, dy = delta.dy;

    final strokes = (state.strokesByPage[pageId] ?? const <Stroke>[])
        .map((s) {
      if (!strokeIds.contains(s.id)) return s;
      final pts = s.points
          .map((p) => p.copyWith(x: p.x + dx, y: p.y + dy))
          .toList();
      final bbox = Bbox(
        minX: s.bbox.minX + dx,
        minY: s.bbox.minY + dy,
        maxX: s.bbox.maxX + dx,
        maxY: s.bbox.maxY + dy,
      );
      return s.copyWith(points: pts, bbox: bbox);
    }).toList();

    final shapes = (state.shapesByPage[pageId] ?? const <ShapeObject>[])
        .map((s) {
      if (!shapeIds.contains(s.id)) return s;
      return s.copyWith(
        bbox: Bbox(
          minX: s.bbox.minX + dx,
          minY: s.bbox.minY + dy,
          maxX: s.bbox.maxX + dx,
          maxY: s.bbox.maxY + dy,
        ),
      );
    }).toList();

    final texts = (state.textsByPage[pageId] ?? const <TextBoxObject>[])
        .map((t) {
      if (!textIds.contains(t.id)) return t;
      return t.copyWith(
        bbox: Bbox(
          minX: t.bbox.minX + dx,
          minY: t.bbox.minY + dy,
          maxX: t.bbox.maxX + dx,
          maxY: t.bbox.maxY + dy,
        ),
      );
    }).toList();

    state = state.copyWith(
      strokesByPage: {...state.strokesByPage, pageId: strokes},
      shapesByPage: {...state.shapesByPage, pageId: shapes},
      textsByPage: {...state.textsByPage, pageId: texts},
    );
  }
}

// Private helpers — track can-undo / can-redo state as plain booleans so the
// toolbar can watch them without coupling to the stack lists themselves.
final _canUndoProvider = StateProvider<bool>((ref) => false);
final _canRedoProvider = StateProvider<bool>((ref) => false);

/// Public providers — watch these in the toolbar to enable/disable buttons.
final canUndoProvider = Provider<bool>((ref) => ref.watch(_canUndoProvider));
final canRedoProvider = Provider<bool>((ref) => ref.watch(_canRedoProvider));

final notebookProvider =
    NotifierProvider<NotebookController, NotebookState>(NotebookController.new);
