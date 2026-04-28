import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/db/repository.dart';
import '../notebook/notebook_state.dart' show repositoryProvider;

// ── Session ID — unique per app instance lifetime ──────────────────────
final sessionIdProvider = Provider<String>((ref) => const Uuid().v4());

// ── Lock service provider ───────────────────────────────────────────────
final noteLockServiceProvider = Provider<NoteLockService>((ref) {
  final sessionId = ref.read(sessionIdProvider);
  final repo = ref.read(repositoryProvider);
  final service = NoteLockService(sessionId: sessionId, repo: repo);
  ref.onDispose(service.dispose);
  return service;
});

// ── Locked notes stream ─────────────────────────────────────────────────
/// noteId → sessionId map, updated live from DB.
final lockedNotesProvider = StreamProvider<Map<String, String>>((ref) {
  return ref.read(repositoryProvider).watchLockedNotes();
});

// ── Result types ────────────────────────────────────────────────────────
enum LockAcquireResult { acquired, handoffRequested, failed }

// ── Service ─────────────────────────────────────────────────────────────
class NoteLockService {
  NoteLockService({required this.sessionId, required this.repo}) {
    _initChannel();
  }

  final String sessionId;
  final NotebookRepository repo;

  static const _method = MethodChannel('notee/lock');
  static const _events = EventChannel('notee/lock_events');

  // Completer per noteId waiting for an ack.
  final Map<String, Completer<void>> _pendingAcks = {};

  // Stream of incoming handoff requests directed at us.
  final _handoffRequestController =
      StreamController<_HandoffEvent>.broadcast();
  // Stream of "library changed" notifications from any other instance.
  final _libraryChangedController = StreamController<void>.broadcast();
  // Stream of "tool settings changed" notifications from any other instance.
  final _toolChangedController = StreamController<void>.broadcast();

  Stream<_HandoffEvent> get handoffRequests => _handoffRequestController.stream;
  Stream<void> get libraryChanged => _libraryChangedController.stream;
  Stream<void> get toolChanged => _toolChangedController.stream;

  StreamSubscription<dynamic>? _eventSub;

  void _initChannel() {
    _eventSub = _events.receiveBroadcastStream().listen((dynamic raw) {
      final map = Map<String, dynamic>.from(raw as Map);
      final type = map['type'] as String;

      if (type == 'libraryChanged') {
        final source = map['source'] as String?;
        debugPrint('[Lock] libraryChanged event source=$source self=$sessionId');
        if (source != sessionId) {
          _libraryChangedController.add(null);
        }
        return;
      }

      if (type == 'toolChanged') {
        final source = map['source'] as String?;
        if (source != sessionId) {
          _toolChangedController.add(null);
        }
        return;
      }

      final target = map['target'] as String?;
      final source = map['source'] as String?;
      final noteId = map['noteId'] as String?;
      if (target == null || source == null || noteId == null) return;

      if (type == 'handoffRequest' && target == sessionId) {
        _handoffRequestController.add(_HandoffEvent(source: source, noteId: noteId));
      }
      if (type == 'handoffAck' && target == sessionId) {
        _pendingAcks[noteId]?.complete();
      }
    });
  }

  /// Try to acquire the lock for [noteId].
  ///
  /// - If unlocked → lock immediately → [LockAcquireResult.acquired]
  /// - If locked by dead session → force-unlock + claim → [acquired]
  /// - If locked by live session → request handoff → wait 600ms
  ///     → ack received: claim → [acquired]
  ///     → timeout: force-unlock + claim → [acquired]
  Future<LockAcquireResult> acquire(String noteId) async {
    debugPrint('[Lock] acquire noteId=$noteId session=$sessionId');

    // Fast path: try atomic lock-if-free.
    if (await repo.tryLockIfFree(noteId, sessionId)) {
      debugPrint('[Lock] atomic acquire OK');
      return LockAcquireResult.acquired;
    }

    // Already-mine fast path.
    final current = await repo.getNoteLock(noteId);
    debugPrint('[Lock] currently locked by=$current');
    if (current == sessionId) {
      debugPrint('[Lock] already self-locked');
      return LockAcquireResult.acquired;
    }
    if (current == null) {
      // Someone unlocked between our two queries — try once more.
      if (await repo.tryLockIfFree(noteId, sessionId)) {
        debugPrint('[Lock] atomic acquire OK (retry)');
        return LockAcquireResult.acquired;
      }
    }

    // Locked by another live session — request handoff.
    final completer = Completer<void>();
    _pendingAcks[noteId] = completer;

    try {
      await _method.invokeMethod('sendHandoffRequest', {
        'targetSession': current,
        'sourceSession': sessionId,
        'noteId': noteId,
      });
      debugPrint('[Lock] sent handoff request, waiting ack...');
      await completer.future.timeout(const Duration(milliseconds: 800));
      debugPrint('[Lock] ack received');
    } on TimeoutException {
      debugPrint('[Lock] handoff TIMEOUT — stealing');
    } catch (e) {
      debugPrint('[Lock] handoff error $e — stealing');
    } finally {
      _pendingAcks.remove(noteId);
    }

    await repo.forceUnlockNote(noteId);
    await repo.lockNote(noteId, sessionId);
    debugPrint('[Lock] post-handoff acquire OK');
    return LockAcquireResult.acquired;
  }

  /// Release the lock held by this session for [noteId].
  Future<void> release(String noteId) async {
    await repo.unlockNote(noteId, sessionId);
  }

  /// Send ack back to the requester that we've released [noteId].
  Future<void> sendAck({
    required String toSession,
    required String noteId,
  }) async {
    try {
      await _method.invokeMethod('sendHandoffAck', {
        'targetSession': toSession,
        'sourceSession': sessionId,
        'noteId': noteId,
      });
    } catch (_) {}
  }

  /// Release all locks held by this session (call on app shutdown).
  Future<void> releaseAll() async {
    await repo.releaseAllLocks(sessionId);
  }

  /// Open a new app window/instance (Android only).
  Future<void> openNewWindow() async {
    try {
      await _method.invokeMethod('openNewWindow');
    } catch (_) {}
  }

  /// Tell other app instances that the library changed (note created, deleted, etc.).
  Future<void> broadcastLibraryChanged() async {
    try {
      await _method.invokeMethod('broadcastLibraryChanged', {
        'sourceSession': sessionId,
      });
    } catch (_) {}
  }

  /// Tell other app instances that tool settings changed.
  Future<void> broadcastToolChanged() async {
    try {
      await _method.invokeMethod('broadcastToolChanged', {
        'sourceSession': sessionId,
      });
    } catch (_) {}
  }

  void dispose() {
    _eventSub?.cancel();
    _handoffRequestController.close();
    _libraryChangedController.close();
    _toolChangedController.close();
    releaseAll();
  }
}

class _HandoffEvent {
  const _HandoffEvent({required this.source, required this.noteId});
  final String source;
  final String noteId;
}
