part of 'library_screen.dart';

// ── Thin sync progress strip shown at top of library content ────────────
class _SyncProgressStrip extends ConsumerStatefulWidget {
  const _SyncProgressStrip();
  @override
  ConsumerState<_SyncProgressStrip> createState() => _SyncProgressStripState();
}

class _SyncProgressStripState extends ConsumerState<_SyncProgressStrip> {
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = ref.read(syncActionsProvider).onChanged.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final cloud = ref.watch(cloudSyncProvider);
    final pending = ref.watch(pendingAssetNotesProvider);
    final snap = ref.read(syncActionsProvider).snapshot();
    final queued = snap.p0.length + snap.p1.length + snap.p2.length;
    final running = snap.running.length;

    final isSyncing = cloud.status == CloudSyncStatus.syncing ||
        cloud.status == CloudSyncStatus.checking ||
        queued > 0 ||
        running > 0 ||
        pending.isNotEmpty;
    if (!isSyncing) return const SizedBox.shrink();

    final value = (cloud.syncTotal != null &&
            cloud.syncTotal! > 0 &&
            cloud.syncCurrent != null &&
            cloud.status == CloudSyncStatus.syncing)
        ? (cloud.syncCurrent! / cloud.syncTotal!).clamp(0.0, 1.0)
        : null;

    final label = <String>[];
    if (cloud.syncTotal != null && cloud.syncTotal! > 0) {
      label.add('동기화 ${cloud.syncCurrent ?? 0}/${cloud.syncTotal}');
    } else if (cloud.status == CloudSyncStatus.checking) {
      label.add('연결 확인 중…');
    }
    if (running > 0) label.add('전송 ${running}개 진행 중');
    if (queued > 0) label.add('${queued}개 대기');
    if (pending.isNotEmpty) label.add('에셋 ${pending.length}개 남음');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (label.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              label.join('  ·  '),
              style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 10,
                  color: t.inkFaint),
            ),
          ),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: SizedBox(
            height: 3,
            child: LinearProgressIndicator(
              value: value,
              backgroundColor: t.tbBorder,
              valueColor: AlwaysStoppedAnimation<Color>(t.accent),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Conflict banner shown above the library when push hit a server-side
//    conflict. Tapping opens the resolution dialog.
class _ConflictBanner extends ConsumerWidget {
  const _ConflictBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = NoteeProvider.of(context).tokens;
    final conflicts = ref.watch(pendingConflictsProvider);
    if (conflicts.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: const Color(0xFFFEF3C7),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () async {
            await showDialog<void>(
              context: context,
              builder: (_) => _ConflictResolutionDialog(
                noteId: conflicts.keys.first,
                sessionId: conflicts.values.first,
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(children: [
              const Icon(Icons.warning_amber_rounded,
                  size: 18, color: Color(0xFFB45309)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${conflicts.length}개 노트에서 충돌이 발생했어요',
                        style: TextStyle(
                            color: const Color(0xFF78350F),
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text('서버의 다른 변경과 겹쳐서 일부 변경사항이 적용되지 않았습니다. 탭해서 해결.',
                        style: TextStyle(
                            color: t.inkDim.withValues(alpha: 0.75),
                            fontSize: 11)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right, size: 18, color: Color(0xFF78350F)),
            ]),
          ),
        ),
      ),
    );
  }
}

// ─── Cloud sync status button ─────────────────────────────────────────────

class _CloudButton extends ConsumerStatefulWidget {
  const _CloudButton({required this.anchorKey});
  final GlobalKey anchorKey;

  @override
  ConsumerState<_CloudButton> createState() => _CloudButtonState();
}

class _CloudButtonState extends ConsumerState<_CloudButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  Future<void> _openPopover() async {
    final t = NoteeProvider.of(context).tokens;
    await showNoteePopover<void>(
      context,
      anchorKey: widget.anchorKey,
      placement: NoteePopoverPlacement.below,
      maxWidth: 260,
      builder: (ctx) => _CloudPopover(tokens: t),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final cloud = ref.watch(cloudSyncProvider);

    if (cloud.status == CloudSyncStatus.checking ||
        cloud.status == CloudSyncStatus.syncing) {
      if (!_spin.isAnimating) _spin.repeat();
    } else {
      if (_spin.isAnimating) _spin.stop();
    }

    final (icon, color) = switch (cloud.status) {
      CloudSyncStatus.notLoggedIn => (Icons.cloud_outlined,      t.inkFaint),
      CloudSyncStatus.idle        => (Icons.cloud,               t.accent),
      CloudSyncStatus.checking    => (Icons.sync,                t.accent),
      CloudSyncStatus.syncing     => (Icons.sync,                t.accent),
      CloudSyncStatus.ok          => (Icons.cloud_done,          const Color(0xFF4CAF50)),
      CloudSyncStatus.error       => (Icons.cloud_off,           t.inkFaint),
    };

    Widget iconWidget = Icon(icon, size: 19, color: color);

    if (cloud.status == CloudSyncStatus.checking ||
        cloud.status == CloudSyncStatus.syncing) {
      iconWidget = RotationTransition(
        turns: _spin,
        child: iconWidget,
      );
    }

    return IconButton(
      tooltip: _tooltip(cloud),
      icon: iconWidget,
      onPressed: _openPopover,
    );
  }

  String _tooltip(CloudSyncState s) {
    if (s.status == CloudSyncStatus.syncing &&
        s.syncTotal != null && s.syncTotal! > 0) {
      return '동기화중… (${s.syncCurrent ?? 0}/${s.syncTotal})';
    }
    return switch (s.status) {
      CloudSyncStatus.notLoggedIn => '로그인 필요',
      CloudSyncStatus.idle        => '연결됨',
      CloudSyncStatus.checking    => '연결 확인 중…',
      CloudSyncStatus.syncing     => '동기화중…',
      CloudSyncStatus.ok          => '연결됨',
      CloudSyncStatus.error       => '오프라인',
    };
  }
}

// ─── Cloud badge on note thumbnails ──────────────────────────────────────

class _CloudBadge extends ConsumerStatefulWidget {
  const _CloudBadge({required this.noteId});
  final String noteId;

  @override
  ConsumerState<_CloudBadge> createState() => _CloudBadgeState();
}

class _CloudBadgeState extends ConsumerState<_CloudBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cloud = ref.watch(cloudSyncProvider);

    if (cloud.status == CloudSyncStatus.notLoggedIn) return const SizedBox.shrink();

    final isThisNoteSyncing = cloud.status == CloudSyncStatus.syncing &&
        cloud.syncingNoteId == widget.noteId;

    if (isThisNoteSyncing || cloud.status == CloudSyncStatus.checking) {
      if (!_spin.isAnimating) _spin.repeat();
    } else {
      if (_spin.isAnimating) _spin.stop();
    }

    final IconData icon;
    if (isThisNoteSyncing || cloud.status == CloudSyncStatus.checking) {
      icon = Icons.sync;
    } else if (cloud.status == CloudSyncStatus.error) {
      icon = Icons.cloud_off;
    } else if (cloud.status == CloudSyncStatus.ok) {
      icon = Icons.cloud_done;
    } else {
      icon = Icons.cloud;
    }

    Widget iconWidget = Icon(icon, size: 12, color: Colors.white.withValues(alpha: 0.9));
    if (isThisNoteSyncing || cloud.status == CloudSyncStatus.checking) {
      iconWidget = RotationTransition(turns: _spin, child: iconWidget);
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: cloud.status == CloudSyncStatus.error
            ? Colors.black.withValues(alpha: 0.25)
            : Colors.black.withValues(alpha: 0.18),
        shape: BoxShape.circle,
      ),
      child: iconWidget,
    );
  }
}

// ─── Cloud status popover ─────────────────────────────────────────────────

String _buildSyncSummary(CloudSyncState cloud) {
  final pushed = cloud.lastSyncPushedNotes ?? 0;
  final pulled = cloud.lastSyncPulledNotes ?? 0;
  final changes = cloud.lastSyncChanges ?? 0;
  final parts = <String>[];
  if (pushed > 0) parts.add('↑ $pushed개 노트 업로드');
  if (pulled > 0) parts.add('↓ $pulled개 노트 다운로드');
  if (changes > 0) parts.add('$changes개 변경사항');
  if (parts.isEmpty) parts.add('변경 없음');
  return '마지막 동기화: ${parts.join('  ')}';
}

class _CloudPopover extends ConsumerWidget {
  const _CloudPopover({required this.tokens});
  final NoteeTokens tokens;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = tokens;
    final cloud = ref.watch(cloudSyncProvider);
    ref.watch(authProvider);

    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(
              _statusIcon(cloud.status),
              size: 16,
              color: _statusColor(cloud.status, t),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _statusLabel(cloud),
                style: TextStyle(
                  color: t.ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ]),

          if (cloud.status == CloudSyncStatus.syncing ||
              cloud.status == CloudSyncStatus.checking) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: SizedBox(
                height: 4,
                child: LinearProgressIndicator(
                  value: (cloud.syncTotal != null &&
                          cloud.syncTotal! > 0 &&
                          cloud.syncCurrent != null)
                      ? (cloud.syncCurrent! / cloud.syncTotal!).clamp(0.0, 1.0)
                      : null,
                  backgroundColor: t.tbBorder,
                  valueColor: AlwaysStoppedAnimation<Color>(t.accent),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Builder(builder: (_) {
              final pending = ref.watch(pendingAssetNotesProvider);
              final running = ref.read(syncActionsProvider).snapshot().running.length;
              final phase = (cloud.syncTotal != null && cloud.syncTotal! > 0)
                  ? '${cloud.syncCurrent ?? 0} / ${cloud.syncTotal}'
                  : '';
              final assets = pending.isNotEmpty
                  ? '에셋 ${pending.length}개 대기 · 워커 $running'
                  : '';
              final parts = [phase, assets].where((s) => s.isNotEmpty).join('  ·  ');
              if (parts.isEmpty) return const SizedBox.shrink();
              return Text(
                parts,
                style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    color: t.inkFaint,
                    fontSize: 10),
              );
            }),
          ],

          if (cloud.serverUrl != null) ...[
            const SizedBox(height: 6),
            Text(
              cloud.serverUrl!,
              style: TextStyle(
                color: t.inkFaint,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],

          if (cloud.lastCheckedAt != null) ...[
            const SizedBox(height: 4),
            Text(
              '마지막 확인: ${_relativeTime(cloud.lastCheckedAt!)}',
              style: TextStyle(color: t.inkFaint, fontSize: 11),
            ),
          ],

          if (cloud.lastSyncPushedNotes != null || cloud.lastSyncPulledNotes != null) ...[
            const SizedBox(height: 4),
            Text(
              _buildSyncSummary(cloud),
              style: TextStyle(color: t.inkFaint, fontSize: 11),
            ),
          ],

          if (cloud.status == CloudSyncStatus.error &&
              cloud.errorMessage != null) ...[
            const SizedBox(height: 6),
            Text(
              cloud.errorMessage!,
              style: const TextStyle(color: Color(0xFFDC2626), fontSize: 11),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],

          const SizedBox(height: 12),
          Divider(height: 1, thickness: 1, color: t.tbBorder),
          const SizedBox(height: 10),

          if (cloud.status == CloudSyncStatus.notLoggedIn)
            _ActionRow(
              icon: Icons.login,
              label: '로그인',
              color: t.accent,
              tokens: t,
              onTap: () {
                Navigator.of(context).pop();
                showDialog<void>(
                  context: context,
                  builder: (_) => const LoginDialog(),
                );
              },
            )
          else ...[
            _ActionRow(
              icon: Icons.cloud_sync,
              label: '모두 동기화',
              color: t.accent,
              tokens: t,
              onTap: () {
                Navigator.of(context).pop();
                ref.read(cloudSyncProvider.notifier).syncAll();
              },
            ),
            const SizedBox(height: 6),
            _ActionRow(
              icon: Icons.refresh,
              label: '연결 확인',
              color: t.inkDim,
              tokens: t,
              onTap: () {
                Navigator.of(context).pop();
                ref.read(cloudSyncProvider.notifier).checkNow();
              },
            ),
            const SizedBox(height: 6),
            _ActionRow(
              icon: Icons.logout,
              label: '로그아웃',
              color: const Color(0xFFDC2626),
              tokens: t,
              onTap: () {
                Navigator.of(context).pop();
                ref.read(authProvider.notifier).logout();
              },
            ),
          ],
        ],
      ),
    );
  }

  IconData _statusIcon(CloudSyncStatus s) => switch (s) {
    CloudSyncStatus.notLoggedIn => Icons.cloud_outlined,
    CloudSyncStatus.idle        => Icons.cloud,
    CloudSyncStatus.checking    => Icons.sync,
    CloudSyncStatus.syncing     => Icons.sync,
    CloudSyncStatus.ok          => Icons.cloud_done,
    CloudSyncStatus.error       => Icons.cloud_off,
  };

  Color _statusColor(CloudSyncStatus s, NoteeTokens t) => switch (s) {
    CloudSyncStatus.notLoggedIn => t.inkFaint,
    CloudSyncStatus.idle        => t.accent,
    CloudSyncStatus.checking    => t.accent,
    CloudSyncStatus.syncing     => t.accent,
    CloudSyncStatus.ok          => const Color(0xFF4CAF50),
    CloudSyncStatus.error       => t.inkFaint,
  };

  String _statusLabel(CloudSyncState s) {
    if (s.status == CloudSyncStatus.syncing &&
        s.syncTotal != null && s.syncTotal! > 0) {
      return '동기화중… (${s.syncCurrent ?? 0}/${s.syncTotal})';
    }
    return switch (s.status) {
      CloudSyncStatus.notLoggedIn => '로그인 필요',
      CloudSyncStatus.idle        => '연결됨',
      CloudSyncStatus.checking    => '확인 중…',
      CloudSyncStatus.syncing     => '동기화중…',
      CloudSyncStatus.ok          => '연결됨',
      CloudSyncStatus.error       => '오프라인',
    };
  }

  String _relativeTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return '방금 전';
    if (diff.inMinutes < 60) return '${diff.inMinutes}분 전';
    return '${diff.inHours}시간 전';
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.label,
    required this.color,
    required this.tokens,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final NoteeTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ]),
      ),
    );
  }
}
