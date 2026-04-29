// One-shot sync actions: push the entire current notebook state, pull deltas
// back. The MVP doesn't keep an explicit outbox — every push sends the
// current state of every object, leveraging server-side LWW. P10 will add
// proper delta tracking via a drift outbox table.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/api_client.dart';
import '../../data/db/repository.dart';
import '../../domain/page_object.dart';
import '../../domain/page_spec.dart';
import '../import/asset_service.dart';
import '../auth/auth_state.dart';
import '../notebook/notebook_state.dart';

class SyncResult {
  SyncResult({
    required this.pushed,
    required this.pulled,
    required this.cursor,
  });
  final int pushed;
  final int pulled;
  final int cursor;
}

class SyncActions {
  SyncActions(this.ref);
  final Ref ref;

  // Tracks last server cursor per noteId for incremental pulls.
  final Map<String, int> _pullCursors = {};

  Future<SyncResult> syncNow({int? since}) async {
    final auth = ref.read(authProvider).value;
    if (auth == null || auth.tokens == null) {
      throw StateError('Not logged in');
    }
    final api = apiFor(auth);
    final notebook = ref.read(notebookProvider);
    final pushed = await _push(api, notebook);
    final effectiveSince = since ?? _pullCursors[notebook.note.id] ?? 0;
    final pulled = await _pull(api, notebook, since: effectiveSince);
    _pullCursors[notebook.note.id] = pulled.cursor;
    return SyncResult(
      pushed: pushed.pushed,
      pulled: pulled.pulled,
      cursor: pulled.cursor,
    );
  }

  /// Silently push a single note by id. Does nothing if not logged in.
  Future<void> pushNote(String noteId) async {
    final auth = ref.read(authProvider).value;
    if (auth == null || !auth.isLoggedIn) return;
    final api = apiFor(auth);
    final repo = ref.read(repositoryProvider);
    final state = await repo.loadByNoteId(noteId);
    if (state == null) return;
    try {
      await _push(api, state);
    } catch (e) {
      debugPrint('[Sync] background push error for $noteId: $e');
    }
  }

  Future<({int pushed})> _push(ApiClient api, NotebookState s) async {
    final changes = <Map<String, dynamic>>[];
    final now = DateTime.now().toUtc();
    final layersFlat = <Map<String, dynamic>>[];
    final pagesFlat = <Map<String, dynamic>>[];
    for (final p in s.pages) {
      pagesFlat.add({
        'id': p.id,
        'noteId': p.noteId,
        'index': p.index,
        'spec': p.spec.toJson(),
        'rev': p.rev,
        'updatedAt': p.updatedAt.toUtc().toIso8601String(),
        'deleted': false,
      });
      for (final l in s.layersByPage[p.id] ?? const []) {
        layersFlat.add({
          'id': l.id,
          'pageId': l.pageId,
          'z': l.z,
          'name': l.name,
          'visible': l.visible,
          'locked': l.locked,
          'opacity': l.opacity,
          'rev': l.rev,
          'deleted': false,
          'updatedAt': now.toIso8601String(),
        });
      }
      for (final st in s.strokesByPage[p.id] ?? const <Stroke>[]) {
        changes.add(_obj('stroke', st.id, st.pageId, st.layerId,
            st.toJson(), st.bbox, st.rev == 0 ? 1 : st.rev, st.deleted, now,
            api.deviceId));
      }
      for (final sh in s.shapesByPage[p.id] ?? const <ShapeObject>[]) {
        changes.add(_obj('shape', sh.id, sh.pageId, sh.layerId,
            sh.toJson(), sh.bbox, sh.rev == 0 ? 1 : sh.rev, sh.deleted, now,
            api.deviceId));
      }
      for (final tx in s.textsByPage[p.id] ?? const <TextBoxObject>[]) {
        changes.add(_obj('text', tx.id, tx.pageId, tx.layerId,
            tx.toJson(), tx.bbox, tx.rev == 0 ? 1 : tx.rev, tx.deleted, now,
            api.deviceId));
      }
    }
    final body = {
      'lastServerRev': 0,
      'note': {
        'id': s.note.id,
        'title': s.note.title,
        'scrollAxis': s.note.scrollAxis.name,
        'inputDrawMode': s.note.inputDrawMode.name,
        'defaultPageSpec': s.note.defaultPageSpec.toJson(),
        'rev': s.note.rev == 0 ? 1 : s.note.rev,
        'updatedAt': now.toIso8601String(),
      },
      'pages': pagesFlat,
      'layers': layersFlat,
      'changes': changes,
    };
    await api.syncPush(s.note.id, body);

    // Upload any PDF/image assets referenced by this note's pages.
    await _uploadAssets(api, s.pages.map((p) => p.spec).toList());

    return (pushed: changes.length);
  }

  Future<void> _uploadAssets(ApiClient api, List<PageSpec> specs) async {
    final assetService = AssetService();
    for (final spec in specs) {
      final bg = spec.background;
      String? assetId;
      if (bg is PdfBackground) assetId = bg.assetId;
      if (bg is ImageBackground) assetId = bg.assetId;
      if (assetId == null) continue;
      try {
        if (await api.assetExists(assetId)) continue;
        final file = await assetService.fileFor(assetId);
        if (file == null) continue;
        final bytes = await file.readAsBytes();
        await api.uploadAsset(assetId, bytes);
        debugPrint('[Sync] uploaded asset $assetId (${bytes.length} bytes)');
      } catch (e) {
        debugPrint('[Sync] asset upload error $assetId: $e');
      }
    }
  }

  Future<void> _downloadAssets(ApiClient api, List<dynamic> pagesJson) async {
    final assetService = AssetService();
    for (final p in pagesJson) {
      final pm = p as Map<String, dynamic>;
      final specJson = pm['spec'];
      if (specJson == null) continue;
      try {
        final spec = PageSpec.fromJson(
          (specJson is Map) ? Map<String, dynamic>.from(specJson) : <String, dynamic>{},
        );
        final bg = spec.background;
        String? assetId;
        if (bg is PdfBackground) assetId = bg.assetId;
        if (bg is ImageBackground) assetId = bg.assetId;
        if (assetId == null) continue;
        final existing = await assetService.fileFor(assetId);
        if (existing != null) continue;
        final bytes = await api.downloadAsset(assetId);
        if (bytes == null) continue;
        await assetService.putBytes(bytes, mime: 'application/octet-stream');
        debugPrint('[Sync] downloaded asset $assetId (${bytes.length} bytes)');
      } catch (e) {
        debugPrint('[Sync] asset download error: $e');
      }
    }
  }

  Map<String, dynamic> _obj(
    String kind,
    String id,
    String pageId,
    String layerId,
    Map<String, dynamic> data,
    Bbox bbox,
    int rev,
    bool deleted,
    DateTime now,
    String deviceId,
  ) {
    return {
      'id': id,
      'pageId': pageId,
      'layerId': layerId,
      'kind': kind,
      'data': data,
      'bbox': [bbox.minX, bbox.minY, bbox.maxX, bbox.maxY],
      'rev': rev,
      'deleted': deleted,
      'updatedAt': now.toIso8601String(),
      'deviceId': deviceId,
    };
  }

  Future<({int pulled, int cursor})> _pull(
      ApiClient api, NotebookState s, {int since = 0}) async {
    final r = await api.syncPull(s.note.id, since);
    final changes = (r['changes'] as List?) ?? const [];
    return (pulled: changes.length, cursor: (r['cursor'] as num?)?.toInt() ?? since);
  }

  // Pushes every local note to the server, then pulls any server notes missing
  // locally. [onProgress] is called after each note with (current, total).
  Future<({int pushed, int notes})> syncAllNotes({
    void Function(int current, int total)? onProgress,
    void Function(String? noteId)? onNoteId,
  }) async {
    final auth = ref.read(authProvider).value;
    if (auth == null || !auth.isLoggedIn) return (pushed: 0, notes: 0);
    final api = apiFor(auth);
    final repo = ref.read(repositoryProvider);

    final summaries = await repo.listNoteSummaries();
    final localIds = summaries.map((s) => s.id).toSet();

    debugPrint('[Sync] local notes: ${summaries.length}');

    // Fetch server list upfront so we know the true total.
    List<Map<String, dynamic>> serverNotes = const [];
    try {
      serverNotes = await api.listNotes();
      debugPrint('[Sync] server notes: ${serverNotes.length}');
    } catch (e) {
      debugPrint('[Sync] listNotes error: $e');
    }
    final serverOnlyIds = serverNotes
        .map((s) => s['id'] as String)
        .where((id) => !localIds.contains(id))
        .toList();
    debugPrint('[Sync] server-only ids to pull: ${serverOnlyIds.length} → $serverOnlyIds');

    final total = summaries.length + serverOnlyIds.length;
    int current = 0;
    int pushed = 0;
    int notes = 0;

    // ── Push local notes ──────────────────────────────────────────────
    for (final s in summaries) {
      current++;
      onNoteId?.call(s.id);
      onProgress?.call(current, total);
      final state = await repo.loadByNoteId(s.id);
      if (state == null) continue;
      try {
        final r = await _push(api, state);
        pushed += r.pushed;
        notes++;
      } catch (_) {}
    }

    // ── Pull server-only notes ────────────────────────────────────────
    for (final id in serverOnlyIds) {
      current++;
      onNoteId?.call(id);
      onProgress?.call(current, total);
      try {
        debugPrint('[Sync] pulling $id');
        final pullData = await api.syncPull(id, 0);
        debugPrint('[Sync] pull ok, note=${pullData['note'] != null}, pages=${(pullData['pages'] as List?)?.length}, changes=${(pullData['changes'] as List?)?.length}');
        await repo.applyServerPull(pullData,
            ownerId: auth.tokens?.userId ?? '');
        debugPrint('[Sync] applyServerPull ok for $id');
        // Download PDF/image assets for pulled note's pages.
        final pages = pullData['pages'] as List? ?? const [];
        await _downloadAssets(api, pages);
        notes++;
      } catch (e, st) {
        debugPrint('[Sync] pull/apply error for $id: $e\n$st');
      }
    }

    return (pushed: pushed, notes: notes);
  }
}

final syncActionsProvider = Provider<SyncActions>(SyncActions.new);
