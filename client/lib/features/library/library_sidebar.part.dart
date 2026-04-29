part of 'library_screen.dart';

// ── Sidebar ─────────────────────────────────────────────────────────────
class _Sidebar extends ConsumerWidget {
  const _Sidebar({
    required this.state,
    required this.filter,
    required this.onFilterChanged,
  });
  final LibraryState state;
  final _LibFilter filter;
  final void Function(_LibFilter) onFilterChanged;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = NoteeProvider.of(context).tokens;
    final ctl = ref.read(libraryProvider.notifier);
    return Container(
      color: t.toolbar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
              children: [
                _SidebarItem(
                  icon: NoteeIcon.home,
                  label: 'All notebooks',
                  count: state.notes.length,
                  active: filter == _LibFilter.all && state.currentFolderId == null,
                  onTap: () {
                    onFilterChanged(_LibFilter.all);
                    ctl.navigateRoot();
                  },
                ),
                _SidebarItem(
                  icon: NoteeIcon.star,
                  label: 'Favorites',
                  count: state.notes.where((n) => n.isFavorite).length,
                  active: filter == _LibFilter.favorites,
                  onTap: () => onFilterChanged(_LibFilter.favorites),
                ),
                _SidebarItem(
                  icon: NoteeIcon.page,
                  label: 'Recent notes',
                  count: state.notes.length,
                  active: filter == _LibFilter.recent,
                  onTap: () => onFilterChanged(_LibFilter.recent),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(children: [
                    const Expanded(child: _Eyebrow(text: 'Folders')),
                    GestureDetector(
                      onTap: () async {
                        final name = await noteeAskName(context, title: 'New folder');
                        if (name != null && name.isNotEmpty) {
                          await ctl.createFolder(name);
                        }
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: NoteeIconWidget(NoteeIcon.plus,
                            size: 12, color: t.inkFaint),
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 4),
                _FolderTree(
                  folders: state.folders,
                  currentFolderId: state.currentFolderId,
                  onSelect: ctl.navigateInto,
                ),
              ],
            ),
          ),
          Container(height: 0.5, color: t.tbBorder),
          const _SettingsButton(),
        ],
      ),
    );
  }
}

// ── Menu button ──────────────────────────────────────────────────────────
class _SettingsButton extends ConsumerWidget {
  const _SettingsButton();

  static final _anchorKey = GlobalKey();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = NoteeProvider.of(context).tokens;
    final bottomPad = MediaQuery.of(context).padding.bottom;
    return GestureDetector(
      onTap: () => _openMenu(context, ref),
      child: Container(
        padding: EdgeInsets.fromLTRB(22, 12, 22, 12 + bottomPad),
        child: Row(
          key: _anchorKey,
          children: [
            SizedBox(
              height: 16,
              child: Center(
                child: NoteeIconWidget(NoteeIcon.rows, size: 14, color: t.inkDim),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'Menu',
              style: TextStyle(
                fontSize: 13,
                height: 1.0,
                fontWeight: FontWeight.w500,
                color: t.inkDim,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openMenu(BuildContext context, WidgetRef ref) {
    showNoteePopover<void>(
      context,
      anchorKey: _anchorKey,
      placement: NoteePopoverPlacement.above,
      maxWidth: 220,
      builder: (ctx) => _MenuPopover(ref: ref),
    );
  }
}

// ── Menu popover ──────────────────────────────────────────────────────────
class _MenuPopover extends StatelessWidget {
  const _MenuPopover({required this.ref});
  final WidgetRef ref;

  static final _themeRowKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final current = ref.watch(surfaceProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _MenuRow(
            icon: NoteeIcon.plus,
            label: '새 창',
            onTap: () {
              ref.read(noteLockServiceProvider).openNewWindow();
              Navigator.of(context).pop();
            },
            t: t,
          ),
          _MenuRow(
            key: _themeRowKey,
            icon: NoteeIcon.gear,
            label: 'Theme',
            trailing: NoteeIconWidget(NoteeIcon.chev, size: 12, color: t.inkFaint),
            onTap: () => _openThemePopover(context, current, t),
            t: t,
          ),
          if (Platform.isMacOS || Platform.isWindows) ...[
            _MenuRow(
              icon: NoteeIcon.folder,
              label: '데이터 폴더 열기',
              onTap: () async {
                Navigator.of(context).pop();
                final dir = await getApplicationDocumentsDirectory();
                if (Platform.isMacOS) {
                  await Process.run('open', [dir.path]);
                } else {
                  await Process.run('explorer', [dir.path]);
                }
              },
              t: t,
            ),
            _MenuRow(
              icon: NoteeIcon.folder,
              label: '썸네일 폴더 열기',
              onTap: () async {
                Navigator.of(context).pop();
                await ThumbnailService.instance.openCacheFolder();
              },
              t: t,
            ),
          ],
          _MenuRow(
            icon: NoteeIcon.trash,
            label: '썸네일 캐시 삭제',
            onTap: () async {
              Navigator.of(context).pop();
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('썸네일 캐시 삭제'),
                  content: const Text('모든 썸네일을 삭제합니다. Library를 다시 열면 자동으로 재생성됩니다.'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: const Text('취소'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: const Text('삭제'),
                    ),
                  ],
                ),
              );
              if (confirmed == true) {
                await ThumbnailService.instance.clearAll();
                ref.read(libraryProvider.notifier).refresh();
              }
            },
            t: t,
          ),
          _MenuRow(
            icon: NoteeIcon.rows,
            label: 'PDF 큐 보기',
            onTap: () {
              Navigator.of(context).pop();
              showDialog<void>(
                context: context,
                builder: (_) => const _PdfQueueDialog(),
              );
            },
            t: t,
          ),
          _MenuRow(
            icon: NoteeIcon.share,
            label: '동기화 큐 보기',
            onTap: () {
              Navigator.of(context).pop();
              showDialog<void>(
                context: context,
                builder: (_) => const _SyncQueueDialog(),
              );
            },
            t: t,
          ),
          _MenuRow(
            icon: NoteeIcon.gear,
            label: 'PDF 렌더 스레드 수',
            onTap: () async {
              Navigator.of(context).pop();
              await showDialog<void>(
                context: context,
                builder: (_) => const _PdfThreadsDialog(),
              );
            },
            t: t,
          ),
        ],
      ),
    );
  }

  void _openThemePopover(BuildContext context, NoteeSurface current, NoteeTokens t) {
    final rowBox = _themeRowKey.currentContext?.findRenderObject() as RenderBox?;
    final btnBox = _SettingsButton._anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (rowBox == null || btnBox == null) return;
    final rowOrigin = rowBox.localToGlobal(Offset.zero);
    final btnOrigin = btnBox.localToGlobal(Offset.zero);
    final btnSize = btnBox.size;
    showNoteePopoverAt<void>(
      context,
      position: Offset(rowOrigin.dx + rowBox.size.width + 6, btnOrigin.dy),
      anchorSize: btnSize,
      placement: NoteePopoverPlacement.above,
      offset: 6,
      maxWidth: 180,
      builder: (ctx) => _ThemeSubMenu(current: current, ref: ref),
    );
  }
}

class _ThemeSubMenu extends StatelessWidget {
  const _ThemeSubMenu({required this.current, required this.ref});
  final NoteeSurface current;
  final WidgetRef ref;

  static const _surfaces = [
    (NoteeSurface.paper, 'Paper', Color(0xFFF4EDE0)),
    (NoteeSurface.white, 'White', Color(0xFFFFFFFF)),
    (NoteeSurface.sepia, 'Sepia', Color(0xFFE8D9B8)),
    (NoteeSurface.dark, 'Dark', Color(0xFF1C1C1E)),
  ];

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (surface, label, swatch) in _surfaces)
            _ThemeRow(
              surface: surface,
              label: label,
              swatch: swatch,
              selected: current == surface,
              onTap: () {
                ref.read(surfaceProvider.notifier).state = surface;
                Navigator.of(context)
                  ..pop()
                  ..pop();
              },
              t: t,
            ),
        ],
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    required this.t,
    this.trailing,
  });
  final NoteeIcon icon;
  final String label;
  final VoidCallback onTap;
  final NoteeTokens t;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        color: Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        child: Row(
          children: [
            NoteeIconWidget(icon, size: 14, color: t.inkDim),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(fontSize: 13, color: t.ink, fontWeight: FontWeight.w500),
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

class _ThemeRow extends StatelessWidget {
  const _ThemeRow({
    required this.surface,
    required this.label,
    required this.swatch,
    required this.selected,
    required this.onTap,
    required this.t,
  });
  final NoteeSurface surface;
  final String label;
  final Color swatch;
  final bool selected;
  final VoidCallback onTap;
  final NoteeTokens t;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        color: Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: swatch,
                shape: BoxShape.circle,
                border: Border.all(color: t.rule, width: 0.8),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? t.ink : t.inkDim,
                ),
              ),
            ),
            if (selected)
              NoteeIconWidget(NoteeIcon.check, size: 13, color: t.accent),
          ],
        ),
      ),
    );
  }
}

class _Eyebrow extends StatelessWidget {
  const _Eyebrow({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
      child: Text(text.toUpperCase(), style: noteeSectionEyebrow(t)),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.icon,
    required this.label,
    required this.count,
    required this.active,
    required this.onTap,
  });
  final NoteeIcon icon;
  final String label;
  final int count;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active ? t.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: active ? t.accent.withValues(alpha: 0.6) : Colors.transparent,
            width: 0.5,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              height: 16,
              child: Center(
                child: NoteeIconWidget(icon,
                    size: 14, color: active ? t.accent : t.inkDim),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.0,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  color: t.ink,
                ),
              ),
            ),
            if (count > 0)
              Text('$count',
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 10,
                    height: 1.0,
                    color: t.inkFaint,
                  )),
          ],
        ),
      ),
    );
  }
}

class _FolderTree extends StatefulWidget {
  const _FolderTree({
    required this.folders,
    required this.currentFolderId,
    required this.onSelect,
  });
  final List<Folder> folders;
  final String? currentFolderId;
  final void Function(String) onSelect;
  @override
  State<_FolderTree> createState() => _FolderTreeState();
}

class _FolderTreeState extends State<_FolderTree> {
  final Set<String> _open = <String>{};

  List<Folder> _childrenOf(String? parentId) =>
      widget.folders.where((f) => f.parentId == parentId).toList()
        ..sort((a, b) => a.name.compareTo(b.name));

  Widget _node(Folder f, int depth) {
    final t = NoteeProvider.of(context).tokens;
    final kids = _childrenOf(f.id);
    final hasKids = kids.isNotEmpty;
    final isOpen = _open.contains(f.id);
    final isSel = widget.currentFolderId == f.id;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () {
          widget.onSelect(f.id);
          if (hasKids) {
            setState(() {
              if (isOpen) {
                _open.remove(f.id);
              } else {
                _open.add(f.id);
              }
            });
          }
        },
        child: Container(
          padding: EdgeInsets.fromLTRB(8 + depth * 14, 4, 8, 4),
          decoration: BoxDecoration(
            color: isSel ? t.accentSoft : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: isSel
                ? Border.all(color: t.accent.withValues(alpha: 0.6), width: 0.5)
                : null,
          ),
          child: Row(children: [
            SizedBox(
              width: 12,
              child: hasKids
                  ? Transform.rotate(
                      angle: isOpen ? 1.5708 : 0,
                      child: NoteeIconWidget(NoteeIcon.chev,
                          size: 9, color: t.inkDim),
                    )
                  : null,
            ),
            const SizedBox(width: 4),
            Icon(_folderIconFor(f.iconKey),
                size: 14,
                color: isSel ? t.accent : Color(f.colorArgb)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                f.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSel ? FontWeight.w600 : FontWeight.w500,
                  color: t.ink,
                ),
              ),
            ),
          ]),
        ),
      ),
      if (hasKids && isOpen)
        for (final c in kids) _node(c, depth + 1),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final roots = _childrenOf(null);
    if (roots.isEmpty) {
      final t = NoteeProvider.of(context).tokens;
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
        child: Text(
          'No folders yet',
          style: TextStyle(fontSize: 11.5, color: t.inkFaint),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final f in roots) _node(f, 0)],
    );
  }
}
