// One-shot sync actions: push the entire current notebook state, pull deltas
// back. The MVP doesn't keep an explicit outbox — every push sends the
// current state of every object, leveraging server-side LWW. P10 will add
// proper delta tracking via a drift outbox table.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../data/api/api_client.dart';
import '../../domain/page_object.dart';
import '../../domain/page_spec.dart';
import '../import/asset_service.dart';
import '../library/thumbnail_service.dart';
import '../auth/auth_state.dart';
import '../notebook/notebook_state.dart';

// Sentinel for crash/multi-window coordination.
//   noteIds       — set of note IDs whose assets are still pending.
//   ownerId       — sessionId of the window currently draining the queue
//                   (null means up for grabs).
//   lastHeartbeat — owner's last write; ownership goes stale after
//                   [ownerStaleAfter] elapses.
class _PendingFile {
  _PendingFile({required this.noteIds, this.ownerId, this.lastHeartbeat});
  final Set<String> noteIds;
  final String? ownerId;
  final DateTime? lastHeartbeat;

  static const ownerStaleAfter = Duration(seconds: 10);

  bool get hasLiveOwner =>
      ownerId != null &&
      lastHeartbeat != null &&
      DateTime.now().difference(lastHeartbeat!) < ownerStaleAfter;

  Map<String, dynamic> toJson() => {
        'noteIds': noteIds.toList(),
        if (ownerId != null) 'ownerId': ownerId,
        if (lastHeartbeat != null)
          'lastHeartbeat': lastHeartbeat!.toIso8601String(),
      };

  static _PendingFile fromJson(Map<String, dynamic> j) => _PendingFile(
        noteIds: ((j['noteIds'] as List?)?.cast<String>().toSet()) ?? {},
        ownerId: j['ownerId'] as String?,
        lastHeartbeat: j['lastHeartbeat'] != null
            ? DateTime.tryParse(j['lastHeartbeat'] as String)
            : null,
      );
}

// Disk-backed store of "notes whose assets are still pending". Shared across
// multiple app instances (separate Flutter windows). A 2-second poll picks
// up other windows' changes; an ownership heartbeat lets surviving windows
// resume a sync if the owner crashes.
class _PendingAssetsStore {
  _PendingAssetsStore._();
  static final _PendingAssetsStore instance = _PendingAssetsStore._();

  Future<File> _file() async {
    final docs = await getApplicationDocumentsDirectory();
    return File(p.join(docs.path, 'notee-pending-assets.json'));
  }

  Future<_PendingFile> read() async {
    try {
      final f = await _file();
      if (!await f.exists()) return _PendingFile(noteIds: {});
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return _PendingFile(noteIds: {});
      return _PendingFile.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return _PendingFile(noteIds: {});
    }
  }

  Future<void> _writeRaw(_PendingFile s) async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode(s.toJson()), flush: true);
    } catch (_) {}
  }

  // All mutations are read-modify-write so a window that's only changing
  // [noteIds] doesn't clobber another window's owner/heartbeat field, and
  // vice versa.
  Future<void> addNote(String id) async {
    final cur = await read();
    if (cur.noteIds.contains(id)) return;
    await _writeRaw(_PendingFile(
      noteIds: {...cur.noteIds, id},
      ownerId: cur.ownerId,
      lastHeartbeat: cur.lastHeartbeat,
    ));
  }

  Future<void> removeNote(String id) async {
    final cur = await read();
    if (!cur.noteIds.contains(id)) return;
    final ns = {...cur.noteIds}..remove(id);
    await _writeRaw(_PendingFile(
      noteIds: ns,
      ownerId: cur.ownerId,
      lastHeartbeat: cur.lastHeartbeat,
    ));
  }

  Future<void> setOwner(String? ownerId) async {
    final cur = await read();
    await _writeRaw(_PendingFile(
      noteIds: cur.noteIds,
      ownerId: ownerId,
      lastHeartbeat: ownerId != null ? DateTime.now() : null,
    ));
  }

  Future<void> heartbeat(String ownerId) async {
    final cur = await read();
    if (cur.ownerId != ownerId) return; // someone else took over
    await _writeRaw(_PendingFile(
      noteIds: cur.noteIds,
      ownerId: ownerId,
      lastHeartbeat: DateTime.now(),
    ));
  }
}

// Tracks notes whose DB rows are pulled but whose binary assets (PDF/image
// originals) have not all been downloaded yet. State is mirrored to disk so
// that:
//   1. Multiple windows see the same syncing set.
//   2. A crash mid-sync leaves the indicator visible on next launch.
//   3. If the window doing the work dies, another window detects the stale
//      ownership heartbeat and continues the drain.
class PendingAssetNotesNotifier extends Notifier<Set<String>> {
  Timer? _poller;

  @override
  Set<String> build() {
    _bootstrap();
    ref.onDispose(() => _poller?.cancel());
    return {};
  }

  Future<void> _bootstrap() async {
    await _refresh();
    _poller ??= Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  Future<void> _refresh() async {
    final cur = await _PendingAssetsStore.instance.read();
    if (!_eq(cur.noteIds, state)) state = cur.noteIds;
    // Failover: if there's pending work and the previous owner is dead,
    // try to take over (only if this window isn't already draining).
    if (cur.noteIds.isNotEmpty && !cur.hasLiveOwner) {
      // Fire-and-forget — resumeAssetDownloads itself guards against
      // double-driving the queue.
      // ignore: unawaited_futures
      ref.read(syncActionsProvider).resumeAssetDownloads();
    }
  }

  bool _eq(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  Future<void> add(String id) async {
    if (state.contains(id)) {
      await _PendingAssetsStore.instance.addNote(id);
      return;
    }
    state = {...state, id};
    await _PendingAssetsStore.instance.addNote(id);
  }

  Future<void> remove(String id) async {
    if (state.contains(id)) {
      state = {...state}..remove(id);
    }
    await _PendingAssetsStore.instance.removeNote(id);
  }
}

final pendingAssetNotesProvider =
    NotifierProvider<PendingAssetNotesNotifier, Set<String>>(
        PendingAssetNotesNotifier.new);

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

  // Asset-download queue: noteId → page JSON list still to process.
  // Populated after Phase A (DB pull) and drained in Phase B in priority order.
  final Map<String, List<dynamic>> _assetQueue = {};
  // When set, the queue picks this note next (used for "open during sync").
  String? _priorityNoteId;
  // Callers awaiting a specific note's assets to be ready.
  final Map<String, List<Completer<void>>> _waiters = {};

  // Process-unique session ID for cross-window ownership coordination.
  late final String _sessionId =
      '${DateTime.now().microsecondsSinceEpoch}-${math.Random().nextInt(1 << 32)}';

  /// Bumps [noteId]'s assets to the front of the queue and returns a Future
  /// that completes once that note's assets are fully on-disk. Resolves
  /// immediately if the note has no pending assets.
  Future<void> prioritizeNoteAssets(String noteId) async {
    // If pending state says the note still needs assets but our queue is
    // empty (e.g. another window started the sync, or we just relaunched),
    // load the note's pages from local DB and queue its assets first.
    if (!_assetQueue.containsKey(noteId)) {
      final pending = ref.read(pendingAssetNotesProvider);
      if (pending.contains(noteId)) {
        await resumeAssetDownloads();
      }
    }
    if (!_assetQueue.containsKey(noteId)) return;
    _priorityNoteId = noteId;
    final c = Completer<void>();
    _waiters.putIfAbsent(noteId, () => []).add(c);
    debugPrint('[Sync] prioritize $noteId (queue=${_assetQueue.keys.toList()})');
    return c.future;
  }

  // Whether a phase-B drain is currently running. Prevents double-driving
  // the queue when multiple resume calls land in quick succession.
  bool _draining = false;

  /// On startup, re-enqueue assets for any notes the on-disk pending file
  /// still lists. Loads each note's pages from local DB and queues their
  /// PDF/image assets for download. Safe to call multiple times.
  Future<void> resumeAssetDownloads() async {
    final pending = ref.read(pendingAssetNotesProvider);
    if (pending.isEmpty) return;
    final auth = ref.read(authProvider).value;
    if (auth == null || !auth.isLoggedIn) return;
    final api = apiFor(auth);
    final repo = ref.read(repositoryProvider);
    final notifier = ref.read(pendingAssetNotesProvider.notifier);

    for (final noteId in pending) {
      // Already in queue from this session — skip.
      if (_assetQueue.containsKey(noteId)) continue;
      final state = await repo.loadByNoteId(noteId);
      if (state == null) {
        // Note no longer exists locally — drop from pending.
        notifier.remove(noteId);
        continue;
      }
      final pagesJson = <Map<String, dynamic>>[
        for (final page in state.pages)
          {'spec': page.spec.toJson()},
      ];
      _assetQueue[noteId] = pagesJson;
      debugPrint('[Sync] resuming asset download for $noteId');
    }
    if (_assetQueue.isNotEmpty && !_draining) {
      // Drive the queue without progress callbacks (silent background drain).
      _drainAssetQueue(api: api, notifier: notifier);
    }
  }

  Future<void> _drainAssetQueue({
    required ApiClient api,
    required PendingAssetNotesNotifier notifier,
    void Function(String noteId)? onNoteAssetsReady,
    void Function(int current, int total)? onProgress,
    void Function(String? noteId)? onNoteId,
    int currentBase = 0,
    int total = 0,
  }) async {
    if (_draining) return;

    // Claim ownership for cross-window coordination. If another live owner
    // exists, defer to it.
    final cur = await _PendingAssetsStore.instance.read();
    if (cur.hasLiveOwner && cur.ownerId != _sessionId) {
      debugPrint('[Sync] another window ($cur.ownerId) owns the drain — skipping');
      return;
    }
    await _PendingAssetsStore.instance.setOwner(_sessionId);

    _draining = true;
    Timer? heartbeat = Timer.periodic(const Duration(seconds: 3), (_) {
      _PendingAssetsStore.instance.heartbeat(_sessionId);
    });

    int current = currentBase;
    try {
      while (_assetQueue.isNotEmpty) {
        final pickId = (_priorityNoteId != null &&
                _assetQueue.containsKey(_priorityNoteId))
            ? _priorityNoteId!
            : _assetQueue.keys.first;
        final pages = _assetQueue.remove(pickId)!;
        if (_priorityNoteId == pickId) _priorityNoteId = null;
        current++;
        onNoteId?.call(pickId);
        if (total > 0) onProgress?.call(current, total);
        debugPrint('[Sync] downloading assets for $pickId');
        try {
          await _downloadAssets(api, pages);
        } catch (e) {
          debugPrint('[Sync] asset phase error for $pickId: $e');
        }
        try {
          await ThumbnailService.instance.invalidate(pickId);
        } catch (_) {}
        await notifier.remove(pickId);
        _completeWaiters(pickId);
        onNoteAssetsReady?.call(pickId);
      }
    } finally {
      heartbeat.cancel();
      heartbeat = null;
      _draining = false;
      // Release ownership only if we still hold it.
      final after = await _PendingAssetsStore.instance.read();
      if (after.ownerId == _sessionId) {
        await _PendingAssetsStore.instance.setOwner(null);
      }
    }
  }

  void _completeWaiters(String noteId) {
    final list = _waiters.remove(noteId);
    if (list == null) return;
    for (final c in list) {
      if (!c.isCompleted) c.complete();
    }
  }

  Future<SyncResult> syncNow({int? since}) async {
    debugPrint('[Sync] syncNow called');
    final auth = ref.read(authProvider).value;
    if (auth == null || auth.tokens == null) {
      debugPrint('[Sync] syncNow: not logged in');
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

  /// Locally-deleted notes that still need to be propagated to the server.
  /// Persisted to disk so a delete made offline survives an app restart.
  Future<File> _tombstonesFile() async {
    final docs = await getApplicationDocumentsDirectory();
    return File(p.join(docs.path, 'notee-pending-deletes.json'));
  }

  Future<Set<String>> _loadTombstones() async {
    try {
      final f = await _tombstonesFile();
      if (!await f.exists()) return {};
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return {};
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return ((j['noteIds'] as List?)?.cast<String>().toSet()) ?? {};
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveTombstones(Set<String> ids) async {
    try {
      final f = await _tombstonesFile();
      await f.writeAsString(jsonEncode({'noteIds': ids.toList()}), flush: true);
    } catch (_) {}
  }

  /// Records that [noteId] was deleted locally and tries to delete it on the
  /// server right away. If the API call fails (offline, 5xx, not logged in),
  /// the id stays in the tombstone file and is retried on the next sync.
  Future<void> queueDeleteNote(String noteId) async {
    final cur = await _loadTombstones();
    if (!cur.contains(noteId)) {
      await _saveTombstones({...cur, noteId});
    }
    await _drainTombstones();
  }

  /// Best-effort: walks the tombstone set and DELETEs each note on the
  /// server. Successful ids are removed from the file; failures stay queued.
  Future<void> _drainTombstones() async {
    final auth = ref.read(authProvider).value;
    if (auth == null || !auth.isLoggedIn) return;
    final api = apiFor(auth);
    final ids = await _loadTombstones();
    if (ids.isEmpty) return;
    final remaining = <String>{...ids};
    for (final id in ids) {
      try {
        await api.deleteNote(id);
        remaining.remove(id);
        debugPrint('[Sync] tombstone deleted on server: $id');
      } catch (e) {
        debugPrint('[Sync] tombstone delete failed for $id: $e (will retry)');
      }
    }
    if (remaining.length != ids.length) {
      await _saveTombstones(remaining);
    }
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
    debugPrint('[Sync] _push noteId=${s.note.id} pages=${s.pages.length}');
    for (final p in s.pages) {
      debugPrint('[Sync]   page ${p.id} bg=${p.spec.background.runtimeType}');
    }
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
    // Deduplicate: many pages may share the same PDF/image asset.
    final seen = <String>{};
    for (final spec in specs) {
      final bg = spec.background;
      String? assetId;
      if (bg is PdfBackground) assetId = bg.assetId;
      if (bg is ImageBackground) assetId = bg.assetId;
      if (assetId == null || assetId.isEmpty || !seen.add(assetId)) continue;
      try {
        if (await api.assetExists(assetId)) continue;
        final file = await assetService.fileFor(assetId);
        if (file == null) {
          debugPrint('[Sync] asset $assetId not found locally, skipping');
          continue;
        }
        final sizeMb = (await file.length()) / 1024 / 1024;
        debugPrint('[Sync] uploading asset $assetId (${sizeMb.toStringAsFixed(1)} MB)');
        await api.uploadAsset(assetId, file);
        debugPrint('[Sync] uploaded asset $assetId ok');
      } catch (e) {
        debugPrint('[Sync] asset upload error $assetId: $e');
      }
    }
  }

  Future<void> _downloadAssets(ApiClient api, List<dynamic> pagesJson) async {
    final assetService = AssetService();
    final seen = <String>{};
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
        if (assetId == null || assetId.isEmpty || !seen.add(assetId)) continue;
        final existing = await assetService.fileFor(assetId);
        if (existing != null) continue;
        final savePath = await assetService.assetPath(assetId);
        debugPrint('[Sync] downloading asset $assetId');
        final ok = await api.downloadAssetToFile(assetId, savePath);
        if (!ok) {
          debugPrint('[Sync] asset download failed $assetId');
          continue;
        }
        debugPrint('[Sync] downloaded asset $assetId ok');
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
    void Function()? onNotePulled,
    void Function(String noteId)? onNoteAssetsReady,
  }) async {
    final auth = ref.read(authProvider).value;
    if (auth == null || !auth.isLoggedIn) return (pushed: 0, notes: 0);
    final api = apiFor(auth);
    final repo = ref.read(repositoryProvider);
    final pending = ref.read(pendingAssetNotesProvider.notifier);

    // Drain any pending delete-tombstones first so server stays in sync
    // even if the original DELETE attempt was offline.
    await _drainTombstones();

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

    // Total counts: push step + pull DB step + per-note asset step.
    final total = summaries.length + serverOnlyIds.length * 2;
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

    // ── Phase A: pull all server-only DBs first ───────────────────────
    // Notes show up in the library immediately, but stay non-openable
    // (pendingAssetNotes) until their PDF/image originals land in Phase B.
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
        notes++;
        final pages = pullData['pages'] as List? ?? const [];
        _assetQueue[id] = pages;
        pending.add(id);
        onNotePulled?.call();
      } catch (e, st) {
        debugPrint('[Sync] pull/apply error for $id: $e\n$st');
      }
    }

    // ── Phase B: download assets, priority-aware ──────────────────────
    await _drainAssetQueue(
      api: api,
      notifier: pending,
      onNoteAssetsReady: onNoteAssetsReady,
      onProgress: onProgress,
      onNoteId: onNoteId,
      currentBase: current,
      total: total,
    );

    return (pushed: pushed, notes: notes);
  }
}

final syncActionsProvider = Provider<SyncActions>(SyncActions.new);
