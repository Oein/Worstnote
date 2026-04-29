// One-shot sync actions: push the entire current notebook state, pull deltas
// back. The MVP doesn't keep an explicit outbox — every push sends the
// current state of every object, leveraging server-side LWW. P10 will add
// proper delta tracking via a drift outbox table.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../data/api/api_client.dart';
import '../../domain/page_object.dart';
import '../../domain/page_spec.dart';
import '../import/asset_service.dart';
import '../import/pdf_render_cache.dart';
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

// Disk-backed store of "noteId → conflictSessionId" for conflicts that
// were detected by the server during a push and still need user resolution.
// Persisted so a closed app, a switched window, or a fresh launch all see
// the same set of unresolved conflicts.
class _PendingConflictsStore {
  _PendingConflictsStore._();
  static final _PendingConflictsStore instance = _PendingConflictsStore._();

  Future<File> _file() async {
    final docs = await getApplicationDocumentsDirectory();
    return File(p.join(docs.path, 'notee-pending-conflicts.json'));
  }

  Future<Map<String, String>> read() async {
    try {
      final f = await _file();
      if (!await f.exists()) return {};
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return {};
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return j.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeRaw(Map<String, String> m) async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode(m), flush: true);
    } catch (_) {}
  }

  Future<void> set(String noteId, String sid) async {
    final cur = await read();
    if (cur[noteId] == sid) return;
    cur[noteId] = sid;
    await _writeRaw(cur);
  }

  Future<void> clear(String noteId) async {
    final cur = await read();
    if (!cur.containsKey(noteId)) return;
    cur.remove(noteId);
    await _writeRaw(cur);
  }
}

class PendingConflictsNotifier extends Notifier<Map<String, String>> {
  Timer? _poller;

  @override
  Map<String, String> build() {
    _bootstrap();
    ref.onDispose(() => _poller?.cancel());
    return {};
  }

  Future<void> _bootstrap() async {
    await _refresh();
    _poller ??= Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  Future<void> _refresh() async {
    final cur = await _PendingConflictsStore.instance.read();
    if (!_eq(cur, state)) state = cur;
  }

  bool _eq(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  Future<void> register(String noteId, String sid) async {
    state = {...state, noteId: sid};
    await _PendingConflictsStore.instance.set(noteId, sid);
  }

  Future<void> clear(String noteId) async {
    if (!state.containsKey(noteId)) return;
    state = {...state}..remove(noteId);
    await _PendingConflictsStore.instance.clear(noteId);
  }
}

final pendingConflictsProvider =
    NotifierProvider<PendingConflictsNotifier, Map<String, String>>(
        PendingConflictsNotifier.new);

// Priority levels — same semantics as PdfRenderCache:
//   p0: user-requested (note being opened right now)
//   p1: current sync session (active push or pull)
//   p2: background / resume-from-crash
enum _AssetPriority { p0, p1, p2 }

enum _AssetDir { upload, download }

class _AssetJob {
  _AssetJob({
    required this.assetId,
    required this.noteId,
    required this.dir,
    required this.priority,
    this.localFile,    // upload only: source file resolved at enqueue
    this.savePath,     // download only: destination path
  });
  final String assetId;
  final String noteId;
  final _AssetDir dir;
  _AssetPriority priority;
  final File? localFile;
  final String? savePath;
}

class _NoteAssetState {
  _NoteAssetState({required this.pagesJson, required this.totalAssets});
  final List<dynamic> pagesJson; // for _enqueuePdfRenderJobs after note completes
  int totalAssets;
  int completedAssets = 0;
  bool allOk = true;
}

/// Read-only view of one asset *file* (PDF/image) being transferred or
/// queued — granularity is per-file, not per-note. Used by the queue
/// viewer modal so the user sees every individual file moving.
class AssetFileView {
  const AssetFileView({
    required this.assetId,
    required this.noteId,
    required this.direction, // 'upload' | 'download'
    required this.priority,  // 'P0' | 'P1' | 'P2' | 'running'
    this.bytesTransferred,   // null unless this file is in flight
    this.bytesTotal,
  });
  final String assetId;
  final String noteId;
  final String direction;
  final String priority;
  final int? bytesTransferred;
  final int? bytesTotal;

  /// 0.0–1.0 if total is known, else null (indeterminate).
  double? get progress {
    if (bytesTotal == null || bytesTotal! <= 0) return null;
    return (bytesTransferred ?? 0) / bytesTotal!;
  }
}

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
  // Loaded from disk on first use so it survives app restarts — prevents
  // the first push after restart from sending lastServerRev:0 and triggering
  // false conflicts for every object on the server.
  Map<String, int>? _pullCursors;

  Future<Map<String, int>> _loadedCursors() async {
    if (_pullCursors != null) return _pullCursors!;
    _pullCursors = await _loadCursors();
    return _pullCursors!;
  }

  Future<File> _cursorsFile() async {
    final docs = await getApplicationDocumentsDirectory();
    return File(p.join(docs.path, 'notee-sync-cursors.json'));
  }

  Future<Map<String, int>> _loadCursors() async {
    try {
      final f = await _cursorsFile();
      if (!await f.exists()) return {};
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return {};
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return j.map((k, v) => MapEntry(k, (v as num).toInt()));
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveCursor(String noteId, int cursor) async {
    final cursors = await _loadedCursors();
    cursors[noteId] = cursor;
    try {
      final f = await _cursorsFile();
      await f.writeAsString(jsonEncode(cursors));
    } catch (_) {}
  }

  /// Publicly expose cursor update so conflict resolution can advance the
  /// cursor to the server's resolved rev before the next push.
  Future<void> updateCursor(String noteId, int serverRev) =>
      _saveCursor(noteId, serverRev);

  // Unified asset transfer queue (uploads + downloads).
  // Priority: p0 (user-requested) > p1 (current session) > p2 (background).
  final List<_AssetJob> _jobQueue = [];
  // Per-note completion tracking for downloads (file-level queue).
  final Map<String, _NoteAssetState> _noteState = {};
  // Callers awaiting a specific note's assets (download only).
  final Map<String, List<Completer<void>>> _waiters = {};
  // Process-unique session ID for cross-window ownership coordination.
  late final String _sessionId =
      '${DateTime.now().microsecondsSinceEpoch}-${math.Random().nextInt(1 << 32)}';
  // Number of parallel transfer workers.
  static const int _maxWorkers = 3;
  // Per-file transfers currently in flight. Keyed by assetId so the same
  // asset can't appear twice (workers de-dupe via _seenInFlight).
  // Each entry = (assetId, noteId, direction).
  final Map<String, ({String noteId, _AssetDir dir})> _activeFiles = {};
  // Broadcast queue-state changes so the modal can repaint live.
  final StreamController<void> _changes = StreamController<void>.broadcast();
  Stream<void> get onChanged => _changes.stream;
  int get maxWorkers => _maxWorkers;

  // Bytes transferred so far / total bytes per active assetId. Updated by
  // Dio's onReceiveProgress / onSendProgress callbacks; throttled so we
  // don't fire _changes on every TCP chunk.
  final Map<String, ({int received, int total})> _activeProgress = {};
  // Last time we broadcast a progress tick (per asset) — keeps repaint cost
  // sane during a fast download.
  final Map<String, DateTime> _lastProgressBroadcast = {};

  void _setActiveFile(String assetId, String noteId, _AssetDir dir) {
    _activeFiles[assetId] = (noteId: noteId, dir: dir);
    _activeProgress[assetId] = (received: 0, total: 0);
    _changes.add(null);
  }

  void _clearActiveFile(String assetId) {
    _activeFiles.remove(assetId);
    _activeProgress.remove(assetId);
    _lastProgressBroadcast.remove(assetId);
    _changes.add(null);
  }

  void _updateProgress(String assetId, int received, int total) {
    _activeProgress[assetId] = (received: received, total: total);
    // Throttle: at most ~5 events/second per asset.
    final now = DateTime.now();
    final last = _lastProgressBroadcast[assetId];
    if (last == null || now.difference(last) > const Duration(milliseconds: 200)) {
      _lastProgressBroadcast[assetId] = now;
      _changes.add(null);
    }
  }

  void _enqueueJob(_AssetJob job) {
    final idx = _jobQueue.indexWhere(
        (j) => j.assetId == job.assetId && j.dir == job.dir);
    if (idx >= 0) {
      // Already queued — bump to higher priority if needed.
      if (job.priority.index < _jobQueue[idx].priority.index) {
        _jobQueue[idx].priority = job.priority;
        _changes.add(null);
      }
      return;
    }
    _jobQueue.add(job);
    _changes.add(null);
  }

  /// Expand a note's pull-data into per-file download jobs.
  /// Files already on disk are skipped. Returns false if no work was queued
  /// (e.g. all assets already present), in which case caller should fire
  /// onReady immediately.
  Future<bool> _enqueueDownloadFiles({
    required String noteId,
    required List<dynamic> pagesJson,
    required _AssetPriority priority,
  }) async {
    final assetService = AssetService();
    final assetIds = <String>{};
    for (final p in pagesJson) {
      try {
        final pm = p as Map<String, dynamic>;
        final specMap = _resolveSpec(pm['spec']);
        if (specMap == null) continue;
        final spec = PageSpec.fromJson(specMap);
        final bg = spec.background;
        String? id;
        if (bg is PdfBackground) id = bg.assetId;
        if (bg is ImageBackground) id = bg.assetId;
        if (id != null && id.isNotEmpty) assetIds.add(id);
      } catch (_) {}
    }
    // Skip files already on disk.
    final pending = <String>[];
    for (final id in assetIds) {
      if (await assetService.fileFor(id) == null) pending.add(id);
    }
    if (pending.isEmpty) return false;
    _noteState[noteId] = _NoteAssetState(
      pagesJson: pagesJson,
      totalAssets: pending.length,
    );
    for (final id in pending) {
      final savePath = await assetService.assetPath(id);
      _enqueueJob(_AssetJob(
        assetId: id,
        noteId: noteId,
        dir: _AssetDir.download,
        priority: priority,
        savePath: savePath,
      ));
    }
    return true;
  }

  Future<void> _enqueueUploadFiles({
    required String noteId,
    required List<PageSpec> specs,
    required _AssetPriority priority,
  }) async {
    final assetService = AssetService();
    final seen = <String>{};
    for (final spec in specs) {
      final bg = spec.background;
      String? id;
      if (bg is PdfBackground) id = bg.assetId;
      if (bg is ImageBackground) id = bg.assetId;
      if (id == null || id.isEmpty || !seen.add(id)) continue;
      final file = await assetService.fileFor(id);
      if (file == null) continue;
      _enqueueJob(_AssetJob(
        assetId: id,
        noteId: noteId,
        dir: _AssetDir.upload,
        priority: priority,
        localFile: file,
      ));
    }
  }

  /// Read-only snapshot of every file (PDF/image) the sync system is
  /// either transferring or has queued — flat list, not grouped by note.
  /// Files currently in flight don't appear in the priority sections;
  /// they live in [running] instead.
  ({
    List<AssetFileView> p0,
    List<AssetFileView> p1,
    List<AssetFileView> p2,
    List<AssetFileView> running,
    int maxWorkers,
  }) snapshot() {
    AssetFileView toView(_AssetJob j) => AssetFileView(
          assetId: j.assetId,
          noteId: j.noteId,
          direction: j.dir == _AssetDir.upload ? 'upload' : 'download',
          priority: j.priority == _AssetPriority.p0
              ? 'P0'
              : j.priority == _AssetPriority.p1
                  ? 'P1'
                  : 'P2',
        );
    final p0 = <AssetFileView>[];
    final p1 = <AssetFileView>[];
    final p2 = <AssetFileView>[];
    for (final j in _jobQueue) {
      final view = toView(j);
      switch (j.priority) {
        case _AssetPriority.p0: p0.add(view);
        case _AssetPriority.p1: p1.add(view);
        case _AssetPriority.p2: p2.add(view);
      }
    }
    final running = <AssetFileView>[];
    _activeFiles.forEach((assetId, meta) {
      final prog = _activeProgress[assetId];
      running.add(AssetFileView(
        assetId: assetId,
        noteId: meta.noteId,
        direction: meta.dir == _AssetDir.upload ? 'upload' : 'download',
        priority: 'running',
        bytesTransferred: prog?.received,
        bytesTotal: prog?.total,
      ));
    });
    return (p0: p0, p1: p1, p2: p2, running: running, maxWorkers: _maxWorkers);
  }

  _AssetJob? _pickNext() {
    if (_jobQueue.isEmpty) return null;
    final indices = List<int>.generate(_jobQueue.length, (i) => i);
    indices.sort((a, b) =>
        _jobQueue[a].priority.index.compareTo(_jobQueue[b].priority.index));
    for (final idx in indices) {
      if (!_activeFiles.containsKey(_jobQueue[idx].assetId)) {
        return _jobQueue.removeAt(idx);
      }
    }
    return null;
  }

  /// Bumps [noteId]'s download job to P0 and waits until its assets are
  /// fully on disk. Resolves immediately if the note has no pending assets.
  Future<void> prioritizeNoteAssets(String noteId) async {
    // Three states the note can be in:
    //   inQueue:  files for it are sitting in _jobQueue
    //   inFlight: a worker is mid-download (note in _noteState, files removed
    //             from _jobQueue by _pickNext)
    //   neither:  no work registered → try to enqueue from pending
    bool inQueue = _jobQueue.any(
        (j) => j.noteId == noteId && j.dir == _AssetDir.download);
    bool inFlight = _noteState.containsKey(noteId);

    if (!inQueue && !inFlight) {
      final pending = ref.read(pendingAssetNotesProvider);
      if (!pending.contains(noteId)) return; // genuinely nothing to wait for
      await resumeAssetDownloads();
      inQueue = _jobQueue.any(
          (j) => j.noteId == noteId && j.dir == _AssetDir.download);
      inFlight = _noteState.containsKey(noteId);
    }

    // After resume: if still nothing, every asset is on disk (resumeAssetDownloads
    // cleared pending) — the editor can open immediately.
    if (!inQueue && !inFlight) return;

    // Bump any *queued* jobs for this note to P0. Already-running jobs can't
    // be re-prioritised but they'll finish on their own.
    for (final j in _jobQueue) {
      if (j.noteId == noteId && j.dir == _AssetDir.download) {
        j.priority = _AssetPriority.p0;
      }
    }
    _changes.add(null);

    // Make sure a drain is actually running. If workers all exited
    // before this note was queued (idle pool, queue went empty briefly),
    // _draining is false and the freshly-enqueued P0 job would just sit.
    if (_jobQueue.isNotEmpty && !_draining) {
      final auth = ref.read(authProvider).value;
      if (auth != null && auth.isLoggedIn) {
        final api = apiFor(auth, onTokens: (t) { ref.read(authProvider.notifier).updateTokens(t); }, onLogout: () { ref.read(authProvider.notifier).clearTokens(); });
        final notifier = ref.read(pendingAssetNotesProvider.notifier);
        // ignore: unawaited_futures
        _drainJobQueue(api: api, notifier: notifier);
      }
    }

    final c = Completer<void>();
    _waiters.putIfAbsent(noteId, () => []).add(c);
    debugPrint('[Sync] prioritize $noteId → P0 (inQueue=$inQueue inFlight=$inFlight)');
    return c.future;
  }

  bool _draining = false;

  /// Re-enqueues assets for any notes the on-disk pending file still lists.
  /// Queued as P2 (background). Safe to call multiple times.
  Future<void> resumeAssetDownloads() async {
    final pending = ref.read(pendingAssetNotesProvider);
    if (pending.isEmpty) return;
    final auth = ref.read(authProvider).value;
    if (auth == null || !auth.isLoggedIn) return;
    final api = apiFor(auth, onTokens: (t) { ref.read(authProvider.notifier).updateTokens(t); }, onLogout: () { ref.read(authProvider.notifier).clearTokens(); });
    final repo = ref.read(repositoryProvider);
    final notifier = ref.read(pendingAssetNotesProvider.notifier);

    for (final noteId in pending) {
      if (_jobQueue.any(
          (j) => j.noteId == noteId && j.dir == _AssetDir.download)) continue;
      if (_noteState.containsKey(noteId)) continue;
      final state = await repo.loadByNoteId(noteId);
      if (state == null) {
        await notifier.remove(noteId);
        continue;
      }
      final pagesJson = <Map<String, dynamic>>[
        for (final page in state.pages) {'spec': page.spec.toJson()},
      ];
      final hasWork = await _enqueueDownloadFiles(
        noteId: noteId,
        pagesJson: pagesJson,
        priority: _AssetPriority.p2,
      );
      if (!hasWork) {
        // Every asset already on disk — note is complete. Clean up the
        // stale pending entry so the syncing overlay disappears and a
        // user-tap doesn't hang waiting for nothing.
        debugPrint('[Sync] $noteId: all assets already on disk, clearing pending');
        await notifier.remove(noteId);
        // Render queue may not have been seeded for this note — do it now.
        try { await _enqueuePdfRenderJobs(pagesJson); } catch (_) {}
        _completeWaiters(noteId);
      } else {
        debugPrint('[Sync] resume download $noteId (P2)');
      }
    }
    if (_jobQueue.isNotEmpty && !_draining) {
      // ignore: unawaited_futures
      _drainJobQueue(api: api, notifier: notifier);
    }
  }

  /// Drains the job queue with up to [_maxWorkers] parallel workers.
  /// Workers pick the highest-priority job each iteration.
  Future<void> _drainJobQueue({
    required ApiClient api,
    required PendingAssetNotesNotifier notifier,
    void Function(String noteId)? onDownloadReady,
  }) async {
    if (_draining) return;

    // Cross-window ownership: defer if another live window owns the drain.
    final cur = await _PendingAssetsStore.instance.read();
    if (cur.hasLiveOwner && cur.ownerId != _sessionId) {
      debugPrint('[Sync] another window owns drain — skipping');
      return;
    }
    await _PendingAssetsStore.instance.setOwner(_sessionId);

    _draining = true;
    final heartbeat = Timer.periodic(const Duration(seconds: 3), (_) {
      _PendingAssetsStore.instance.heartbeat(_sessionId);
    });

    try {
      // Always spawn _maxWorkers workers — each loops until queue exhausted.
      final n = _maxWorkers;
      if (n > 0) {
        await Future.wait(
          List.generate(
            n,
            (_) => _runWorker(
                api: api, notifier: notifier, onDownloadReady: onDownloadReady),
            growable: false,
          ),
        );
      }
    } finally {
      heartbeat.cancel();
      _draining = false;
      final after = await _PendingAssetsStore.instance.read();
      if (after.ownerId == _sessionId) {
        await _PendingAssetsStore.instance.setOwner(null);
      }
    }
  }

  // One parallel worker: loops picking highest-priority jobs until queue empty.
  Future<void> _runWorker({
    required ApiClient api,
    required PendingAssetNotesNotifier notifier,
    void Function(String noteId)? onDownloadReady,
  }) async {
    while (true) {
      final job = _pickNext();
      if (job == null) {
        if (_jobQueue.isEmpty) break;
        // All remaining jobs are duplicates of an in-flight one — wait.
        await Future<void>.delayed(const Duration(milliseconds: 150));
        continue;
      }
      if (job.dir == _AssetDir.upload) {
        await _runUploadFile(api, job);
      } else {
        await _runDownloadFile(api, notifier, job, onDownloadReady);
      }
    }
  }

  Future<void> _runUploadFile(ApiClient api, _AssetJob job) async {
    if (job.localFile == null) return;
    _setActiveFile(job.assetId, job.noteId, _AssetDir.upload);
    try {
      if (await api.assetExists(job.assetId)) return;
      final sizeMb = (await job.localFile!.length()) / 1024 / 1024;
      debugPrint('[Sync] uploading ${job.assetId} (${sizeMb.toStringAsFixed(1)} MB)');
      await api.uploadAsset(
        job.assetId,
        job.localFile!,
        onProgress: (sent, total) => _updateProgress(job.assetId, sent, total),
      );
      debugPrint('[Sync] uploaded ${job.assetId} ok');
    } catch (e) {
      debugPrint('[Sync] upload error ${job.assetId}: $e');
    } finally {
      _clearActiveFile(job.assetId);
    }
  }

  Future<void> _runDownloadFile(
    ApiClient api,
    PendingAssetNotesNotifier notifier,
    _AssetJob job,
    void Function(String noteId)? onReady,
  ) async {
    if (job.savePath == null) return;
    // Another worker may have completed this file already.
    final assetService = AssetService();
    if (await assetService.fileFor(job.assetId) != null) {
      _onFileDone(job.noteId, true, notifier, onReady);
      return;
    }
    _setActiveFile(job.assetId, job.noteId, _AssetDir.download);
    bool ok = false;
    try {
      for (int attempt = 1; attempt <= 3; attempt++) {
        debugPrint('[Sync] downloading ${job.assetId} (attempt $attempt/3)');
        ok = await api.downloadAssetToFile(
          job.assetId,
          job.savePath!,
          onProgress: (received, total) =>
              _updateProgress(job.assetId, received, total),
        );
        if (ok) {
          debugPrint('[Sync] downloaded ${job.assetId} ok');
          break;
        }
        if (attempt < 3) {
          final delay = Duration(seconds: 2 << (attempt - 1));
          debugPrint('[Sync] ${job.assetId} failed, retry in ${delay.inSeconds}s');
          await Future<void>.delayed(delay);
        }
      }
      if (!ok) debugPrint('[Sync] ${job.assetId} failed after 3 attempts');
    } finally {
      _clearActiveFile(job.assetId);
    }
    _onFileDone(job.noteId, ok, notifier, onReady);
  }

  void _onFileDone(
    String noteId,
    bool ok,
    PendingAssetNotesNotifier notifier,
    void Function(String noteId)? onReady,
  ) {
    final info = _noteState[noteId];
    if (info == null) return;
    info.completedAssets++;
    if (!ok) info.allOk = false;
    if (info.completedAssets < info.totalAssets) return;
    // All files done — finalize the note.
    final pagesJson = info.pagesJson;
    final allOk = info.allOk;
    _noteState.remove(noteId);
    // Schedule PDF render jobs and thumbnail invalidation as a fire-and-forget
    // micro-task so we don't block the worker.
    Future<void>(() async {
      try { await _enqueuePdfRenderJobs(pagesJson); } catch (_) {}
      try { await ThumbnailService.instance.invalidate(noteId); } catch (_) {}
      // Always release any waiters — even if some files failed, we don't
      // want the user's "open note" call to hang forever. The editor will
      // open with whatever's on disk; missing files render blank but don't
      // crash thanks to the 0-byte / corrupt-file guards.
      _completeWaiters(noteId);
      if (allOk) {
        await notifier.remove(noteId);
        onReady?.call(noteId);
        debugPrint('[Sync] note $noteId fully done');
      } else {
        debugPrint('[Sync] note $noteId partial — kept in pending for next sync');
      }
    });
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
    final api = apiFor(auth, onTokens: (t) { ref.read(authProvider.notifier).updateTokens(t); }, onLogout: () { ref.read(authProvider.notifier).clearTokens(); });
    final notebook = ref.read(notebookProvider);
    final cursors = await _loadedCursors();
    final lastKnownRev = cursors[notebook.note.id] ?? 0;
    final pushed = await _push(api, notebook, lastServerRev: lastKnownRev);
    // Always advance cursor from push result — even when a conflict was
    // detected, the server returns its current rev so the *next* push uses
    // the correct lastServerRev and doesn't re-trigger the same conflict.
    if (pushed.serverRev > lastKnownRev) {
      await _saveCursor(notebook.note.id, pushed.serverRev);
    }
    final effectiveSince = since ?? cursors[notebook.note.id] ?? 0;
    final pulled = await _pull(api, notebook, since: effectiveSince);
    await _saveCursor(notebook.note.id, pulled.cursor);
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
    final api = apiFor(auth, onTokens: (t) { ref.read(authProvider.notifier).updateTokens(t); }, onLogout: () { ref.read(authProvider.notifier).clearTokens(); });
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
  /// Asks the server to seal pending revisions into a new commit. No-op
  /// server-side if nothing was pushed since the last commit.
  Future<void> commitNote(String noteId, {String? message}) async {
    final auth = ref.read(authProvider).value;
    if (auth == null || !auth.isLoggedIn) return;
    final api = apiFor(auth, onTokens: (t) { ref.read(authProvider.notifier).updateTokens(t); }, onLogout: () { ref.read(authProvider.notifier).clearTokens(); });
    try {
      final r = await api.commitNote(noteId, message: message);
      if (r['committed'] == true) {
        debugPrint('[Sync] committed $noteId rev_to=${r['revTo']} changes=${r['changes']}');
      }
    } catch (e) {
      debugPrint('[Sync] commit error $noteId: $e');
    }
  }

  Future<void> pushNote(String noteId) async {
    final auth = ref.read(authProvider).value;
    if (auth == null || !auth.isLoggedIn) return;
    final api = apiFor(auth, onTokens: (t) { ref.read(authProvider.notifier).updateTokens(t); }, onLogout: () { ref.read(authProvider.notifier).clearTokens(); });
    final repo = ref.read(repositoryProvider);
    final state = await repo.loadByNoteId(noteId);
    if (state == null) return;
    final cursors = await _loadedCursors();
    try {
      final r = await _push(api, state, lastServerRev: cursors[noteId] ?? 0);
      if (r.serverRev > (cursors[noteId] ?? 0)) {
        await _saveCursor(noteId, r.serverRev);
      }
      await _enqueueUploadFiles(
        noteId: state.note.id,
        specs: state.pages.map((p) => p.spec).toList(),
        priority: _AssetPriority.p1,
      );
      // Drain immediately if not already running.
      if (_jobQueue.isNotEmpty && !_draining) {
        final notifier = ref.read(pendingAssetNotesProvider.notifier);
        // ignore: unawaited_futures
        _drainJobQueue(api: api, notifier: notifier);
      }
    } catch (e) {
      debugPrint('[Sync] background push error for $noteId: $e');
    }
  }

  Future<({int pushed, int serverRev})> _push(ApiClient api, NotebookState s, {int lastServerRev = 0}) async {
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
      'lastServerRev': lastServerRev,
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
    final resp = await api.syncPush(s.note.id, body);

    // Server marks objects whose server rev advanced past the rev we
    // submitted as "conflicting" — they're parked in conflict_items, not
    // applied. The client must surface this to the user; silently dropping
    // means lost data.
    final sid = (resp['conflictSessionId'] as String?) ?? '';
    if (sid.isNotEmpty) {
      debugPrint('[Sync] note ${s.note.id} has conflict session $sid');
      try {
        await ref.read(pendingConflictsProvider.notifier)
            .register(s.note.id, sid);
      } catch (e) {
        debugPrint('[Sync] failed to register conflict: $e');
      }
    }

    final newServerRev = (resp['serverRev'] as num?)?.toInt() ?? lastServerRev;
    return (pushed: changes.length, serverRev: newServerRev);
  }

  /// Resolves a raw specJson (Map or JSON string) to a typed Map.
  Map<String, dynamic>? _resolveSpec(dynamic specJson) {
    if (specJson is Map) return Map<String, dynamic>.from(specJson);
    if (specJson is String && specJson.isNotEmpty) {
      try {
        return jsonDecode(specJson) as Map<String, dynamic>;
      } catch (_) {}
    }
    return null;
  }

  /// After a note's PDF assets are on disk, queue render jobs for every
  /// page of that note. Workers will pick them up at P2 priority (or P1/P0
  /// once the user opens the note and the visibility hints kick in).
  Future<void> _enqueuePdfRenderJobs(List<dynamic> pagesJson) async {
    final assetService = AssetService();
    // Cache the resolved File per assetId so we don't fileFor() per page.
    final fileByAsset = <String, File?>{};
    int enqueued = 0;
    for (final p in pagesJson) {
      try {
        final pm = p as Map<String, dynamic>;
        final specMap = _resolveSpec(pm['spec']);
        if (specMap == null) continue;
        final spec = PageSpec.fromJson(specMap);
        final bg = spec.background;
        if (bg is! PdfBackground) continue;
        final assetId = bg.assetId;
        if (assetId.isEmpty) continue;
        File? file;
        if (fileByAsset.containsKey(assetId)) {
          file = fileByAsset[assetId];
        } else {
          file = await assetService.fileFor(assetId);
          fileByAsset[assetId] = file;
        }
        if (file == null) continue;
        PdfRenderCache.instance.enqueue(
          file,
          assetId,
          bg.pageNo,
          Size(spec.widthPt, spec.heightPt),
          [200],
        );
        enqueued++;
      } catch (e) {
        debugPrint('[Sync] PDF queue enqueue error: $e');
      }
    }
    debugPrint('[Sync] _enqueuePdfRenderJobs: enqueued $enqueued jobs from ${pagesJson.length} pages');
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
  Future<({int pushed, int notes, int pulled})> syncAllNotes({
    void Function(int current, int total)? onProgress,
    void Function(String? noteId)? onNoteId,
    void Function()? onNotePulled,
    void Function(String noteId)? onNoteAssetsReady,
  }) async {
    final auth = ref.read(authProvider).value;
    if (auth == null || !auth.isLoggedIn) return (pushed: 0, notes: 0, pulled: 0);
    final api = apiFor(auth, onTokens: (t) { ref.read(authProvider.notifier).updateTokens(t); }, onLogout: () { ref.read(authProvider.notifier).clearTokens(); });
    final repo = ref.read(repositoryProvider);
    final pending = ref.read(pendingAssetNotesProvider.notifier);

    // Drain any pending delete-tombstones first so server stays in sync
    // even if the original DELETE attempt was offline.
    await _drainTombstones();

    final summaries = await repo.listNoteSummaries();
    final localIds = summaries.map((s) => s.id).toSet();

    // Load tombstones so we don't re-pull notes the user deleted locally
    // (in case the server DELETE hasn't propagated yet).
    final tombstones = await _loadTombstones();

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
        .where((id) => !tombstones.contains(id)) // don't re-pull locally-deleted notes
        .toList();
    debugPrint('[Sync] server-only ids to pull: ${serverOnlyIds.length} → $serverOnlyIds');

    // Total counts: push step + pull DB step + per-note asset step.
    final total = summaries.length + serverOnlyIds.length * 2;
    int current = 0;
    int pushed = 0;
    int notes = 0;
    int pulled = 0; // notes pulled from server

    final cursors = await _loadedCursors();

    // ── Push local notes ──────────────────────────────────────────────
    for (final s in summaries) {
      current++;
      onNoteId?.call(s.id);
      onProgress?.call(current, total);
      final state = await repo.loadByNoteId(s.id);
      if (state == null) continue;
      try {
        final lastKnownRev = cursors[s.id] ?? 0;
        final r = await _push(api, state, lastServerRev: lastKnownRev);
        pushed += r.pushed;
        // Update cursor so subsequent syncs use the correct lastServerRev.
        if (r.serverRev > lastKnownRev) {
          await _saveCursor(s.id, r.serverRev);
        }
        notes++;
        // Enqueue asset uploads as P1 (processed in parallel with downloads).
        await _enqueueUploadFiles(
          noteId: state.note.id,
          specs: state.pages.map((p) => p.spec).toList(),
          priority: _AssetPriority.p1,
        );
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
        pulled++;
        final pages = pullData['pages'] as List? ?? const [];
        final hasWork = await _enqueueDownloadFiles(
          noteId: id,
          pagesJson: pages,
          priority: _AssetPriority.p1,
        );
        if (hasWork) {
          // ignore: unawaited_futures
          pending.add(id);
        } else {
          // No assets to fetch — note is immediately ready.
          try { await _enqueuePdfRenderJobs(pages); } catch (_) {}
          onNoteAssetsReady?.call(id);
        }
        onNotePulled?.call();
      } catch (e, st) {
        debugPrint('[Sync] pull/apply error for $id: $e\n$st');
      }
    }

    // ── Phase B: drain all queued upload+download jobs in parallel ────────
    await _drainJobQueue(
      api: api,
      notifier: pending,
      onDownloadReady: onNoteAssetsReady,
    );

    return (pushed: pushed, notes: notes, pulled: pulled);
  }
}

final syncActionsProvider = Provider<SyncActions>(SyncActions.new);
