// CloudSyncState — tracks server connectivity and auth state for the
// cloud status button in the library header.

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
    this.lastSyncPushed,
    this.lastSyncTotal,
    this.syncCurrent,
    this.syncTotal,
    this.syncingNoteId,
  });

  final CloudSyncStatus status;
  final String? errorMessage;
  final DateTime? lastCheckedAt;
  final String? serverUrl;
  final int? lastSyncPushed;  // objects pushed in last sync
  final int? lastSyncTotal;   // total notes processed in last sync
  final int? syncCurrent;     // notes done so far in active sync
  final int? syncTotal;       // total notes in active sync
  final String? syncingNoteId; // note ID currently being pushed/pulled

  CloudSyncState copyWith({
    CloudSyncStatus? status,
    String? errorMessage,
    DateTime? lastCheckedAt,
    String? serverUrl,
    int? lastSyncPushed,
    int? lastSyncTotal,
    int? syncCurrent,
    int? syncTotal,
    String? syncingNoteId,
  }) => CloudSyncState(
    status: status ?? this.status,
    errorMessage: errorMessage,
    lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
    serverUrl: serverUrl ?? this.serverUrl,
    lastSyncPushed: lastSyncPushed ?? this.lastSyncPushed,
    lastSyncTotal: lastSyncTotal ?? this.lastSyncTotal,
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
      );
      state = state.copyWith(
        status: CloudSyncStatus.ok,
        lastCheckedAt: DateTime.now(),
        lastSyncPushed: r.pushed,
        lastSyncTotal: r.notes,
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
