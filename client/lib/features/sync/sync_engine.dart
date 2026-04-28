// SyncEngine — drains the local outbox to the server and applies inbound
// deltas. The wire format and conflict rules are in shared/docs/SYNC.md.
//
// P0 skeleton: clean interfaces + placeholder push/pull. Concrete dio +
// drift wiring lands in P9.

import 'dart:async';

abstract class SyncTransport {
  Future<PushResult> push(String noteId, PushPayload payload);
  Future<PullResult> pull(String noteId, String? cursor);
}

class PushPayload {
  PushPayload({required this.lastServerRev, required this.changes});
  final int lastServerRev;
  final List<Map<String, dynamic>> changes;
}

class PushResult {
  PushResult({required this.serverRev, required this.accepted, required this.conflicts});
  final int serverRev;
  final List<Map<String, dynamic>> accepted;
  final List<Map<String, dynamic>> conflicts;
}

class PullResult {
  PullResult({required this.cursor, required this.changes, required this.more});
  final String cursor;
  final List<Map<String, dynamic>> changes;
  final bool more;
}

abstract class OutboxStore {
  /// Returns up to [limit] queued changes for [noteId].
  Future<List<Map<String, dynamic>>> peek(String noteId, {int limit = 200});

  /// Removes accepted entries by id.
  Future<void> remove(List<String> ids);

  /// Replace local rev with server rev for accepted ids.
  Future<void> markAccepted(List<({String id, int serverRev})> updates);

  /// Apply server-provided versions over local copies (LWW loser side).
  Future<void> applyServerVersions(List<Map<String, dynamic>> serverObjects);
}

class SyncEngine {
  SyncEngine({required this.transport, required this.outbox});

  final SyncTransport transport;
  final OutboxStore outbox;

  bool _running = false;

  /// Drain the outbox once. Idempotent — safe to call repeatedly.
  Future<void> drain(String noteId, int lastServerRev) async {
    if (_running) return;
    _running = true;
    try {
      while (true) {
        final batch = await outbox.peek(noteId);
        if (batch.isEmpty) break;
        final result = await transport.push(
          noteId,
          PushPayload(lastServerRev: lastServerRev, changes: batch),
        );
        await outbox.markAccepted([
          for (final a in result.accepted)
            (id: a['id'] as String, serverRev: a['serverRev'] as int),
        ]);
        await outbox.remove([for (final a in result.accepted) a['id'] as String]);
        if (result.conflicts.isNotEmpty) {
          await outbox.applyServerVersions(
            [for (final c in result.conflicts) c['serverVersion'] as Map<String, dynamic>],
          );
        }
        lastServerRev = result.serverRev;
        if (batch.length < 200) break;
      }
    } finally {
      _running = false;
    }
  }

  Future<int> pullSince(String noteId, String? cursor,
      Future<void> Function(List<Map<String, dynamic>>) apply) async {
    var nextCursor = cursor;
    var totalApplied = 0;
    while (true) {
      final r = await transport.pull(noteId, nextCursor);
      if (r.changes.isNotEmpty) {
        await apply(r.changes);
        totalApplied += r.changes.length;
      }
      nextCursor = r.cursor;
      if (!r.more) break;
    }
    return totalApplied;
  }
}
