// CloudSyncState — tracks server connectivity and auth state for the
// cloud status button in the library header.

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_state.dart';
import '../library/library_state.dart';
import 'sync_actions.dart';

enum CloudSyncStatus {
  notLoggedIn, // no tokens → dotted cloud
  idle,        // logged in, connected
  checking,    // health ping in flight → spinning
  syncing,     // actively pushing notes → spinning
  ok,          // last ping succeeded (briefly shown)
  error,       // ping failed / offline
}

class CloudSyncState {
  const CloudSyncState({
    required this.status,
    this.errorMessage,
    this.lastCheckedAt,
    this.serverUrl,
    this.lastSyncPushedNotes,
    this.lastSyncPulledNotes,
    this.lastSyncChanges,
    this.syncCurrent,
    this.syncTotal,
    this.syncingNoteId,
  });

  final CloudSyncStatus status;
  final String? errorMessage;
  final DateTime? lastCheckedAt;
  final String? serverUrl;
  final int? lastSyncPushedNotes;   // notes pushed in last sync
  final int? lastSyncPulledNotes;   // notes pulled from server in last sync
  final int? lastSyncChanges;       // change objects (strokes/etc.) pushed
  final int? syncCurrent;           // notes done so far in active sync
  final int? syncTotal;             // total notes in active sync
  final String? syncingNoteId;      // note ID currently being pushed/pulled

  CloudSyncState copyWith({
    CloudSyncStatus? status,
    String? errorMessage,
    DateTime? lastCheckedAt,
    String? serverUrl,
    int? lastSyncPushedNotes,
    int? lastSyncPulledNotes,
    int? lastSyncChanges,
    int? syncCurrent,
    int? syncTotal,
    String? syncingNoteId,
  }) => CloudSyncState(
    status: status ?? this.status,
    errorMessage: errorMessage,
    lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
    serverUrl: serverUrl ?? this.serverUrl,
    lastSyncPushedNotes: lastSyncPushedNotes ?? this.lastSyncPushedNotes,
    lastSyncPulledNotes: lastSyncPulledNotes ?? this.lastSyncPulledNotes,
    lastSyncChanges: lastSyncChanges ?? this.lastSyncChanges,
    syncCurrent: syncCurrent ?? this.syncCurrent,
    syncTotal: syncTotal ?? this.syncTotal,
    syncingNoteId: syncingNoteId,
  );
}

class CloudSyncNotifier extends Notifier<CloudSyncState> {
  @override
  CloudSyncState build() {
    final auth = ref.watch(authProvider).value;
    if (auth == null || !auth.isLoggedIn) {
      return CloudSyncState(
        status: CloudSyncStatus.notLoggedIn,
        serverUrl: auth?.serverUrl,
      );
    }
    return CloudSyncState(
      status: CloudSyncStatus.idle,
      serverUrl: auth.serverUrl,
    );
  }

  Future<void> checkNow() async {
    final auth = ref.read(authProvider).value;
    if (auth == null || !auth.isLoggedIn) {
      state = CloudSyncState(
        status: CloudSyncStatus.notLoggedIn,
        serverUrl: auth?.serverUrl,
      );
      return;
    }

    state = state.copyWith(status: CloudSyncStatus.checking);

    try {
      final api = apiFor(auth);
      await api.healthCheck();
      final now = DateTime.now();
      state = state.copyWith(status: CloudSyncStatus.ok, lastCheckedAt: now);

      await Future<void>.delayed(const Duration(seconds: 3));
      if (state.status == CloudSyncStatus.ok) {
        state = state.copyWith(status: CloudSyncStatus.idle);
      }
    } catch (e) {
      state = state.copyWith(
        status: CloudSyncStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  Future<void> syncAll() async {
    if (state.status == CloudSyncStatus.notLoggedIn) return;
    // Guard re-entry — callers fire syncAll after every library mutation,
    // so multiple invocations land while a previous run is still in-flight.
    if (state.status == CloudSyncStatus.syncing ||
        state.status == CloudSyncStatus.checking ||
        state.status == CloudSyncStatus.ok) return;
    state = state.copyWith(
      status: CloudSyncStatus.syncing,
      syncCurrent: 0,
      syncTotal: null,
    );
    try {
      final r = await ref.read(syncActionsProvider).syncAllNotes(
        onProgress: (current, total) {
          state = state.copyWith(syncCurrent: current, syncTotal: total);
        },
        onNoteId: (noteId) {
          state = state.copyWith(syncingNoteId: noteId);
        },
        onNotePulled: () {
          // Surface each pulled note immediately (DB only — assets still pending).
          ref.read(libraryProvider.notifier).refresh();
        },
        onNoteAssetsReady: (_) {
          // Refresh again so the freshly regenerated PDF/image cover
          // thumbnail picks up.
          ref.read(libraryProvider.notifier).refresh();
        },
      );
      state = state.copyWith(
        status: CloudSyncStatus.ok,
        lastCheckedAt: DateTime.now(),
        lastSyncPushedNotes: r.notes - r.pulled,
        lastSyncPulledNotes: r.pulled,
        lastSyncChanges: r.pushed,
        syncCurrent: null,
        syncTotal: null,
        syncingNoteId: null,
      );
      // Refresh library so newly pulled notes become visible.
      await ref.read(libraryProvider.notifier).refresh();
      await Future<void>.delayed(const Duration(seconds: 3));
      if (state.status == CloudSyncStatus.ok) {
        state = state.copyWith(status: CloudSyncStatus.idle);
      }
    } catch (e) {
      // Both access and refresh tokens rejected → session is dead, auto-logout.
      if (e is DioException && e.response?.statusCode == 401) {
        await ref.read(authProvider.notifier).logout();
        return;
      }
      state = state.copyWith(
        status: CloudSyncStatus.error,
        errorMessage: e.toString(),
        syncCurrent: null,
        syncTotal: null,
        syncingNoteId: null,
      );
    }
  }
}

final cloudSyncProvider =
    NotifierProvider<CloudSyncNotifier, CloudSyncState>(CloudSyncNotifier.new);
