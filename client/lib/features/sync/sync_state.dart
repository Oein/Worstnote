// CloudSyncState — tracks server connectivity and auth state for the
// cloud status button in the library header.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_state.dart';
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
  });

  final CloudSyncStatus status;
  final String? errorMessage;
  final DateTime? lastCheckedAt;
  final String? serverUrl;
  final int? lastSyncPushed;   // objects pushed in last sync
  final int? lastSyncTotal;    // total notes processed in last sync

  CloudSyncState copyWith({
    CloudSyncStatus? status,
    String? errorMessage,
    DateTime? lastCheckedAt,
    String? serverUrl,
    int? lastSyncPushed,
    int? lastSyncTotal,
  }) => CloudSyncState(
    status: status ?? this.status,
    errorMessage: errorMessage,
    lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
    serverUrl: serverUrl ?? this.serverUrl,
    lastSyncPushed: lastSyncPushed ?? this.lastSyncPushed,
    lastSyncTotal: lastSyncTotal ?? this.lastSyncTotal,
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
    state = state.copyWith(status: CloudSyncStatus.syncing);
    try {
      final r = await ref.read(syncActionsProvider).syncAllNotes();
      state = state.copyWith(
        status: CloudSyncStatus.ok,
        lastCheckedAt: DateTime.now(),
        lastSyncPushed: r.pushed,
        lastSyncTotal: r.notes,
      );
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
}

final cloudSyncProvider =
    NotifierProvider<CloudSyncNotifier, CloudSyncState>(CloudSyncNotifier.new);
