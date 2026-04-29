part of 'library_screen.dart';

// ── Main area: breadcrumb + grid ─────────────────────────────────────
class _MainArea extends ConsumerStatefulWidget {
  const _MainArea({
    required this.state,
    required this.searchQuery,
    required this.isGridView,
    required this.sortOrder,
    required this.filter,
    required this.onCreateFolder,
  });
  final LibraryState state;
  final String searchQuery;
  final bool isGridView;
  final _SortOrder sortOrder;
  final _LibFilter filter;
  final Future<void> Function() onCreateFolder;

  @override
  ConsumerState<_MainArea> createState() => _MainAreaState();
}

class _MainAreaState extends ConsumerState<_MainArea> {
  final Set<String> _selectedNoteIds = {};
  final Set<String> _selectedFolderIds = {};

  bool _selectionMode = false;

  Set<String> get _selectedIds => {..._selectedNoteIds, ..._selectedFolderIds};

  void _toggleSelectNote(String id) {
    setState(() {
      if (_selectedNoteIds.contains(id)) {
        _selectedNoteIds.remove(id);
      } else {
        _selectedNoteIds.add(id);
      }
    });
  }

  void _toggleSelectFolder(String id) {
    setState(() {
      if (_selectedFolderIds.contains(id)) {
        _selectedFolderIds.remove(id);
      } else {
        _selectedFolderIds.add(id);
      }
    });
  }

  void _enterSelectionModeNote(String id) {
    setState(() {
      _selectionMode = true;
      _selectedNoteIds.clear();
      _selectedFolderIds.clear();
      _selectedNoteIds.add(id);
    });
  }

  void _enterSelectionModeFolder(String id) {
    setState(() {
      _selectionMode = true;
      _selectedNoteIds.clear();
      _selectedFolderIds.clear();
      _selectedFolderIds.add(id);
    });
  }

  void _selectAllVisible(List<Folder> folders, List<NoteSummary> notes) {
    setState(() {
      _selectionMode = true;
      _selectedNoteIds.addAll(notes.map((n) => n.id));
      _selectedFolderIds.addAll(folders.map((f) => f.id));
    });
  }

  void _exitSelectionMode() => setState(() {
    _selectionMode = false;
    _selectedNoteIds.clear();
    _selectedFolderIds.clear();
  });

  void _setSelectionFromRubberBand(
      Set<String> noteIds, Set<String> folderIds, Offset globalPos) {
    setState(() {
      _selectedNoteIds
        ..clear()
        ..addAll(noteIds);
      _selectedFolderIds
        ..clear()
        ..addAll(folderIds);
      _selectionMode = _selectedNoteIds.isNotEmpty || _selectedFolderIds.isNotEmpty;
    });
  }

  Future<void> _openNote(String id) async {
    debugPrint('[OpenNote] start id=$id');
    final pending = ref.read(pendingAssetNotesProvider);
    if (pending.contains(id)) {
      final messenger = ScaffoldMessenger.of(context);
      messenger
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(
          content: Text('동기화 중인 노트입니다. 잠시만 기다려 주세요…'),
          duration: Duration(seconds: 30),
        ));
      try {
        await ref.read(syncActionsProvider).prioritizeNoteAssets(id);
      } finally {
        if (mounted) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
        }
      }
      if (!mounted) return;
    }
    final lockService = ref.read(noteLockServiceProvider);
    final result = await lockService.acquire(id);
    debugPrint('[OpenNote] acquire returned $result mounted=$mounted');
    if (!mounted) return;
    ref.read(currentNoteIdProvider.notifier).state = id;
    debugPrint('[OpenNote] noteId set');
  }

  List<NoteSummary> _sorted(List<NoteSummary> notes) {
    final list = [...notes];
    switch (widget.sortOrder) {
      case _SortOrder.updatedAt:
        list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      case _SortOrder.createdAt:
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      case _SortOrder.name:
        list.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final ctl = ref.read(libraryProvider.notifier);
    final state = widget.state;
    final searchQuery = widget.searchQuery;
    final isGridView = widget.isGridView;
    final filter = widget.filter;
    final pendingNoteIds = ref.watch(pendingAssetNotesProvider);

    var folders = state.childFoldersHere;
    var notes = state.notesHere;
    if (filter == _LibFilter.favorites) {
      folders = const [];
      notes = state.notes.where((n) => n.isFavorite).toList();
    } else if (filter == _LibFilter.recent) {
      folders = const [];
      notes = [...state.notes]
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      if (notes.length > 30) notes = notes.sublist(0, 30);
    }
    if (searchQuery.trim().isNotEmpty) {
      final q = searchQuery.toLowerCase();
      notes = state.notes.where((n) => n.title.toLowerCase().contains(q)).toList();
      folders = const [];
    }
    if (filter != _LibFilter.recent) notes = _sorted(notes);

    final isInFolder = state.currentFolderId != null;
    return PopScope(
      canPop: !_selectionMode && !isInFolder,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selectionMode) {
          _exitSelectionMode();
        } else if (isInFolder) {
          ctl.navigateUp();
        }
      },
      child: Stack(children: [
        Padding(
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Breadcrumb(state: state),
          const SizedBox(height: 8),
          const _ConflictBanner(),
          const SizedBox(height: 6),
          if (_selectionMode)
            _MultiSelectBar(
              noteCount: _selectedNoteIds.length,
              folderCount: _selectedFolderIds.length,
              totalVisible: folders.length + notes.length,
              onClear: _exitSelectionMode,
              onSelectAll: () => _selectAllVisible(folders, notes),
            )
          else
            Row(crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic, children: [
              Flexible(
                child: Text(
                  searchQuery.isNotEmpty
                      ? 'Search results'
                      : filter == _LibFilter.favorites
                          ? 'Favorites'
                          : filter == _LibFilter.recent
                              ? 'Recent notes'
                              : (state.currentFolder?.name ?? 'All notebooks'),
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.4,
                      ),
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  '${folders.length} folders · ${notes.length} notebooks',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 11,
                    color: t.inkFaint,
                  ),
                ),
              ),
              const Spacer(),
            ]),
          const SizedBox(height: 18),
          Expanded(
            child: (folders.isEmpty && notes.isEmpty)
                ? _EmptyState(onCreateFolder: widget.onCreateFolder)
                : isGridView
                    ? _GridContent(
                        folders: folders,
                        notes: notes,
                        selectedNoteIds: _selectedNoteIds,
                        selectedFolderIds: _selectedFolderIds,
                        pendingNoteIds: pendingNoteIds,
                        selectionMode: _selectionMode,
                        onOpenFolder: (id) {
                          if (_selectionMode) {
                            _toggleSelectFolder(id);
                          } else {
                            ctl.navigateInto(id);
                          }
                        },
                        onEnterSelectionFolder: _enterSelectionModeFolder,
                        onFolderContext: (f, pos) =>
                            _showFolderContextMenu(context, ref, f, pos),
                        onOpenNote: (id) {
                          if (_selectionMode) {
                            _toggleSelectNote(id);
                          } else {
                            _openNote(id);
                          }
                        },
                        onEnterSelectionNote: _enterSelectionModeNote,
                        onNoteContext: (n, pos) =>
                            _showNoteContextMenu(context, ref, n, pos),
                        onToggleSelectNote: _toggleSelectNote,
                        onToggleSelectFolder: _toggleSelectFolder,
                        onRubberBandSelect: _setSelectionFromRubberBand,
                      )
                    : _ListContent(
                        folders: folders,
                        notes: notes,
                        selectedNoteIds: _selectedNoteIds,
                        selectedFolderIds: _selectedFolderIds,
                        pendingNoteIds: pendingNoteIds,
                        selectionMode: _selectionMode,
                        onOpenFolder: (id) {
                          if (_selectionMode) {
                            _toggleSelectFolder(id);
                          } else {
                            ctl.navigateInto(id);
                          }
                        },
                        onEnterSelectionFolder: _enterSelectionModeFolder,
                        onFolderContext: (f, pos) =>
                            _showFolderContextMenu(context, ref, f, pos),
                        onOpenNote: (id) {
                          if (_selectionMode) {
                            _toggleSelectNote(id);
                          } else {
                            _openNote(id);
                          }
                        },
                        onEnterSelectionNote: _enterSelectionModeNote,
                        onNoteContext: (n, pos) =>
                            _showNoteContextMenu(context, ref, n, pos),
                        onToggleSelectNote: _toggleSelectNote,
                        onToggleSelectFolder: _toggleSelectFolder,
                        onRubberBandSelect: _setSelectionFromRubberBand,
                      ),
          ),
        ],
      ),
        ),
        if (_selectionMode && _selectedIds.isNotEmpty)
          _SelectionActionPanel(
            noteCount: _selectedNoteIds.length,
            folderCount: _selectedFolderIds.length,
            singleNote: _selectedNoteIds.length == 1 && _selectedFolderIds.isEmpty
                ? notes.where((n) => n.id == _selectedNoteIds.first).cast<NoteSummary?>().firstOrNull
                : null,
            singleFolder: _selectedFolderIds.length == 1 && _selectedNoteIds.isEmpty
                ? folders.where((f) => f.id == _selectedFolderIds.first).cast<Folder?>().firstOrNull
                : null,
            onMove: _selectedIds.isEmpty ? null : () async {
              final lib = ref.read(libraryProvider).value;
              final excludeIds = <String>{};
              if (lib != null) {
                for (final id in _selectedFolderIds) {
                  excludeIds.addAll(_allDescendantFolderIds(lib.folders, id));
                }
              }
              if (!context.mounted) return;
              final folderId = await _pickFolder(context, ref, excludeFolderIds: excludeIds);
              if (folderId != null && context.mounted) {
                final target = folderId == '__root__' ? null : folderId;
                await ctl.bulkMoveItems(_selectedNoteIds, _selectedFolderIds, target);
              }
              _exitSelectionMode();
            },
            onDelete: _selectedIds.isEmpty ? null : () async {
              final total = _selectedIds.length;
              final ok = await noteeConfirm(context,
                  title: '$total개 항목 삭제',
                  body: '선택한 항목이 모두 삭제됩니다.');
              if (!context.mounted) return;
              if (ok) {
                if (_selectedFolderIds.isNotEmpty) {
                  for (final id in _selectedFolderIds) {
                    await ctl.deleteFolder(id);
                  }
                }
                if (_selectedNoteIds.isNotEmpty) {
                  await ctl.bulkDelete(_selectedNoteIds);
                }
                _exitSelectionMode();
              }
            },
            onDuplicate: (_selectedFolderIds.isEmpty && _selectedNoteIds.isNotEmpty) ? () async {
              await ctl.bulkDuplicate(_selectedNoteIds);
              _exitSelectionMode();
            } : null,
            onRenameNote: (_selectedNoteIds.length == 1 && _selectedFolderIds.isEmpty)
                ? () async {
                    final n = notes.where((n) => n.id == _selectedNoteIds.first).cast<NoteSummary?>().firstOrNull;
                    if (n == null) return;
                    final name = await noteeAskName(context, title: '노트 이름 수정', initial: n.title, confirmLabel: '저장');
                    if (name != null && name.trim().isNotEmpty) {
                      await ctl.renameNotebook(n.id, name.trim());
                    }
                    _exitSelectionMode();
                  }
                : null,
            onFavoriteNote: (_selectedNoteIds.length == 1 && _selectedFolderIds.isEmpty)
                ? () async {
                    final n = notes.where((n) => n.id == _selectedNoteIds.first).cast<NoteSummary?>().firstOrNull;
                    if (n == null) return;
                    await ctl.toggleFavorite(n.id);
                    _exitSelectionMode();
                  }
                : null,
            onExportNote: (_selectedNoteIds.length == 1 && _selectedFolderIds.isEmpty)
                ? () async {
                    final n = notes.where((n) => n.id == _selectedNoteIds.first).cast<NoteSummary?>().firstOrNull;
                    if (n == null || !context.mounted) return;
                    await _executeNoteAction(context, ref, n, _NoteCtx.export);
                    _exitSelectionMode();
                  }
                : null,
            onHistoryNote: (_selectedNoteIds.length == 1 && _selectedFolderIds.isEmpty)
                ? () async {
                    final n = notes.where((n) => n.id == _selectedNoteIds.first).cast<NoteSummary?>().firstOrNull;
                    if (n == null || !context.mounted) return;
                    await _executeNoteAction(context, ref, n, _NoteCtx.history);
                    _exitSelectionMode();
                  }
                : null,
            onRenameFolder: (_selectedFolderIds.length == 1 && _selectedNoteIds.isEmpty)
                ? () async {
                    final f = folders.where((f) => f.id == _selectedFolderIds.first).cast<Folder?>().firstOrNull;
                    if (f == null) return;
                    final name = await noteeAskName(context, title: '폴더 이름 수정', initial: f.name, confirmLabel: '저장');
                    if (name != null && name.trim().isNotEmpty) {
                      await ctl.renameFolder(f.id, name.trim());
                    }
                    _exitSelectionMode();
                  }
                : null,
            onAppearanceFolder: (_selectedFolderIds.length == 1 && _selectedNoteIds.isEmpty)
                ? () async {
                    final f = folders.where((f) => f.id == _selectedFolderIds.first).cast<Folder?>().firstOrNull;
                    if (f == null || !context.mounted) return;
                    final result2 = await showDialog<(int, String)>(
                      context: context,
                      builder: (_) => _FolderAppearanceDialog(
                        initialColor: f.colorArgb,
                        initialIconKey: f.iconKey,
                      ),
                    );
                    if (result2 != null && context.mounted) {
                      await ref.read(libraryProvider.notifier)
                          .updateFolderAppearance(f.id, result2.$1, result2.$2);
                    }
                    _exitSelectionMode();
                  }
                : null,
          ),
      ]),
    );
  }
}

// ── Grid view ─────────────────────────────────────────────────────────
class _GridContent extends StatefulWidget {
  const _GridContent({
    required this.folders,
    required this.notes,
    required this.onOpenFolder,
    required this.onEnterSelectionFolder,
    required this.onOpenNote,
    required this.onEnterSelectionNote,
    required this.onToggleSelectNote,
    required this.onToggleSelectFolder,
    required this.onRubberBandSelect,
    required this.selectionMode,
    this.selectedNoteIds = const {},
    this.selectedFolderIds = const {},
    this.pendingNoteIds = const {},
    this.onFolderContext,
    this.onNoteContext,
  });
  final List<Folder> folders;
  final List<NoteSummary> notes;
  final Set<String> selectedNoteIds;
  final Set<String> selectedFolderIds;
  final Set<String> pendingNoteIds;
  final bool selectionMode;
  final void Function(Set<String> noteIds, Set<String> folderIds, Offset globalPos) onRubberBandSelect;
  final void Function(String) onOpenFolder;
  final void Function(String) onEnterSelectionFolder;
  final void Function(String) onOpenNote;
  final void Function(String) onEnterSelectionNote;
  final void Function(String id) onToggleSelectNote;
  final void Function(String id) onToggleSelectFolder;
  final void Function(Folder, Offset)? onFolderContext;
  final void Function(NoteSummary, Offset)? onNoteContext;

  @override
  State<_GridContent> createState() => _GridContentState();
}

class _GridContentState extends State<_GridContent> {
  Offset? _dragStart;
  Offset? _dragCurrent;
  Offset? _dragEndGlobal;
  final Map<String, GlobalKey> _itemKeys = {};

  void _ensureKeys() {
    for (final f in widget.folders) {
      _itemKeys.putIfAbsent(f.id, GlobalKey.new);
    }
    for (final n in widget.notes) {
      _itemKeys.putIfAbsent(n.id, GlobalKey.new);
    }
  }

  Rect? get _selectionRect {
    if (_dragStart == null || _dragCurrent == null) return null;
    return Rect.fromPoints(_dragStart!, _dragCurrent!);
  }

  void _onPanEnd() {
    final rect = _selectionRect;
    final endGlobal = _dragEndGlobal;
    if (rect != null && rect.size.longestSide > 6) {
      final renderBox = context.findRenderObject() as RenderBox?;
      if (renderBox != null) {
        final newNoteIds = <String>{};
        final newFolderIds = <String>{};
        for (final entry in _itemKeys.entries) {
          final key = entry.value;
          final ctx = key.currentContext;
          if (ctx == null) continue;
          final itemBox = ctx.findRenderObject() as RenderBox?;
          if (itemBox == null) continue;
          final itemOffset = itemBox.localToGlobal(Offset.zero);
          final itemRect = itemOffset & itemBox.size;
          final localItemRect = Rect.fromLTWH(
            itemRect.left - renderBox.localToGlobal(Offset.zero).dx,
            itemRect.top - renderBox.localToGlobal(Offset.zero).dy,
            itemRect.width,
            itemRect.height,
          );
          if (rect.overlaps(localItemRect)) {
            final isFolder = widget.folders.any((f) => f.id == entry.key);
            if (isFolder) {
              newFolderIds.add(entry.key);
            } else {
              newNoteIds.add(entry.key);
            }
          }
        }
        widget.onRubberBandSelect(
          newNoteIds, newFolderIds, endGlobal ?? Offset.zero);
      }
    }
    setState(() {
      _dragStart = null;
      _dragCurrent = null;
      _dragEndGlobal = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    _ensureKeys();
    final allItems = [
      ...widget.folders.map((f) => f.id),
      ...widget.notes.map((n) => n.id),
    ];
    _itemKeys.removeWhere((id, _) => !allItems.contains(id));

    final grid = CustomScrollView(
      slivers: [
        if (widget.folders.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.only(top: 8),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 120,
                mainAxisExtent: 120,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              delegate: SliverChildListDelegate([
                for (final f in widget.folders)
                  _SelectableWrapper(
                    key: _itemKeys[f.id],
                    id: f.id,
                    selected: widget.selectedFolderIds.contains(f.id),
                    onToggleSelect: widget.onToggleSelectFolder,
                    onEnterSelection: widget.onEnterSelectionFolder,
                    child: _FolderTile(
                      folder: f,
                      onOpen: () => widget.onOpenFolder(f.id),
                      onLongPress: null,
                      onContextMenu: widget.onFolderContext == null
                          ? null
                          : (pos) => widget.onFolderContext!(f, pos),
                    ),
                  ),
              ]),
            ),
          ),
        SliverPadding(
          padding: EdgeInsets.only(
            top: widget.folders.isNotEmpty ? 20 : 8,
            bottom: 72,
          ),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 200,
              mainAxisExtent: 300,
              crossAxisSpacing: 28,
              mainAxisSpacing: 28,
            ),
            delegate: SliverChildListDelegate([
              for (final n in widget.notes)
                _SelectableWrapper(
                  key: _itemKeys[n.id],
                  id: n.id,
                  selected: widget.selectedNoteIds.contains(n.id),
                  onToggleSelect: widget.onToggleSelectNote,
                  onEnterSelection: widget.onEnterSelectionNote,
                  child: _SyncingOverlay(
                    syncing: widget.pendingNoteIds.contains(n.id),
                    child: _NotebookCover(
                      note: n,
                      onTap: () => widget.onOpenNote(n.id),
                      onLongPress: null,
                      onContextMenu: widget.onNoteContext == null
                          ? null
                          : (pos) => widget.onNoteContext!(n, pos),
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ],
    );

    return Stack(children: [
      Listener(
        onPointerDown: (e) {
          if (e.kind == PointerDeviceKind.mouse && e.buttons == 1) {
            setState(() {
              _dragStart = e.localPosition;
              _dragCurrent = e.localPosition;
              _dragEndGlobal = e.position;
            });
          }
        },
        onPointerMove: (e) {
          if (_dragStart != null) {
            setState(() {
              _dragCurrent = e.localPosition;
              _dragEndGlobal = e.position;
            });
          }
        },
        onPointerUp: (_) => _onPanEnd(),
        onPointerCancel: (_) => setState(() {
          _dragStart = null;
          _dragCurrent = null;
          _dragEndGlobal = null;
        }),
        child: grid,
      ),
      if (_selectionRect != null)
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _RubberBandPainter(_selectionRect!),
            ),
          ),
        ),
    ]);
  }
}

// ── List / rows view ──────────────────────────────────────────────────
class _ListContent extends StatefulWidget {
  const _ListContent({
    required this.folders,
    required this.notes,
    required this.onOpenFolder,
    required this.onEnterSelectionFolder,
    required this.onOpenNote,
    required this.onEnterSelectionNote,
    required this.onToggleSelectNote,
    required this.onToggleSelectFolder,
    required this.onRubberBandSelect,
    required this.selectionMode,
    this.selectedNoteIds = const {},
    this.selectedFolderIds = const {},
    this.pendingNoteIds = const {},
    this.onFolderContext,
    this.onNoteContext,
  });
  final List<Folder> folders;
  final List<NoteSummary> notes;
  final Set<String> selectedNoteIds;
  final Set<String> selectedFolderIds;
  final Set<String> pendingNoteIds;
  final bool selectionMode;
  final void Function(Set<String> noteIds, Set<String> folderIds, Offset globalPos) onRubberBandSelect;
  final void Function(String) onOpenFolder;
  final void Function(String) onEnterSelectionFolder;
  final void Function(String) onOpenNote;
  final void Function(String) onEnterSelectionNote;
  final void Function(String id) onToggleSelectNote;
  final void Function(String id) onToggleSelectFolder;
  final void Function(Folder, Offset)? onFolderContext;
  final void Function(NoteSummary, Offset)? onNoteContext;

  @override
  State<_ListContent> createState() => _ListContentState();
}

class _ListContentState extends State<_ListContent> {
  Offset? _dragStart;
  Offset? _dragCurrent;
  Offset? _dragEndGlobal;
  final Map<String, GlobalKey> _itemKeys = {};

  void _ensureKeys() {
    for (final f in widget.folders) {
      _itemKeys.putIfAbsent(f.id, GlobalKey.new);
    }
    for (final n in widget.notes) {
      _itemKeys.putIfAbsent(n.id, GlobalKey.new);
    }
  }

  Rect? get _selectionRect {
    if (_dragStart == null || _dragCurrent == null) return null;
    return Rect.fromPoints(_dragStart!, _dragCurrent!);
  }

  void _onPanEnd() {
    final rect = _selectionRect;
    final endGlobal = _dragEndGlobal;
    if (rect != null && rect.size.longestSide > 6) {
      final renderBox = context.findRenderObject() as RenderBox?;
      if (renderBox != null) {
        final newNoteIds = <String>{};
        final newFolderIds = <String>{};
        for (final entry in _itemKeys.entries) {
          final key = entry.value;
          final ctx = key.currentContext;
          if (ctx == null) continue;
          final itemBox = ctx.findRenderObject() as RenderBox?;
          if (itemBox == null) continue;
          final itemOffset = itemBox.localToGlobal(Offset.zero);
          final itemRect = itemOffset & itemBox.size;
          final localItemRect = Rect.fromLTWH(
            itemRect.left - renderBox.localToGlobal(Offset.zero).dx,
            itemRect.top - renderBox.localToGlobal(Offset.zero).dy,
            itemRect.width,
            itemRect.height,
          );
          if (rect.overlaps(localItemRect)) {
            final isFolder = widget.folders.any((f) => f.id == entry.key);
            if (isFolder) {
              newFolderIds.add(entry.key);
            } else {
              newNoteIds.add(entry.key);
            }
          }
        }
        widget.onRubberBandSelect(
          newNoteIds, newFolderIds, endGlobal ?? Offset.zero);
      }
    }
    setState(() {
      _dragStart = null;
      _dragCurrent = null;
      _dragEndGlobal = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    _ensureKeys();
    final allItems = [
      ...widget.folders.map((f) => f.id),
      ...widget.notes.map((n) => n.id),
    ];
    _itemKeys.removeWhere((id, _) => !allItems.contains(id));

    final list = ListView(
      padding: const EdgeInsets.only(left: 16, right: 16, bottom: 72),
      children: [
        for (final f in widget.folders) ...[
          _SelectableWrapper(
            key: _itemKeys[f.id],
            id: f.id,
            selected: widget.selectedFolderIds.contains(f.id),
            onToggleSelect: widget.onToggleSelectFolder,
            onEnterSelection: widget.onEnterSelectionFolder,
            child: _FolderListTile(
              folder: f,
              onOpen: () => widget.onOpenFolder(f.id),
              onLongPress: null,
              onContextMenu: widget.onFolderContext == null
                  ? null
                  : (pos) => widget.onFolderContext!(f, pos),
            ),
          ),
          const _ListDivider(),
        ],
        for (final n in widget.notes) ...[
          _SelectableWrapper(
            key: _itemKeys[n.id],
            id: n.id,
            selected: widget.selectedNoteIds.contains(n.id),
            onToggleSelect: widget.onToggleSelectNote,
            onEnterSelection: widget.onEnterSelectionNote,
            child: _SyncingOverlay(
              syncing: widget.pendingNoteIds.contains(n.id),
              child: _NoteListTile(
                note: n,
                onTap: () => widget.onOpenNote(n.id),
                onLongPress: null,
                onContextMenu: widget.onNoteContext == null
                    ? null
                    : (pos) => widget.onNoteContext!(n, pos),
              ),
            ),
          ),
          const _ListDivider(),
        ],
      ],
    );

    return Stack(children: [
      Listener(
        onPointerDown: (e) {
          if (e.kind == PointerDeviceKind.mouse && e.buttons == 1) {
            setState(() {
              _dragStart = e.localPosition;
              _dragCurrent = e.localPosition;
              _dragEndGlobal = e.position;
            });
          }
        },
        onPointerMove: (e) {
          if (_dragStart != null) {
            setState(() {
              _dragCurrent = e.localPosition;
              _dragEndGlobal = e.position;
            });
          }
        },
        onPointerUp: (_) => _onPanEnd(),
        onPointerCancel: (_) => setState(() {
          _dragStart = null;
          _dragCurrent = null;
          _dragEndGlobal = null;
        }),
        child: list,
      ),
      if (_selectionRect != null)
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _RubberBandPainter(_selectionRect!),
            ),
          ),
        ),
    ]);
  }
}

class _RubberBandPainter extends CustomPainter {
  _RubberBandPainter(this.rect);
  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      rect,
      Paint()
        ..color = const Color(0xFF2563EB).withValues(alpha: 0.12)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..color = const Color(0xFF2563EB).withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_RubberBandPainter old) => old.rect != rect;
}

class _SyncingOverlay extends StatelessWidget {
  const _SyncingOverlay({required this.syncing, required this.child});
  final bool syncing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!syncing) return child;
    return Stack(children: [
      Opacity(opacity: 0.55, child: child),
      Positioned.fill(
        child: IgnorePointer(
          child: Center(
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}

class _ListDivider extends StatelessWidget {
  const _ListDivider();
  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    return Container(height: 0.5, color: t.tbBorder);
  }
}

class _SelectableWrapper extends StatelessWidget {
  const _SelectableWrapper({
    super.key,
    required this.id,
    required this.selected,
    required this.onToggleSelect,
    required this.onEnterSelection,
    required this.child,
  });
  final String id;
  final bool selected;
  final void Function(String id) onToggleSelect;
  final void Function(String id) onEnterSelection;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        if (HardwareKeyboard.instance.isMetaPressed ||
            HardwareKeyboard.instance.isShiftPressed) {
          onToggleSelect(id);
        }
      },
      onLongPress: () => onEnterSelection(id),
      child: Stack(children: [
        child,
        if (selected)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF2563EB).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: const Color(0xFF2563EB),
                    width: 2,
                  ),
                ),
                child: Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: const BoxDecoration(
                        color: Color(0xFF2563EB),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.check,
                        size: 13,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

class _MultiSelectBar extends StatelessWidget {
  const _MultiSelectBar({
    super.key,
    required this.noteCount,
    required this.folderCount,
    required this.totalVisible,
    required this.onClear,
    required this.onSelectAll,
  });

  final int noteCount;
  final int folderCount;
  final int totalVisible;
  final VoidCallback onClear;
  final VoidCallback onSelectAll;

  int get _count => noteCount + folderCount;

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final allSelected = _count >= totalVisible;
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: t.toolbar,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.tbBorder, width: 0.5),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        IconButton(
          icon: const Icon(Icons.close, size: 16),
          onPressed: onClear,
          color: t.inkDim,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          tooltip: '선택 해제',
        ),
        const SizedBox(width: 8),
        Text(
          '$_count개 선택됨',
          style: TextStyle(
            fontFamily: 'Inter Tight',
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: t.ink,
          ),
        ),
        const Spacer(),
        if (!allSelected)
          TextButton(
            onPressed: onSelectAll,
            style: TextButton.styleFrom(
              textStyle: const TextStyle(fontFamily: 'Inter Tight', fontSize: 12),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              foregroundColor: t.inkDim,
            ),
            child: const Text('모두 선택'),
          ),
      ]),
    );
  }
}

class _FolderListTile extends StatelessWidget {
  const _FolderListTile({
    required this.folder,
    required this.onOpen,
    this.onLongPress,
    this.onContextMenu,
  });
  final Folder folder;
  final VoidCallback onOpen;
  final VoidCallback? onLongPress;
  final void Function(Offset globalPos)? onContextMenu;

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final color = Color(folder.colorArgb);
    final icon = _folderIconFor(folder.iconKey);
    return InkWell(
      onTap: onOpen,
      onLongPress: onLongPress,
      onSecondaryTapDown: onContextMenu == null
          ? null
          : (d) => onContextMenu!.call(d.globalPosition),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              folder.name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: t.ink,
              ),
            ),
          ),
          Text(
            'Folder',
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 10,
              color: t.inkFaint,
            ),
          ),
          const SizedBox(width: 4),
          Icon(Icons.chevron_right_rounded, size: 16, color: t.inkFaint),
        ]),
      ),
    );
  }
}

class _NoteListTile extends StatelessWidget {
  const _NoteListTile({
    required this.note,
    required this.onTap,
    this.onLongPress,
    this.onContextMenu,
  });
  final NoteSummary note;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final void Function(Offset globalPos)? onContextMenu;

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final spec = note.firstPageSpec;
    final pageAspect = (spec != null && spec.heightPt > 0)
        ? spec.widthPt / spec.heightPt
        : 44 / 60;

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTapDown: onContextMenu == null
          ? null
          : (d) => onContextMenu!.call(d.globalPosition),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          SizedBox(
            height: 60,
            child: AspectRatio(
              aspectRatio: pageAspect,
              child: Container(
                decoration: BoxDecoration(
                  color: t.page,
                  borderRadius: BorderRadius.circular(4),
                  boxShadow: [
                    BoxShadow(color: t.pageEdge, spreadRadius: 0.5),
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.10),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: _CoverContent(note: note),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Text(
                      note.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: t.ink,
                      ),
                    ),
                  ),
                  if (note.isFavorite)
                    const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: Icon(Icons.star_rounded,
                          size: 13, color: Colors.amber),
                    ),
                ]),
                const SizedBox(height: 3),
                Text(
                  '${note.pageCount} pages · ${_relTime(note.updatedAt)}',
                  style: TextStyle(fontSize: 11.5, color: t.inkDim),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _relTime(note.updatedAt),
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 10,
              color: t.inkFaint,
            ),
          ),
        ]),
      ),
    );
  }
}

class _Breadcrumb extends ConsumerWidget {
  const _Breadcrumb({required this.state});
  final LibraryState state;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = NoteeProvider.of(context).tokens;
    final ctl = ref.read(libraryProvider.notifier);
    final crumbs = [null, ...state.breadcrumb().map((f) => f.id)];
    final names = ['Library', ...state.breadcrumb().map((f) => f.name)];
    final isInFolder = crumbs.length > 1;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        if (isInFolder) ...[
          InkWell(
            onTap: ctl.navigateUp,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: NoteeIconWidget(NoteeIcon.chev, size: 11, color: t.inkDim),
            ),
          ),
          const SizedBox(width: 4),
        ],
        for (var i = 0; i < crumbs.length; i++) ...[
          InkWell(
            onTap: () {
              if (crumbs[i] == null) {
                ctl.navigateRoot();
              } else {
                ctl.navigateInto(crumbs[i]!);
              }
            },
            child: Text(
              names[i],
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 11,
                color: i == crumbs.length - 1 ? t.ink : t.inkDim,
                fontWeight: i == crumbs.length - 1
                    ? FontWeight.w600
                    : FontWeight.normal,
              ),
            ),
          ),
          if (i != crumbs.length - 1) ...[
            const SizedBox(width: 8),
            NoteeIconWidget(NoteeIcon.chev, size: 9, color: t.inkFaint),
            const SizedBox(width: 8),
          ],
        ],
      ]),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onCreateFolder});
  final Future<void> Function() onCreateFolder;
  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          NoteeIconWidget(NoteeIcon.folder, size: 56, color: t.inkFaint),
          const SizedBox(height: 14),
          Text(
            'This folder is empty.',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: t.ink),
          ),
          const SizedBox(height: 6),
          Text(
            'Use “New notebook” above, or create a folder to get organized.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: t.inkDim),
          ),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: onCreateFolder,
            icon: const NoteeIconWidget(NoteeIcon.folder, size: 14),
            label: const Text('New folder'),
          ),
        ]),
      ),
    );
  }
}

// ── Folder card (back tab + body + paper peek) ─────────────────────────
class _FolderTile extends StatelessWidget {
  const _FolderTile({
    required this.folder,
    required this.onOpen,
    this.onLongPress,
    this.onContextMenu,
  });
  final Folder folder;
  final VoidCallback onOpen;
  final VoidCallback? onLongPress;
  final void Function(Offset globalPos)? onContextMenu;

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final color = Color(folder.colorArgb);
    return InkWell(
      onTap: onOpen,
      onLongPress: onLongPress,
      onSecondaryTapDown: onContextMenu == null
          ? null
          : (d) => onContextMenu!.call(d.globalPosition),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: AspectRatio(
                aspectRatio: 1.3,
                child: LayoutBuilder(builder: (context, c) {
                  final iconData = _folderIconFor(folder.iconKey);
                  final iconSize = c.maxWidth * 0.28;
                  return Stack(children: [
                    Positioned(
                      left: 12,
                      top: 0,
                      child: Container(
                        width: 70,
                        height: 14,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(4),
                            topRight: Radius.circular(8),
                          ),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      top: 10,
                      child: Container(
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(2),
                            topRight: Radius.circular(8),
                            bottomLeft: Radius.circular(8),
                            bottomRight: Radius.circular(8),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.16),
                              blurRadius: 16,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 10,
                      bottom: 0,
                      child: Center(
                        child: Icon(
                          iconData,
                          size: iconSize,
                          color: Colors.white.withValues(alpha: 0.85),
                        ),
                      ),
                    ),
                  ]);
                }),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              folder.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: t.ink,
                  ),
            ),
            const SizedBox(height: 2),
            Text(
              'Folder',
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 10,
                color: t.inkFaint,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Right-click context menus ─────────────────────────────────────────
enum _NoteCtx { rename, duplicate, move, favorite, export, history, delete }
enum _FolderCtx { rename, changeAppearance, delete }

Future<void> _showNoteContextMenu(
    BuildContext context, WidgetRef ref, NoteSummary n, Offset pos) async {
  final result = await showNoteeMenuAt<_NoteCtx>(
    context,
    position: pos,
    items: [
      const NoteeMenuItem(
        label: '이름 수정',
        value: _NoteCtx.rename,
        icon: Icon(Icons.edit_outlined, size: 16),
      ),
      const NoteeMenuItem(
        label: '복제',
        value: _NoteCtx.duplicate,
        icon: Icon(Icons.copy_rounded, size: 16),
      ),
      const NoteeMenuItem(
        label: '이동',
        value: _NoteCtx.move,
        icon: Icon(Icons.drive_file_move_outline, size: 16),
      ),
      NoteeMenuItem(
        label: n.isFavorite ? '즐겨찾기 해제' : '즐겨찾기 추가',
        value: _NoteCtx.favorite,
        icon: Icon(
          n.isFavorite ? Icons.star_rounded : Icons.star_border_rounded,
          size: 16,
        ),
      ),
      const NoteeMenuItem(
        label: '내보내기',
        value: _NoteCtx.export,
        icon: Icon(Icons.ios_share_rounded, size: 16),
      ),
      const NoteeMenuItem(
        label: '버전 기록',
        value: _NoteCtx.history,
        icon: Icon(Icons.history_rounded, size: 16),
      ),
      const NoteeMenuItem.separator(),
      const NoteeMenuItem(
        label: '삭제',
        value: _NoteCtx.delete,
        icon: Icon(Icons.delete_outline, size: 16),
        danger: true,
      ),
    ],
  );
  if (!context.mounted || result == null) return;
  await _executeNoteAction(context, ref, n, result);
}

Future<void> _executeNoteAction(
    BuildContext context, WidgetRef ref, NoteSummary n, _NoteCtx action) async {
  if (!context.mounted) return;
  final ctl = ref.read(libraryProvider.notifier);
  switch (action) {
    case _NoteCtx.rename:
      final name = await noteeAskName(
        context,
        title: '노트 이름 수정',
        initial: n.title,
        confirmLabel: '저장',
      );
      if (name != null && name.trim().isNotEmpty) {
        await ctl.renameNotebook(n.id, name.trim());
      }
    case _NoteCtx.duplicate:
      await ctl.duplicateNotebook(n.id);
    case _NoteCtx.move:
      if (!context.mounted) return;
      final folderId = await _pickFolder(context, ref, currentFolderId: n.folderId);
      if (folderId != null) {
        final target = folderId == '__root__' ? null : folderId;
        await ctl.moveNotebook(n.id, target);
      }
    case _NoteCtx.favorite:
      await ctl.toggleFavorite(n.id);
    case _NoteCtx.export:
      if (!context.mounted) return;
      final repo = ref.read(repositoryProvider);
      final nbState = await repo.loadByNoteId(n.id);
      if (nbState == null || !context.mounted) return;
      final path = await ExportDialog.show(context, nbState, suggestedName: n.title);
      if (path != null && context.mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(
            content: Text('저장됨: $path'),
            duration: const Duration(seconds: 4),
            action: SnackBarAction(
              label: '닫기',
              onPressed: () => ScaffoldMessenger.of(context).hideCurrentSnackBar(),
            ),
          ));
      }
    case _NoteCtx.history:
      if (!context.mounted) return;
      final auth = ref.read(authProvider).value;
      if (auth == null || !auth.isLoggedIn) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('버전 기록은 로그인 후에 사용할 수 있습니다.')),
        );
        return;
      }
      final historyClient = apiFor(auth, onTokens: (t) {
        ref.read(authProvider.notifier).updateTokens(t);
      }, onLogout: () {
        ref.read(authProvider.notifier).clearTokens();
      });
      final restored = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => HistoryScreen(noteId: n.id, client: historyClient),
        ),
      );
      if (restored == true && context.mounted) {
        try {
          await ref.read(syncActionsProvider).syncNow();
          await ref.read(libraryProvider.notifier).refresh();
        } catch (_) {}
      }
    case _NoteCtx.delete:
      if (!context.mounted) return;
      final ok = await noteeConfirm(context,
          title: '"${n.title}" 삭제',
          body: '모든 페이지와 스트로크가 삭제됩니다.');
      if (ok) await ctl.deleteNotebook(n.id);
  }
}

Future<void> _showFolderContextMenu(
    BuildContext context, WidgetRef ref, Folder f, Offset pos) async {
  final result = await showNoteeMenuAt<_FolderCtx>(
    context,
    position: pos,
    items: const [
      NoteeMenuItem(
        label: '이름 수정',
        value: _FolderCtx.rename,
        icon: Icon(Icons.edit_outlined, size: 16),
      ),
      NoteeMenuItem(
        label: '색상/아이콘 변경',
        value: _FolderCtx.changeAppearance,
        icon: Icon(Icons.color_lens_outlined, size: 16),
      ),
      NoteeMenuItem.separator(),
      NoteeMenuItem(
        label: '삭제',
        value: _FolderCtx.delete,
        icon: Icon(Icons.delete_outline, size: 16),
        danger: true,
      ),
    ],
  );
  if (!context.mounted || result == null) return;
  final ctl = ref.read(libraryProvider.notifier);
  switch (result) {
    case _FolderCtx.rename:
      final name = await noteeAskName(
        context,
        title: '폴더 이름 수정',
        initial: f.name,
        confirmLabel: '저장',
      );
      if (name != null && name.trim().isNotEmpty) {
        await ctl.renameFolder(f.id, name.trim());
      }
    case _FolderCtx.changeAppearance:
      if (!context.mounted) return;
      final result2 = await showDialog<(int, String)>(
        context: context,
        builder: (_) => _FolderAppearanceDialog(
          initialColor: f.colorArgb,
          initialIconKey: f.iconKey,
        ),
      );
      if (result2 != null) {
        await ctl.updateFolderAppearance(f.id, result2.$1, result2.$2);
      }
    case _FolderCtx.delete:
      if (!context.mounted) return;
      final ok = await noteeConfirm(context,
          title: '"${f.name}" 삭제',
          body: '폴더, 하위 폴더, 모든 노트북이 삭제됩니다.');
      if (ok) await ctl.deleteFolder(f.id);
  }
}

Future<String?> _pickFolder(
  BuildContext context,
  WidgetRef ref, {
  String? currentFolderId,
  Set<String> excludeFolderIds = const {},
}) async {
  final lib = ref.read(libraryProvider).value;
  if (lib == null) return null;

  return showDialog<String>(
    context: context,
    builder: (_) => _FolderPickerDialog(
      folders: lib.folders,
      currentFolderId: currentFolderId,
      excludeFolderIds: excludeFolderIds,
    ),
  );
}

// ── Floating selection action panel ─────────────────────────────
class _SelectionActionPanel extends StatelessWidget {
  const _SelectionActionPanel({
    super.key,
    required this.noteCount,
    required this.folderCount,
    this.singleNote,
    this.singleFolder,
    required this.onMove,
    required this.onDelete,
    this.onDuplicate,
    this.onRenameNote,
    this.onFavoriteNote,
    this.onExportNote,
    this.onHistoryNote,
    this.onRenameFolder,
    this.onAppearanceFolder,
  });

  final int noteCount;
  final int folderCount;
  final NoteSummary? singleNote;
  final Folder? singleFolder;
  final VoidCallback? onMove;
  final VoidCallback? onDelete;
  final VoidCallback? onDuplicate;
  final VoidCallback? onRenameNote;
  final VoidCallback? onFavoriteNote;
  final VoidCallback? onExportNote;
  final VoidCallback? onHistoryNote;
  final VoidCallback? onRenameFolder;
  final VoidCallback? onAppearanceFolder;

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final n = singleNote;
    final f = singleFolder;

    final btns = <_ActionBtn>[];

    if (n != null) {
      btns.addAll([
        _ActionBtn(icon: Icons.edit_outlined, label: '이름수정', color: t.ink, onTap: onRenameNote),
        _ActionBtn(
          icon: n.isFavorite ? Icons.star_rounded : Icons.star_border_rounded,
          label: n.isFavorite ? '즐겨찾기\n해제' : '즐겨찾기',
          color: n.isFavorite ? const Color(0xFFF59E0B) : t.ink,
          onTap: onFavoriteNote,
        ),
        _ActionBtn(icon: Icons.copy_rounded, label: '복제', color: t.ink, onTap: onDuplicate),
        _ActionBtn(icon: Icons.drive_file_move_outline, label: '이동', color: t.ink, onTap: onMove),
        _ActionBtn(icon: Icons.ios_share_rounded, label: '내보내기', color: t.ink, onTap: onExportNote),
        _ActionBtn(icon: Icons.history_rounded, label: '버전기록', color: t.ink, onTap: onHistoryNote),
        _ActionBtn(icon: Icons.delete_outline, label: '삭제', color: Colors.red.shade600, onTap: onDelete),
      ]);
    } else if (f != null) {
      btns.addAll([
        _ActionBtn(icon: Icons.edit_outlined, label: '이름수정', color: t.ink, onTap: onRenameFolder),
        _ActionBtn(icon: Icons.color_lens_outlined, label: '색상/아이콘', color: t.ink, onTap: onAppearanceFolder),
        _ActionBtn(icon: Icons.drive_file_move_outline, label: '이동', color: t.ink, onTap: onMove),
        _ActionBtn(icon: Icons.delete_outline, label: '삭제', color: Colors.red.shade600, onTap: onDelete),
      ]);
    } else {
      if (noteCount > 0 && folderCount == 0) {
        btns.add(_ActionBtn(icon: Icons.copy_rounded, label: '복제', color: t.ink, onTap: onDuplicate));
      }
      btns.addAll([
        _ActionBtn(icon: Icons.drive_file_move_outline, label: '이동', color: t.ink, onTap: onMove),
        _ActionBtn(icon: Icons.delete_outline, label: '삭제', color: Colors.red.shade600, onTap: onDelete),
      ]);
    }

    return Positioned(
      bottom: 16,
      right: 16,
      child: SafeArea(
        child: Material(
          color: t.toolbar,
          borderRadius: BorderRadius.circular(16),
          elevation: 12,
          shadowColor: Colors.black38,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(mainAxisSize: MainAxisSize.min, children: btns),
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionBtn extends StatelessWidget {
  const _ActionBtn({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 56,
        height: 56,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: onTap != null ? color : color.withValues(alpha: 0.4)),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: onTap != null ? color : color.withValues(alpha: 0.4),
                fontFamily: 'Inter Tight',
                height: 1.2,
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
            ),
          ],
        ),
      ),
    );
  }
}
