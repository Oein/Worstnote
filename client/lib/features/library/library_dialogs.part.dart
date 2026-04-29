part of 'library_screen.dart';

// ── PDF queue viewer ─────────────────────────────────────────────────────
class _PdfQueueDialog extends StatefulWidget {
  const _PdfQueueDialog();
  @override
  State<_PdfQueueDialog> createState() => _PdfQueueDialogState();
}

class _PdfQueueDialogState extends State<_PdfQueueDialog> {
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = PdfRenderCache.instance.onChanged.listen((_) {
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
    final s = PdfRenderCache.instance.snapshot();
    return Dialog(
      backgroundColor: t.toolbar,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                Text('PDF 렌더 큐',
                    style: TextStyle(
                      fontFamily: 'Newsreader',
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: t.ink,
                    )),
                const Spacer(),
                Text('스레드 ${s.maxConcurrent}개 · 진행 중 ${s.running.length}',
                    style: TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 11,
                        color: t.inkFaint)),
              ]),
              const SizedBox(height: 12),
              Expanded(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    _QueueSection(
                        title: 'P0 · 보고있는 페이지',
                        jobs: s.p0,
                        accent: const Color(0xFF2563EB),
                        t: t),
                    _QueueSection(
                        title: 'P1 · 현재 노트의 페이지',
                        jobs: s.p1,
                        accent: const Color(0xFF059669),
                        t: t),
                    _QueueSection(
                        title: 'P2 · 나머지 노트',
                        jobs: s.p2,
                        accent: t.inkFaint,
                        t: t),
                    if (s.running.isNotEmpty)
                      _QueueSection(
                          title: '진행 중',
                          jobs: s.running,
                          accent: const Color(0xFFEF4444),
                          t: t),
                  ],
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('닫기'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QueueSection extends StatelessWidget {
  const _QueueSection({
    required this.title,
    required this.jobs,
    required this.accent,
    required this.t,
  });
  final String title;
  final List<PdfRenderJobView> jobs;
  final Color accent;
  final NoteeTokens t;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Text(title,
                style: TextStyle(
                    fontFamily: 'Inter Tight',
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: t.inkDim)),
            const SizedBox(width: 6),
            Text('(${jobs.length})',
                style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 11,
                    color: t.inkFaint)),
          ]),
          const SizedBox(height: 6),
          if (jobs.isEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Text('—',
                  style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 11,
                      color: t.inkFaint)),
            )
          else
            for (final j in jobs)
              Padding(
                padding: const EdgeInsets.only(left: 16, top: 2),
                child: Text(
                  '${j.assetId.substring(0, math.min(8, j.assetId.length))}…  p${j.pageNo}  s${j.scalePct}%',
                  style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 11,
                      color: t.ink),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
        ],
      ),
    );
  }
}

// ── Conflict resolution dialog ───────────────────────────────────────────
class _ConflictResolutionDialog extends ConsumerStatefulWidget {
  const _ConflictResolutionDialog({
    required this.noteId,
    required this.sessionId,
  });
  final String noteId;
  final String sessionId;

  @override
  ConsumerState<_ConflictResolutionDialog> createState() =>
      _ConflictResolutionDialogState();
}

class _ConflictResolutionDialogState
    extends ConsumerState<_ConflictResolutionDialog> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _detail;
  final Map<String, String> _picks = {};
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final auth = ref.read(authProvider).value;
    if (auth == null || !auth.isLoggedIn) return;
    final api = apiFor(auth, onTokens: (t) { ref.read(authProvider.notifier).updateTokens(t); }, onLogout: () { ref.read(authProvider.notifier).clearTokens(); });
    try {
      final data = await api.conflictGet(widget.noteId, widget.sessionId);
      if (!mounted) return;
      setState(() {
        _detail = data;
        for (final item in (data['items'] as List? ?? [])) {
          _picks[(item as Map<String, dynamic>)['id'] as String] = 'server';
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _apply() async {
    final auth = ref.read(authProvider).value;
    if (auth == null || !auth.isLoggedIn) return;
    final api = apiFor(auth, onTokens: (t) { ref.read(authProvider.notifier).updateTokens(t); }, onLogout: () { ref.read(authProvider.notifier).clearTokens(); });
    setState(() => _applying = true);
    try {
      final result = await api.conflictResolve(widget.noteId, widget.sessionId, [
        for (final entry in _picks.entries)
          {'itemId': entry.key, 'resolution': entry.value},
      ]);
      final resolvedRev = (result['serverRev'] as num?)?.toInt() ?? 0;
      if (resolvedRev > 0) {
        await ref.read(syncActionsProvider).updateCursor(widget.noteId, resolvedRev);
      }
      await ref.read(pendingConflictsProvider.notifier).clear(widget.noteId);
      try {
        await ref.read(syncActionsProvider).syncNow();
      } catch (_) {}
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _applying = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final items = (_detail?['items'] as List?) ?? const [];
    return Dialog(
      backgroundColor: t.toolbar,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                Text('충돌 해결',
                    style: TextStyle(
                        fontFamily: 'Newsreader',
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: t.ink)),
                const Spacer(),
                Text('항목 ${items.length}개',
                    style: TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 11,
                        color: t.inkFaint)),
              ]),
              const SizedBox(height: 6),
              Text(
                '같은 항목을 다른 기기에서 동시에 수정해 충돌이 났어요. 항목별로 어느 쪽을 둘지 골라주세요.',
                style: TextStyle(color: t.inkDim, fontSize: 12),
              ),
              const SizedBox(height: 12),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                )
              else if (_error != null)
                Text(_error!,
                    style: const TextStyle(
                        color: Color(0xFFDC2626), fontSize: 12))
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: items.length,
                    separatorBuilder: (_, __) =>
                        Divider(height: 1, thickness: 1, color: t.tbBorder),
                    itemBuilder: (_, i) {
                      final item = items[i] as Map<String, dynamic>;
                      final id = item['id'] as String;
                      return _ConflictItemRow(
                        item: item,
                        pick: _picks[id] ?? 'server',
                        onPick: (r) => setState(() => _picks[id] = r),
                        t: t,
                      );
                    },
                  ),
                ),
              const SizedBox(height: 12),
              Row(children: [
                TextButton(
                  onPressed: _applying
                      ? null
                      : () async {
                          for (final item in items) {
                            _picks[(item as Map)['id'] as String] = 'server';
                          }
                          await _apply();
                        },
                  child: const Text('서버 변경 우선 (전체)'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _applying ? null : () => Navigator.of(context).pop(),
                  child: const Text('나중에'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: (_applying || _loading || _error != null)
                      ? null
                      : _apply,
                  child: _applying
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('적용'),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConflictItemRow extends StatelessWidget {
  const _ConflictItemRow({
    required this.item,
    required this.pick,
    required this.onPick,
    required this.t,
  });
  final Map<String, dynamic> item;
  final String pick;
  final void Function(String) onPick;
  final NoteeTokens t;

  @override
  Widget build(BuildContext context) {
    final objectId = item['objectId'] as String? ?? '';
    final localData = jsonEncode(item['localData']);
    final serverData = jsonEncode(item['serverData']);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('객체 ${objectId.length > 8 ? objectId.substring(0, 8) : objectId}',
              style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 11,
                  color: t.inkFaint)),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _ConflictDataBox(
                  title: '내 변경',
                  body: localData,
                  selected: pick == 'local',
                  onTap: () => onPick('local'),
                  t: t,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _ConflictDataBox(
                  title: '서버 변경',
                  body: serverData,
                  selected: pick == 'server',
                  onTap: () => onPick('server'),
                  t: t,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => onPick('deleted'),
              child: Text(
                pick == 'deleted' ? '✓ 삭제됨' : '둘 다 삭제',
                style: TextStyle(
                    fontSize: 11,
                    color: pick == 'deleted'
                        ? const Color(0xFFDC2626)
                        : t.inkDim),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConflictDataBox extends StatelessWidget {
  const _ConflictDataBox({
    required this.title,
    required this.body,
    required this.selected,
    required this.onTap,
    required this.t,
  });
  final String title;
  final String body;
  final bool selected;
  final VoidCallback onTap;
  final NoteeTokens t;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? t.accentSoft : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            border: Border.all(
              color: selected ? t.accent : t.tbBorder,
              width: selected ? 1.5 : 1,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: TextStyle(
                      fontFamily: 'Inter Tight',
                      fontWeight: FontWeight.w600,
                      fontSize: 11,
                      color: selected ? t.accent : t.inkDim)),
              const SizedBox(height: 4),
              Text(
                body.length > 140 ? '${body.substring(0, 140)}…' : body,
                style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 10,
                    color: t.ink),
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Sync transfer queue viewer ───────────────────────────────────────────
class _SyncQueueDialog extends ConsumerStatefulWidget {
  const _SyncQueueDialog();
  @override
  ConsumerState<_SyncQueueDialog> createState() => _SyncQueueDialogState();
}

class _SyncQueueDialogState extends ConsumerState<_SyncQueueDialog> {
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
    final s = ref.read(syncActionsProvider).snapshot();
    return Dialog(
      backgroundColor: t.toolbar,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                Text('동기화 큐',
                    style: TextStyle(
                      fontFamily: 'Newsreader',
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: t.ink,
                    )),
                const Spacer(),
                Text('워커 ${s.maxWorkers}개 · 진행 중 ${s.running.length}',
                    style: TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 11,
                        color: t.inkFaint)),
              ]),
              const SizedBox(height: 12),
              const _SyncProgressStrip(),
              const SizedBox(height: 8),
              Expanded(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    _SyncQueueSection(
                        title: 'P0 · 사용자 요청',
                        files: s.p0,
                        accent: const Color(0xFF2563EB),
                        t: t),
                    _SyncQueueSection(
                        title: 'P1 · 현재 동기화 세션',
                        files: s.p1,
                        accent: const Color(0xFF059669),
                        t: t),
                    _SyncQueueSection(
                        title: 'P2 · 백그라운드 / 재시도',
                        files: s.p2,
                        accent: t.inkFaint,
                        t: t),
                    if (s.running.isNotEmpty)
                      _SyncQueueSection(
                          title: '진행 중',
                          files: s.running,
                          accent: const Color(0xFFEF4444),
                          t: t),
                  ],
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('닫기'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SyncQueueSection extends StatelessWidget {
  const _SyncQueueSection({
    required this.title,
    required this.files,
    required this.accent,
    required this.t,
  });
  final String title;
  final List<AssetFileView> files;
  final Color accent;
  final NoteeTokens t;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Text(title,
                style: TextStyle(
                    fontFamily: 'Inter Tight',
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: t.inkDim)),
            const SizedBox(width: 6),
            Text('(${files.length})',
                style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 11,
                    color: t.inkFaint)),
          ]),
          const SizedBox(height: 6),
          if (files.isEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Text('—',
                  style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 11,
                      color: t.inkFaint)),
            )
          else
            for (final f in files) _buildFileRow(f, t),
        ],
      ),
    );
  }

  Widget _buildFileRow(AssetFileView f, NoteeTokens t) {
    final pct = f.progress;
    String sizeLabel = '';
    if (f.bytesTotal != null && f.bytesTotal! > 0) {
      final mb = (f.bytesTransferred ?? 0) / 1024 / 1024;
      final totalMb = f.bytesTotal! / 1024 / 1024;
      sizeLabel = '${mb.toStringAsFixed(1)}/${totalMb.toStringAsFixed(1)}MB';
    }
    final pctLabel = pct != null ? '${(pct * 100).toStringAsFixed(0)}%' : '';
    final isRunning = f.priority == 'running';
    return Padding(
      padding: const EdgeInsets.only(left: 16, top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Text(
              f.direction == 'upload' ? '↑' : '↓',
              style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 11,
                  color: f.direction == 'upload'
                      ? const Color(0xFF059669)
                      : const Color(0xFF2563EB)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${f.assetId.substring(0, math.min(12, f.assetId.length))}…  · note ${f.noteId.substring(0, math.min(6, f.noteId.length))}',
                style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 11,
                    color: t.ink),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isRunning && pctLabel.isNotEmpty) ...[
              const SizedBox(width: 6),
              Text(pctLabel,
                  style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: t.accent)),
            ],
          ]),
          if (isRunning) ...[
            const SizedBox(height: 3),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: SizedBox(
                height: 3,
                child: LinearProgressIndicator(
                  value: pct,
                  backgroundColor: t.tbBorder,
                  valueColor: AlwaysStoppedAnimation<Color>(t.accent),
                ),
              ),
            ),
            if (sizeLabel.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(sizeLabel,
                    style: TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 9,
                        color: t.inkFaint)),
              ),
          ],
        ],
      ),
    );
  }
}

// ── PDF render thread count setting ──────────────────────────────────────
class _PdfThreadsDialog extends StatefulWidget {
  const _PdfThreadsDialog();
  @override
  State<_PdfThreadsDialog> createState() => _PdfThreadsDialogState();
}

class _PdfThreadsDialogState extends State<_PdfThreadsDialog> {
  late int _value = PdfRenderCache.instance.maxConcurrent;

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    return Dialog(
      backgroundColor: t.toolbar,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('PDF 렌더 스레드 수',
                  style: TextStyle(
                    fontFamily: 'Newsreader',
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: t.ink,
                  )),
              const SizedBox(height: 6),
              Text(
                '스레드 수가 많을수록 PDF 페이지가 빨리 렌더되지만, 메모리를 더 사용합니다.',
                style: TextStyle(
                  fontFamily: 'Inter Tight',
                  fontSize: 12,
                  color: t.inkDim,
                ),
              ),
              const SizedBox(height: 16),
              Row(children: [
                Text('$_value',
                    style: TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                        color: t.ink)),
                const SizedBox(width: 8),
                Expanded(
                  child: Slider(
                    value: _value.toDouble(),
                    min: 1,
                    max: 8,
                    divisions: 7,
                    label: '$_value',
                    onChanged: (v) => setState(() => _value = v.round()),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('취소'),
                ),
                TextButton(
                  onPressed: () async {
                    PdfRenderCache.instance.setMaxConcurrent(_value);
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setInt('pdf_render_threads', _value);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  child: const Text('저장'),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Folder picker dialog (collapsible tree) ────────────────────────────

class _FolderPickerDialog extends StatefulWidget {
  const _FolderPickerDialog({
    required this.folders,
    this.currentFolderId,
    this.excludeFolderIds = const {},
  });
  final List<Folder> folders;
  final String? currentFolderId;
  final Set<String> excludeFolderIds;

  @override
  State<_FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends State<_FolderPickerDialog> {
  late final Set<String> _collapsed;

  @override
  void initState() {
    super.initState();
    _collapsed = widget.folders
        .where((f) => widget.folders.any((c) => c.parentId == f.id))
        .map((f) => f.id)
        .toSet();
  }

  List<Folder> _childrenOf(String? parentId) => widget.folders
      .where((f) => f.parentId == parentId)
      .toList()
    ..sort((a, b) => a.name.compareTo(b.name));

  bool _hasChildren(String id) =>
      widget.folders.any((f) => f.parentId == id);

  List<(Folder, int)> _visibleItems() {
    final result = <(Folder, int)>[];
    void visit(String? parentId, int depth) {
      for (final f in _childrenOf(parentId)) {
        if (widget.excludeFolderIds.contains(f.id)) continue;
        result.add((f, depth));
        if (!_collapsed.contains(f.id)) {
          visit(f.id, depth + 1);
        }
      }
    }
    visit(null, 0);
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final items = _visibleItems();

    return Dialog(
      backgroundColor: t.toolbar,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320, maxHeight: 480),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '폴더로 이동',
                style: TextStyle(
                  fontFamily: 'Newsreader',
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: t.ink,
                ),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    ListTile(
                      leading: Icon(Icons.home_outlined, color: t.ink),
                      title: Text(
                        '루트 (폴더 없음)',
                        style: TextStyle(
                          fontFamily: 'Inter Tight',
                          color: t.ink,
                        ),
                      ),
                      selected: widget.currentFolderId == null,
                      onTap: () => Navigator.of(context).pop('__root__'),
                    ),
                    for (final (f, depth) in items)
                      _FolderPickerRow(
                        folder: f,
                        depth: depth,
                        selected: widget.currentFolderId == f.id,
                        hasChildren: _hasChildren(f.id) &&
                            !widget.excludeFolderIds.contains(f.id),
                        collapsed: _collapsed.contains(f.id),
                        onTap: () => Navigator.of(context).pop(f.id),
                        onToggleCollapse: _hasChildren(f.id)
                            ? () => setState(() {
                                  if (_collapsed.contains(f.id)) {
                                    _collapsed.remove(f.id);
                                  } else {
                                    _collapsed.add(f.id);
                                  }
                                })
                            : null,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(
                    '취소',
                    style: TextStyle(
                      fontFamily: 'Inter Tight',
                      color: t.inkDim,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FolderPickerRow extends StatelessWidget {
  const _FolderPickerRow({
    required this.folder,
    required this.depth,
    required this.selected,
    required this.hasChildren,
    required this.collapsed,
    required this.onTap,
    this.onToggleCollapse,
  });
  final Folder folder;
  final int depth;
  final bool selected;
  final bool hasChildren;
  final bool collapsed;
  final VoidCallback onTap;
  final VoidCallback? onToggleCollapse;

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    return Padding(
      padding: EdgeInsets.only(left: depth * 16.0),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          decoration: BoxDecoration(
            color: selected ? t.accentSoft : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Row(children: [
            SizedBox(
              width: 20,
              child: hasChildren
                  ? GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onToggleCollapse,
                      child: Icon(
                        collapsed
                            ? Icons.chevron_right_rounded
                            : Icons.expand_more_rounded,
                        size: 16,
                        color: t.inkDim,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 4),
            Icon(
              _folderIconFor(folder.iconKey),
              color: Color(folder.colorArgb),
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                folder.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Inter Tight',
                  fontSize: 13,
                  color: t.ink,
                  fontWeight:
                      selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ── Folder appearance dialog ────────────────────────────────────────────

const _folderColorOptions = <int>[
  0xFFB0BEC5, // default gray-blue
  0xFFC9B78A, // tan
  0xFF9CA97A, // sage
  0xFFB89070, // brown
  0xFFB7A4C9, // lavender
  0xFF7AA4B0, // teal
  0xFFE57373, // red
  0xFF81C784, // green
  0xFF64B5F6, // blue
  0xFFFFB74D, // amber
  0xFFF06292, // pink
  0xFF4DB6AC, // teal-green
];

class _FolderAppearanceDialog extends StatefulWidget {
  const _FolderAppearanceDialog({
    required this.initialColor,
    required this.initialIconKey,
  });
  final int initialColor;
  final String initialIconKey;

  @override
  State<_FolderAppearanceDialog> createState() =>
      _FolderAppearanceDialogState();
}

class _FolderAppearanceDialogState extends State<_FolderAppearanceDialog> {
  late int _color;
  late String _iconKey;

  @override
  void initState() {
    super.initState();
    _color = widget.initialColor;
    _iconKey = widget.initialIconKey;
  }

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    return Dialog(
      backgroundColor: t.toolbar,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '색상/아이콘 변경',
                style: TextStyle(
                  fontFamily: 'Newsreader',
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: t.ink,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '색상',
                style: TextStyle(
                  fontFamily: 'Inter Tight',
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: t.inkDim,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in _folderColorOptions)
                    GestureDetector(
                      onTap: () => setState(() => _color = c),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: Color(c),
                          shape: BoxShape.circle,
                          border: _color == c
                              ? Border.all(color: t.ink, width: 2.5)
                              : Border.all(
                                  color: Colors.transparent, width: 2.5),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                '아이콘',
                style: TextStyle(
                  fontFamily: 'Inter Tight',
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: t.inkDim,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final entry in _folderIconMap.entries)
                    GestureDetector(
                      onTap: () => setState(() => _iconKey = entry.key),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: _iconKey == entry.key
                              ? Color(_color).withValues(alpha: 0.18)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          border: _iconKey == entry.key
                              ? Border.all(
                                  color: Color(_color).withValues(alpha: 0.6),
                                  width: 1.5)
                              : null,
                        ),
                        child: Icon(
                          entry.value,
                          color: _iconKey == entry.key
                              ? Color(_color)
                              : t.inkDim,
                          size: 20,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      '취소',
                      style: TextStyle(
                        fontFamily: 'Inter Tight',
                        color: t.inkDim,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () =>
                        Navigator.of(context).pop((_color, _iconKey)),
                    style: FilledButton.styleFrom(
                      backgroundColor: Color(_color),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text(
                      '저장',
                      style: TextStyle(fontFamily: 'Inter Tight'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
