// LibraryState — top-level browse state for the home screen. Lists all
// folders + all note summaries, plus the currently-viewed folder id (null
// for root). Folders nest by [Folder.parentId]; notes belong to a folder
// via [NoteSummary.folderId].

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../data/db/repository.dart';
import '../../domain/folder.dart';
import '../lock/note_lock_service.dart';
import '../sync/sync_actions.dart';
import '../sync/sync_state.dart';
import '../../domain/layer.dart';
import '../../domain/note.dart';
import '../../domain/page.dart';
import '../../domain/page_object.dart';
import '../../domain/page_spec.dart';
import '../import/goodnotes_importer.dart';
import '../notebook/notebook_state.dart';

@immutable
class LibraryState {
  const LibraryState({
    required this.folders,
    required this.notes,
    required this.currentFolderId,
  });

  final List<Folder> folders;
  final List<NoteSummary> notes;
  final String? currentFolderId;

  Folder? get currentFolder =>
      currentFolderId == null ? null : folders.where((f) => f.id == currentFolderId).cast<Folder?>().firstOrNull;

  List<Folder> get childFoldersHere =>
      folders.where((f) => f.parentId == currentFolderId).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  List<NoteSummary> get notesHere =>
      notes.where((n) => n.folderId == currentFolderId).toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  /// Path from root to currentFolder (inclusive). Empty if root.
  List<Folder> breadcrumb() {
    final path = <Folder>[];
    var id = currentFolderId;
    while (id != null) {
      final f = folders.where((x) => x.id == id).cast<Folder?>().firstOrNull;
      if (f == null) break;
      path.insert(0, f);
      id = f.parentId;
    }
    return path;
  }

  LibraryState copyWith({
    List<Folder>? folders,
    List<NoteSummary>? notes,
    String? currentFolderId,
    bool clearCurrentFolder = false,
  }) =>
      LibraryState(
        folders: folders ?? this.folders,
        notes: notes ?? this.notes,
        currentFolderId:
            clearCurrentFolder ? null : (currentFolderId ?? this.currentFolderId),
      );
}

class LibraryController extends AsyncNotifier<LibraryState> {
  StreamSubscription<void>? _libraryChangedSub;

  @override
  Future<LibraryState> build() async {
    final repo = ref.watch(repositoryProvider);
    final folders = await repo.listFolders();
    final notes = await repo.listNoteSummaries();
    // Refresh whenever another instance signals the library changed.
    _libraryChangedSub?.cancel();
    final lockService = ref.read(noteLockServiceProvider);
    _libraryChangedSub = lockService.libraryChanged.listen((_) {
      debugPrint('[Library] external change detected → refresh()');
      refresh();
    });
    ref.onDispose(() {
      _libraryChangedSub?.cancel();
      _libraryChangedSub = null;
    });
    return LibraryState(
      folders: folders,
      notes: notes,
      currentFolderId: null,
    );
  }

  Future<void> refresh() async {
    final repo = ref.read(repositoryProvider);
    final folders = await repo.listFolders();
    final notes = await repo.listNoteSummaries();
    final cur = state.value;
    state = AsyncData(LibraryState(
      folders: folders,
      notes: notes,
      currentFolderId: cur?.currentFolderId,
    ));
  }

  /// Refresh local library state, then broadcast so other instances refresh.
  /// Also kicks off a server sync so create/delete/rename/move/duplicate
  /// land on the server (and other devices) immediately rather than waiting
  /// for the 30-second background poll.
  Future<void> _refreshAndBroadcast() async {
    await refresh();
    ref.read(noteLockServiceProvider).broadcastLibraryChanged();
    // Fire-and-forget sync. CloudSyncNotifier.syncAll guards re-entry, so
    // calling this many times in quick succession is safe.
    // ignore: unawaited_futures
    ref.read(cloudSyncProvider.notifier).syncAll();
  }

  void navigateInto(String folderId) {
    final cur = state.value;
    if (cur == null) return;
    state = AsyncData(cur.copyWith(currentFolderId: folderId));
  }

  void navigateUp() {
    final cur = state.value;
    if (cur == null) return;
    final parent =
        cur.folders.where((f) => f.id == cur.currentFolderId).cast<Folder?>().firstOrNull?.parentId;
    state = AsyncData(cur.copyWith(
      currentFolderId: parent,
      clearCurrentFolder: parent == null,
    ));
  }

  void navigateRoot() {
    final cur = state.value;
    if (cur == null) return;
    state = AsyncData(cur.copyWith(clearCurrentFolder: true));
  }

  Future<Folder> createFolder(String name) async {
    final cur = state.value;
    if (cur == null) throw StateError('library not loaded');
    final f = Folder(
      id: newId(),
      parentId: cur.currentFolderId,
      name: name.isEmpty ? 'New folder' : name,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    );
    await ref.read(repositoryProvider).upsertFolder(f);
    state = AsyncData(cur.copyWith(folders: [...cur.folders, f]));
    ref.read(noteLockServiceProvider).broadcastLibraryChanged();
    return f;
  }

  Future<void> renameFolder(String folderId, String name) async {
    final cur = state.value;
    if (cur == null) return;
    final list = cur.folders.map((f) {
      if (f.id != folderId) return f;
      return f.copyWith(
        name: name,
        updatedAt: DateTime.now().toUtc(),
        rev: f.rev + 1,
      );
    }).toList();
    final updated = list.firstWhere((f) => f.id == folderId);
    await ref.read(repositoryProvider).upsertFolder(updated);
    state = AsyncData(cur.copyWith(folders: list));
    ref.read(noteLockServiceProvider).broadcastLibraryChanged();
  }

  Future<void> deleteFolder(String folderId) async {
    final deletedNoteIds =
        await ref.read(repositoryProvider).deleteFolder(folderId);
    final sync = ref.read(syncActionsProvider);
    for (final id in deletedNoteIds) {
      // Best-effort: queue tombstone, retry on next sync if offline.
      // ignore: unawaited_futures
      sync.queueDeleteNote(id);
    }
    await _refreshAndBroadcast();
  }

  Future<void> updateFolderAppearance(
      String folderId, int colorArgb, String iconKey) async {
    await ref.read(repositoryProvider).updateFolderAppearance(folderId, colorArgb, iconKey);
    await _refreshAndBroadcast();
  }

  /// Returns the new note id. Caller can drop it into [currentNoteIdProvider]
  /// to open the editor.
  Future<String> createNotebook({String title = 'Untitled'}) async {
    final cur = state.value;
    if (cur == null) throw StateError('library not loaded');
    final fresh = bootstrapNotebook(
      title: title,
      folderId: cur.currentFolderId,
    );
    await ref.read(repositoryProvider).saveAll(fresh);
    await _refreshAndBroadcast();
    return fresh.note.id;
  }

  /// Creates a notebook whose pages are given by [specs] (e.g. from a PDF
  /// import). Returns the new note's id.
  Future<String> createNotebookFromPages(
    List<PageSpec> specs, {
    String title = 'Untitled',
  }) async {
    final cur = state.value;
    if (cur == null) throw StateError('library not loaded');
    final now = DateTime.now().toUtc();
    final noteId = newId();

    final pages = <NotePage>[];
    final layersByPage = <String, List<Layer>>{};
    final strokesByPage = <String, List<Stroke>>{};
    final shapesByPage = <String, List<ShapeObject>>{};
    final textsByPage = <String, List<TextBoxObject>>{};
    final activeLayerByPage = <String, String>{};

    for (int i = 0; i < specs.length; i++) {
      final pageId = newId();
      final layerId = newId();
      pages.add(NotePage(
        id: pageId,
        noteId: noteId,
        index: i,
        spec: specs[i],
        updatedAt: now,
      ));
      layersByPage[pageId] = [
        Layer(id: layerId, pageId: pageId, z: 0, name: 'Default'),
      ];
      strokesByPage[pageId] = const [];
      shapesByPage[pageId] = const [];
      textsByPage[pageId] = const [];
      activeLayerByPage[pageId] = layerId;
    }

    final fresh = NotebookState(
      note: Note(
        id: noteId,
        ownerId: 'local-user',
        title: title,
        scrollAxis: ScrollAxis.vertical,
        defaultPageSpec: specs.isNotEmpty ? specs.first : PageSpec.a4Blank(),
        createdAt: now,
        updatedAt: now,
        folderId: cur.currentFolderId,
      ),
      pages: pages,
      layersByPage: layersByPage,
      strokesByPage: strokesByPage,
      shapesByPage: shapesByPage,
      textsByPage: textsByPage,
      activeLayerByPage: activeLayerByPage,
    );

    await ref.read(repositoryProvider).saveAll(fresh);
    await _refreshAndBroadcast();
    return noteId;
  }

  /// Persist a GoodNotes-imported notebook (pages already populated with
  /// strokes & text boxes). Returns the new note id.
  Future<String> createNotebookFromGoodNotes(ImportedGoodNotes imp) async {
    final cur = state.value;
    if (cur == null) throw StateError('library not loaded');
    final now = DateTime.now().toUtc();
    final noteId = imp.pages.isNotEmpty ? imp.pages.first.noteId : newId();

    final fresh = NotebookState(
      note: Note(
        id: noteId,
        ownerId: 'local-user',
        title: imp.title,
        scrollAxis: ScrollAxis.vertical,
        defaultPageSpec:
            imp.pages.isNotEmpty ? imp.pages.first.spec : PageSpec.a4Blank(),
        createdAt: now,
        updatedAt: now,
        folderId: cur.currentFolderId,
      ),
      pages: imp.pages,
      layersByPage: imp.layersByPage,
      strokesByPage: imp.strokesByPage,
      shapesByPage: {for (final p in imp.pages) p.id: const <ShapeObject>[]},
      textsByPage: imp.textsByPage,
      activeLayerByPage: imp.activeLayerByPage,
    );
    await ref.read(repositoryProvider).saveAll(fresh);
    await _refreshAndBroadcast();
    return noteId;
  }

  /// Persist a .notee-imported notebook. The note's folderId is updated to
  /// the currently-open folder so the import lands in the right place.
  Future<String> createNotebookFromNoteeState(NotebookState imported) async {
    final cur = state.value;
    if (cur == null) throw StateError('library not loaded');

    // Always create a brand-new document by remapping every ID so an existing
    // notebook with the same origin is never overwritten.
    final noteId = newId();

    // page old-id → new-id
    final pageIdMap = {for (final p in imported.pages) p.id: newId()};

    // layer old-id → new-id (across all pages)
    final layerIdMap = <String, String>{};
    for (final layers in imported.layersByPage.values) {
      for (final l in layers) {
        layerIdMap[l.id] = newId();
      }
    }

    final pages = imported.pages.map((p) {
      return p.copyWith(id: pageIdMap[p.id]!, noteId: noteId);
    }).toList();

    Map<String, List<T>> remapPage<T>(
      Map<String, List<T>> src,
      T Function(T, String newPageId) remap,
    ) {
      return {
        for (final e in src.entries)
          if (pageIdMap.containsKey(e.key))
            pageIdMap[e.key]!: e.value.map((x) => remap(x, pageIdMap[e.key]!)).toList(),
      };
    }

    final layersByPage = remapPage(
      imported.layersByPage,
      (l, pid) => l.copyWith(
        id: layerIdMap[l.id] ?? newId(),
        pageId: pid,
      ),
    );

    final strokesByPage = remapPage(
      imported.strokesByPage,
      (s, pid) => s.copyWith(
        id: newId(),
        pageId: pid,
        layerId: layerIdMap[s.layerId] ?? s.layerId,
      ),
    );

    final shapesByPage = remapPage(
      imported.shapesByPage,
      (s, pid) => s.copyWith(
        id: newId(),
        pageId: pid,
        layerId: layerIdMap[s.layerId] ?? s.layerId,
      ),
    );

    final textsByPage = remapPage(
      imported.textsByPage,
      (t, pid) => t.copyWith(
        id: newId(),
        pageId: pid,
        layerId: layerIdMap[t.layerId] ?? t.layerId,
      ),
    );

    final activeLayerByPage = {
      for (final e in imported.activeLayerByPage.entries)
        if (pageIdMap.containsKey(e.key))
          pageIdMap[e.key]!: layerIdMap[e.value] ?? e.value,
    };

    final note = imported.note.copyWith(
      id: noteId,
      folderId: cur.currentFolderId,
    );

    final fresh = NotebookState(
      note: note,
      pages: pages,
      layersByPage: layersByPage,
      strokesByPage: strokesByPage,
      shapesByPage: shapesByPage,
      textsByPage: textsByPage,
      activeLayerByPage: activeLayerByPage,
    );

    await ref.read(repositoryProvider).saveAll(fresh);
    await _refreshAndBroadcast();
    return noteId;
  }

  Future<void> deleteNotebook(String noteId) async {
    await ref.read(repositoryProvider).deleteNote(noteId);
    // ignore: unawaited_futures
    ref.read(syncActionsProvider).queueDeleteNote(noteId);
    await _refreshAndBroadcast();
  }

  Future<void> moveNotebook(String noteId, String? folderId) async {
    await ref.read(repositoryProvider).moveNoteToFolder(noteId, folderId);
    await _refreshAndBroadcast();
  }

  Future<void> bulkDelete(Set<String> ids) async {
    final repo = ref.read(repositoryProvider);
    final sync = ref.read(syncActionsProvider);
    for (final id in ids) {
      await repo.deleteNote(id);
      // ignore: unawaited_futures
      sync.queueDeleteNote(id);
    }
    await _refreshAndBroadcast();
  }

  Future<void> bulkMove(Set<String> ids, String? folderId) async {
    final repo = ref.read(repositoryProvider);
    for (final id in ids) {
      await repo.moveNoteToFolder(id, folderId);
    }
    await _refreshAndBroadcast();
  }

  Future<void> moveFolder(String folderId, String? parentId) async {
    await ref.read(repositoryProvider).moveFolderTo(folderId, parentId);
    await _refreshAndBroadcast();
  }

  Future<void> bulkMoveItems(
      Set<String> noteIds, Set<String> folderIds, String? targetFolderId) async {
    final repo = ref.read(repositoryProvider);
    for (final id in noteIds) {
      await repo.moveNoteToFolder(id, targetFolderId);
    }
    for (final id in folderIds) {
      await repo.moveFolderTo(id, targetFolderId);
    }
    await _refreshAndBroadcast();
  }

  Future<void> bulkDuplicate(Set<String> noteIds) async {
    final repo = ref.read(repositoryProvider);
    for (final id in noteIds) {
      await repo.duplicateNote(id);
    }
    await _refreshAndBroadcast();
  }

  Future<void> renameNotebook(String noteId, String title) async {
    await ref.read(repositoryProvider).updateNoteTitle(noteId, title);
    await _refreshAndBroadcast();
  }

  Future<String> duplicateNotebook(String noteId) async {
    final newId =
        await ref.read(repositoryProvider).duplicateNote(noteId);
    await _refreshAndBroadcast();
    return newId;
  }

  Future<void> toggleFavorite(String noteId) async {
    final cur = state.value;
    if (cur == null) return;
    final note = cur.notes.where((n) => n.id == noteId).cast<NoteSummary?>().firstOrNull;
    if (note == null) return;
    final newVal = !note.isFavorite;
    await ref.read(repositoryProvider).toggleFavorite(noteId, value: newVal);
    // Optimistic update — flip the flag in memory, then do a lightweight
    // state update without a full DB refresh.
    final updated = cur.notes.map((n) {
      if (n.id != noteId) return n;
      return NoteSummary(
        id: n.id,
        title: n.title,
        folderId: n.folderId,
        createdAt: n.createdAt,
        updatedAt: n.updatedAt,
        pageCount: n.pageCount,
        firstPageSpec: n.firstPageSpec,
        firstPageStrokes: n.firstPageStrokes,
        isFavorite: newVal,
      );
    }).toList();
    state = AsyncData(cur.copyWith(notes: updated));
    ref.read(noteLockServiceProvider).broadcastLibraryChanged();
  }
}

final libraryProvider =
    AsyncNotifierProvider<LibraryController, LibraryState>(
        LibraryController.new);

extension _IterableX<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
