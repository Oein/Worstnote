// One-shot sync actions: push the entire current notebook state, pull deltas
// back. The MVP doesn't keep an explicit outbox — every push sends the
// current state of every object, leveraging server-side LWW. P10 will add
// proper delta tracking via a drift outbox table.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/api_client.dart';
import '../../data/db/repository.dart';
import '../../domain/page_object.dart';
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

  Future<SyncResult> syncNow() async {
    final auth = ref.read(authProvider).value;
    if (auth == null || auth.tokens == null) {
      throw StateError('Not logged in');
    }
    final api = apiFor(auth);
    final notebook = ref.read(notebookProvider);
    final pushed = await _push(api, notebook);
    final pulled = await _pull(api, notebook);
    return SyncResult(
      pushed: pushed.pushed,
      pulled: pulled.pulled,
      cursor: pulled.cursor,
    );
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
    return (pushed: changes.length);
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
      ApiClient api, NotebookState s) async {
    final r = await api.syncPull(s.note.id, 0);
    final changes = (r['changes'] as List?) ?? const [];
    return (pulled: changes.length, cursor: (r['cursor'] as num?)?.toInt() ?? 0);
  }

  // Pushes every local note to the server, then pulls any server notes missing
  // locally. [onProgress] is called after each note with (current, total).
  Future<({int pushed, int notes})> syncAllNotes({
    void Function(int current, int total)? onProgress,
  }) async {
    final auth = ref.read(authProvider).value;
    if (auth == null || !auth.isLoggedIn) return (pushed: 0, notes: 0);
    final api = apiFor(auth);
    final repo = ref.read(repositoryProvider);

    final summaries = await repo.listNoteSummaries();
    final localIds = summaries.map((s) => s.id).toSet();

    // Fetch server list upfront so we know the true total.
    List<Map<String, dynamic>> serverNotes = const [];
    try { serverNotes = await api.listNotes(); } catch (_) {}
    final serverOnlyIds = serverNotes
        .map((s) => s['id'] as String)
        .where((id) => !localIds.contains(id))
        .toList();

    final total = summaries.length + serverOnlyIds.length;
    int current = 0;
    int pushed = 0;
    int notes = 0;

    // ── Push local notes ──────────────────────────────────────────────
    for (final s in summaries) {
      current++;
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
      onProgress?.call(current, total);
      try {
        final pullData = await api.syncPull(id, 0);
        await repo.applyServerPull(pullData,
            ownerId: auth.tokens?.userId ?? '');
        notes++;
      } catch (_) {}
    }

    return (pushed: pushed, notes: notes);
  }
}

final syncActionsProvider = Provider<SyncActions>(SyncActions.new);
