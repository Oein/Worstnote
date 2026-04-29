// LibraryScreen — folder + notebook browse, styled to the design handoff.
// Layout (desktop / iPad):
//   ┌─────────────── top bar (Notee logo · search · grid/rows · New) ───────────────┐
//   │ side rail (Library · All notebooks · Favorites · Recent · folder tree)        │
//   │  ────────────────────────────────────────────────────────────                  │
//   │  breadcrumb · "Folder name" · n folders · m notebooks                          │
//   │  grid: folder cards (back-tab + body + paper peek) + notebook covers          │
//   └────────────────────────────────────────────────────────────────────────────────┘
//
// Compact widths (< 720px) collapse the sidebar into an icon strip.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:path_provider/path_provider.dart';

import '../../data/db/repository.dart';
import '../../domain/folder.dart';
import '../../domain/page_object.dart';
import '../../domain/page_spec.dart';
import '../../features/canvas/painters/background_painter.dart';
import '../../features/canvas/widgets/background_image_layer.dart';
import '../../features/export/export_dialog.dart';
import '../../features/import/goodnotes_importer.dart';
import '../../features/import/notee_importer.dart';
import '../../features/import/pdf_importer.dart';
import '../../theme/notee_dialog.dart';
import '../../theme/notee_icons.dart';
import '../../theme/notee_popover.dart';
import '../../theme/notee_theme.dart';
import '../../main.dart' show surfaceProvider;
import 'thumbnail_service.dart';
import '../auth/auth_state.dart';
import '../auth/login_dialog.dart';
import '../lock/note_lock_service.dart';
import '../notebook/notebook_state.dart';
import '../sync/sync_state.dart';
import 'library_state.dart';

enum _LibAction { newNotebook, newFolder, importPdf, importGoodNotes, importNotee }

enum _SortOrder { updatedAt, createdAt, name }

enum _LibFilter { all, favorites, recent }

extension _SortOrderLabel on _SortOrder {
  String get label {
    switch (this) {
      case _SortOrder.updatedAt: return '수정일';
      case _SortOrder.createdAt: return '생성일';
      case _SortOrder.name:      return '이름';
    }
  }
}

const _folderPalette = <Color>[
  Color(0xFFC9B78A),
  Color(0xFF9CA97A),
  Color(0xFFB89070),
  Color(0xFFB7A4C9),
  Color(0xFF7AA4B0),
];

// Legacy palette kept for reference; folders now use their stored colorArgb.
// ignore: unused_element
Color _folderColorFor(String id) {
  return _folderPalette[id.hashCode.abs() % _folderPalette.length];
}

const _folderIconMap = <String, IconData>{
  'folder': Icons.folder_rounded,
  'star': Icons.star_rounded,
  'book': Icons.menu_book_rounded,
  'work': Icons.work_rounded,
  'home': Icons.home_rounded,
  'school': Icons.school_rounded,
  'science': Icons.science_rounded,
  'palette': Icons.palette_rounded,
  'music': Icons.music_note_rounded,
  'sport': Icons.sports_rounded,
  'travel': Icons.flight_rounded,
  'code': Icons.code_rounded,
};

IconData _folderIconFor(String iconKey) =>
    _folderIconMap[iconKey] ?? Icons.folder_rounded;

// DFS walk returning each folder with its nesting depth.
List<(Folder, int)> _buildFolderTree(
    List<Folder> folders, String? parentId, int depth) {
  final result = <(Folder, int)>[];
  for (final f in folders.where((f) => f.parentId == parentId)) {
    result.add((f, depth));
    result.addAll(_buildFolderTree(folders, f.id, depth + 1));
  }
  return result;
}

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final libAsync = ref.watch(libraryProvider);
    final t = NoteeProvider.of(context).tokens;
    return libAsync.when(
      loading: () => Scaffold(
        backgroundColor: t.bg,
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        backgroundColor: t.bg,
        body: Center(child: Text('Library error: $e')),
      ),
      data: (state) => _LibraryView(state: state),
    );
  }
}

class _LibraryView extends ConsumerStatefulWidget {
  const _LibraryView({required this.state});
  final LibraryState state;

  @override
  ConsumerState<_LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends ConsumerState<_LibraryView> {
  String _searchQuery = '';
  bool _isGridView = true;
  _SortOrder _sortOrder = _SortOrder.updatedAt;
  _LibFilter _filter = _LibFilter.all;

  @override
  void initState() {
    super.initState();
    // Schedule thumbnail generation for any notes that don't have a cached cover.
    // Runs in the background (serial queue), never blocks the UI.
    WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleMissingThumbnails());
  }

  @override
  void didUpdateWidget(_LibraryView old) {
    super.didUpdateWidget(old);
    // Re-schedule when note list changes (e.g. after library refresh).
    if (old.state.notes != widget.state.notes) {
      _scheduleMissingThumbnails();
    }
  }

  void _scheduleMissingThumbnails() {
    for (final note in widget.state.notes) {
      if (ThumbnailService.instance.hasCachedInMemory(note.id)) continue;
      final spec = note.firstPageSpec;
      if (spec == null) continue;
      ThumbnailService.instance.schedule(
        noteId: note.id,
        spec: spec,
        strokes: note.firstPageStrokes,
        shapes: note.firstPageShapes,
        texts: note.firstPageTexts,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final ctl = ref.read(libraryProvider.notifier);
    final wide = MediaQuery.sizeOf(context).width >= 720;

    final hasStatusBar = MediaQuery.viewPaddingOf(context).top > 0;
    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        bottom: false,
        top: hasStatusBar,
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TopBar(
            isGridView: _isGridView,
            sortOrder: _sortOrder,
            onSearch: (v) => setState(() => _searchQuery = v),
            onToggleView: () => setState(() => _isGridView = !_isGridView),
            onSortChanged: (s) => setState(() => _sortOrder = s),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (wide)
                  SizedBox(
                    width: 220,
                    child: _Sidebar(
                      state: widget.state,
                      filter: _filter,
                      onFilterChanged: (f) {
                        setState(() => _filter = f);
                        if (f == _LibFilter.all) {
                          ref.read(libraryProvider.notifier).navigateRoot();
                        }
                      },
                    ),
                  ),
                if (wide)
                  Container(width: 0.5, color: t.tbBorder),
                Expanded(
                  child: _MainArea(
                    state: widget.state,
                    searchQuery: _searchQuery,
                    isGridView: _isGridView,
                    sortOrder: _sortOrder,
                    filter: _filter,
                    onCreateFolder: () async {
                      final name = await noteeAskName(context, title: 'New folder');
                      if (name != null && name.isNotEmpty) {
                        await ctl.createFolder(name);
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
        ),
      ),
    );
  }
}

// ── Top bar ─────────────────────────────────────────────────────────────
class _TopBar extends ConsumerStatefulWidget {
  const _TopBar({
    required this.isGridView,
    required this.sortOrder,
    required this.onSearch,
    required this.onToggleView,
    required this.onSortChanged,
  });
  final bool isGridView;
  final _SortOrder sortOrder;
  final void Function(String) onSearch;
  final VoidCallback onToggleView;
  final void Function(_SortOrder) onSortChanged;

  @override
  ConsumerState<_TopBar> createState() => _TopBarState();
}

class _TopBarState extends ConsumerState<_TopBar> {
  final _newBtnKey = GlobalKey();
  final _viewMenuKey = GlobalKey();
  final _cloudBtnKey = GlobalKey();

  Future<void> _openNewItemMenu() async {
    final result = await showNoteeMenu<_LibAction>(
      context,
      anchorKey: _newBtnKey,
      items: const [
        NoteeMenuItem(
          label: '새 노트북',
          value: _LibAction.newNotebook,
          icon: NoteeIconWidget(NoteeIcon.page, size: 14),
        ),
        NoteeMenuItem(
          label: '새 폴더',
          value: _LibAction.newFolder,
          icon: NoteeIconWidget(NoteeIcon.folder, size: 14),
        ),
        NoteeMenuItem.separator(),
        NoteeMenuItem(
          label: 'PDF 가져오기',
          value: _LibAction.importPdf,
          icon: NoteeIconWidget(NoteeIcon.share, size: 14),
        ),
        NoteeMenuItem(
          label: 'GoodNotes 가져오기',
          value: _LibAction.importGoodNotes,
          icon: NoteeIconWidget(NoteeIcon.pen, size: 14),
        ),
        NoteeMenuItem(
          label: 'Notee 파일 가져오기',
          value: _LibAction.importNotee,
          icon: NoteeIconWidget(NoteeIcon.check, size: 14),
        ),
      ],
    );

    if (!mounted) return;
    final ctl = ref.read(libraryProvider.notifier);

    switch (result) {
      case _LibAction.newNotebook:
        final id = await ctl.createNotebook();
        ref.read(currentNoteIdProvider.notifier).state = id;
      case _LibAction.newFolder:
        final name = await noteeAskName(context, title: 'New folder');
        if (name != null && name.isNotEmpty) {
          await ctl.createFolder(name);
        }
      case _LibAction.importPdf:
        await _importPdf(context, ref);
      case _LibAction.importGoodNotes:
        await _importGoodNotes(context, ref);
      case _LibAction.importNotee:
        await _importNotee(context, ref);
      case null:
        break;
    }
  }

  Future<void> _importNotee(BuildContext ctx, WidgetRef ref) async {
    final imported = await NoteeImporter().pickAndImport();
    if (imported == null || !ctx.mounted) return;
    await ref.read(libraryProvider.notifier).createNotebookFromNoteeState(imported);
    if (!ctx.mounted) return;
    ScaffoldMessenger.of(ctx)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text('"${imported.note.title}" 가져오기 완료'),
        duration: const Duration(seconds: 3),
      ));
  }

  Future<void> _importGoodNotes(BuildContext ctx, WidgetRef ref) async {
    final progress = ValueNotifier<String>('GoodNotes 분석 중…');
    bool dialogOpen = false;
    showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: (dc) => ValueListenableBuilder<String>(
        valueListenable: progress,
        builder: (_, msg, __) => AlertDialog(
          content: Row(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(strokeWidth: 2),
            const SizedBox(width: 16),
            Text(msg),
          ]),
        ),
      ),
    ).then((_) => dialogOpen = false);
    dialogOpen = true;

    ImportedGoodNotes? imp;
    try {
      imp = await GoodNotesImporter().pickAndImport();
    } catch (e) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text('가져오기 실패: $e')),
        );
      }
    } finally {
      progress.dispose();
      if (dialogOpen && ctx.mounted) {
        Navigator.of(ctx, rootNavigator: true).pop();
      }
    }
    if (imp == null || !ctx.mounted) return;

    final ctl = ref.read(libraryProvider.notifier);
    final noteId = await ctl.createNotebookFromGoodNotes(imp);
    if (ctx.mounted) {
      ref.read(currentNoteIdProvider.notifier).state = noteId;
    }
  }

  Future<void> _importPdf(BuildContext ctx, WidgetRef ref) async {
    final progress = ValueNotifier<String>('PDF 분석 중…');
    bool dialogOpen = false;

    // Show progress dialog (fire-and-forget; we pop it manually).
    showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: (dc) => ValueListenableBuilder<String>(
        valueListenable: progress,
        builder: (_, msg, __) => AlertDialog(
          content: Row(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(strokeWidth: 2),
            const SizedBox(width: 16),
            Text(msg),
          ]),
        ),
      ),
    ).then((_) => dialogOpen = false);
    dialogOpen = true;

    ImportedPdf? imported;
    try {
      imported = await PdfImporter().pickAndImport(
        onProgress: (c, t) => progress.value = '페이지 렌더링 중… $c / $t',
      );
    } finally {
      progress.dispose();
      if (dialogOpen && ctx.mounted) {
        Navigator.of(ctx, rootNavigator: true).pop();
      }
    }

    if (imported == null || !ctx.mounted) return;

    final ctl = ref.read(libraryProvider.notifier);
    final noteId = await ctl.createNotebookFromPages(
      imported.pages,
      title: imported.title,
    );
    if (ctx.mounted) {
      ref.read(currentNoteIdProvider.notifier).state = noteId;
    }
  }

  Future<void> _openViewMenu() async {
    final t = NoteeProvider.of(context).tokens;
    final result = await showNoteePopover<String>(
      context,
      anchorKey: _viewMenuKey,
      placement: NoteePopoverPlacement.below,
      maxWidth: 200,
      builder: (ctx) => _ViewMenuContent(
        sortOrder: widget.sortOrder,
        isGridView: widget.isGridView,
        tokens: t,
      ),
    );
    if (!mounted || result == null) return;
    if (result == 'toggle') {
      widget.onToggleView();
    } else {
      final order = _SortOrder.values.firstWhere((s) => s.name == result, orElse: () => widget.sortOrder);
      widget.onSortChanged(order);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    return Container(
      height: 52,
      decoration: BoxDecoration(
        color: t.toolbar,
        border: Border(bottom: BorderSide(color: t.tbBorder, width: 0.5)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Row(children: [
        // Notee logo: rounded-square with three pen scratches.
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: t.ink,
            borderRadius: BorderRadius.circular(6),
          ),
          child: CustomPaint(painter: _LogoStrokes(t.page)),
        ),
        const SizedBox(width: 8),
        Text('Worstnote', style: Theme.of(context).textTheme.titleLarge),
        // Search field centred; buttons stay flush right.
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: _SearchField(onChanged: widget.onSearch),
            ),
          ),
        ),
        const SizedBox(width: 4),
        // Cloud sync status button.
        KeyedSubtree(
          key: _cloudBtnKey,
          child: _CloudButton(
            anchorKey: _cloudBtnKey,
          ),
        ),
        const SizedBox(width: 4),
        // View/sort menu button.
        KeyedSubtree(
          key: _viewMenuKey,
          child: IconButton(
            tooltip: '보기 및 정렬',
            icon: NoteeIconWidget(
              widget.isGridView ? NoteeIcon.grid : NoteeIcon.rows,
              size: 17,
              color: t.inkDim,
            ),
            onPressed: _openViewMenu,
          ),
        ),
        const SizedBox(width: 8),
        KeyedSubtree(
          key: _newBtnKey,
          child: FilledButton.icon(
            icon: const NoteeIconWidget(NoteeIcon.plus, size: 14, color: Colors.white),
            label: const Text('새 항목'),
            onPressed: _openNewItemMenu,
          ),
        ),
      ]),
    );
  }
}

class _LogoStrokes extends CustomPainter {
  _LogoStrokes(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 14;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(3 * s, 3.5 * s), Offset(11 * s, 4.5 * s), paint);
    canvas.drawLine(Offset(3 * s, 7 * s), Offset(9 * s, 7.5 * s), paint);
    canvas.drawLine(Offset(3 * s, 10 * s), Offset(11 * s, 10.5 * s), paint);
  }

  @override
  bool shouldRepaint(_LogoStrokes old) => old.color != color;
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.onChanged});
  final void Function(String) onChanged;
  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: t.bg,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: t.tbBorder, width: 0.5),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        NoteeIconWidget(NoteeIcon.search, size: 14, color: t.inkDim),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            onChanged: onChanged,
            style: TextStyle(fontSize: 12.5, color: t.ink),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: 'Search across all notebooks…',
              hintStyle: TextStyle(fontSize: 12.5, color: t.inkDim),
            ),
          ),
        ),
      ]),
    );
  }
}

// ── View / Sort menu content ─────────────────────────────────────────────
class _ViewMenuContent extends StatelessWidget {
  const _ViewMenuContent({
    required this.sortOrder,
    required this.isGridView,
    required this.tokens,
  });
  final _SortOrder sortOrder;
  final bool isGridView;
  final NoteeTokens tokens;

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
            child: Text('정렬', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.8, color: t.inkFaint)),
          ),
          for (final s in _SortOrder.values)
            _ViewMenuRow(
              label: s.label,
              trailing: s == sortOrder ? NoteeIconWidget(NoteeIcon.check, size: 13, color: t.accent) : const SizedBox(width: 13),
              onTap: () => Navigator.of(context).pop(s.name),
              t: t,
            ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 14),
            child: Container(height: 0.5, color: t.rule),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 2, 14, 6),
            child: Text('보기', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.8, color: t.inkFaint)),
          ),
          _ViewMenuRow(
            label: '그리드',
            trailing: isGridView ? NoteeIconWidget(NoteeIcon.check, size: 13, color: t.accent) : const SizedBox(width: 13),
            icon: NoteeIcon.grid,
            onTap: () => isGridView ? Navigator.of(context).pop(null) : Navigator.of(context).pop('toggle'),
            t: t,
          ),
          _ViewMenuRow(
            label: '리스트',
            trailing: !isGridView ? NoteeIconWidget(NoteeIcon.check, size: 13, color: t.accent) : const SizedBox(width: 13),
            icon: NoteeIcon.rows,
            onTap: () => !isGridView ? Navigator.of(context).pop(null) : Navigator.of(context).pop('toggle'),
            t: t,
          ),
        ],
      ),
    );
  }
}

class _ViewMenuRow extends StatelessWidget {
  const _ViewMenuRow({
    required this.label,
    required this.trailing,
    required this.onTap,
    required this.t,
    this.icon,
  });
  final String label;
  final Widget trailing;
  final VoidCallback onTap;
  final NoteeTokens t;
  final NoteeIcon? icon;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        color: Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            if (icon != null) ...[
              NoteeIconWidget(icon!, size: 14, color: t.inkDim),
              const SizedBox(width: 8),
            ] else const SizedBox(width: 22),
            Expanded(child: Text(label, style: TextStyle(fontSize: 13, color: t.ink, fontWeight: FontWeight.w500))),
            trailing,
          ],
        ),
      ),
    );
  }
}

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
                const _Eyebrow(text: 'Library'),
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

  static const _surfaces = [
    (NoteeSurface.paper, 'Paper', Color(0xFFF4EDE0)),
    (NoteeSurface.white, 'White', Color(0xFFFFFFFF)),
    (NoteeSurface.sepia, 'Sepia', Color(0xFFE8D9B8)),
    (NoteeSurface.dark, 'Dark', Color(0xFF1C1C1E)),
  ];

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
    // x: right of the Theme row; y: settings button baseline → bottom aligns with main menu
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
                  ..pop() // theme sub-popover
                  ..pop(); // main menu popover
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

// ─────────────────────────────────────────────────────────────────────────────

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
            // Center the icon vs the text's ink-line, not its line-height box.
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
            NoteeIconWidget(NoteeIcon.folder,
                size: 12, color: isSel ? t.accent : t.inkDim),
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
  final Set<String> _selectedIds = {};

  bool get _selectionMode => _selectedIds.isNotEmpty;

  void _toggleSelect(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _clearSelection() => setState(() => _selectedIds.clear());

  Future<void> _openNote(String id) async {
    debugPrint('[OpenNote] start id=$id');
    final lockService = ref.read(noteLockServiceProvider);
    final result = await lockService.acquire(id);
    debugPrint('[OpenNote] acquire returned $result mounted=$mounted');
    if (!mounted) return;
    ref.read(currentNoteIdProvider.notifier).state = id;
    debugPrint('[OpenNote] noteId set');
  }

  /// Sort a copy of [notes] according to [sortOrder].
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

    // Filter changes the data scope: favorites/recent flatten across all
    // folders; otherwise we honor the current folder hierarchy.
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
    // Apply user-chosen sort, except for the recent filter which is already
    // sorted by updatedAt.
    if (filter != _LibFilter.recent) notes = _sorted(notes);

    // fromLTRB(28,20,28,0) — the scroll view handles bottom inset itself.
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Breadcrumb(state: state),
          const SizedBox(height: 14),
          // Multi-select bar replaces header when items are selected.
          if (_selectionMode)
            _MultiSelectBar(
              count: _selectedIds.length,
              onClear: _clearSelection,
              onDelete: () async {
                final ok = await noteeConfirm(context,
                    title: '${_selectedIds.length}개 항목 삭제',
                    body: '선택한 항목이 모두 삭제됩니다.');
                if (ok) {
                  await ctl.bulkDelete(_selectedIds);
                  _clearSelection();
                }
              },
              onMove: () async {
                final folderId = await _pickFolder(context, ref);
                if (folderId != null && context.mounted) {
                  final target = folderId == '__root__' ? null : folderId;
                  await ctl.bulkMove(_selectedIds, target);
                  _clearSelection();
                }
              },
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
              // "New folder" lives in the top-bar "새 항목" menu now.
              if (false)
                TextButton.icon(
                  onPressed: widget.onCreateFolder,
                  icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                  label: const Text('New folder'),
                  style: TextButton.styleFrom(
                    textStyle: const TextStyle(
                      fontFamily: 'Inter Tight',
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
            ]),
          const SizedBox(height: 18),
          Expanded(
            child: (folders.isEmpty && notes.isEmpty)
                ? _EmptyState(onCreateFolder: widget.onCreateFolder)
                : isGridView
                    ? _GridContent(
                        folders: folders,
                        notes: notes,
                        selectedIds: _selectedIds,
                        onOpenFolder: ctl.navigateInto,
                        onFolderAction: (f) =>
                            _showFolderActions(context, ref, f),
                        onOpenNote: (id) {
                          if (_selectionMode) {
                            _toggleSelect(id);
                          } else {
                            _openNote(id);
                          }
                        },
                        onNoteAction: (n) =>
                            _showNotebookActions(context, ref, n),
                        onFolderContext: (f, pos) =>
                            _showFolderContextMenu(context, ref, f, pos),
                        onNoteContext: (n, pos) =>
                            _showNoteContextMenu(context, ref, n, pos),
                        onToggleSelect: _toggleSelect,
                      )
                    : _ListContent(
                        folders: folders,
                        notes: notes,
                        selectedIds: _selectedIds,
                        onOpenFolder: ctl.navigateInto,
                        onFolderAction: (f) =>
                            _showFolderActions(context, ref, f),
                        onOpenNote: (id) {
                          if (_selectionMode) {
                            _toggleSelect(id);
                          } else {
                            _openNote(id);
                          }
                        },
                        onNoteAction: (n) =>
                            _showNotebookActions(context, ref, n),
                        onFolderContext: (f, pos) =>
                            _showFolderContextMenu(context, ref, f, pos),
                        onNoteContext: (n, pos) =>
                            _showNoteContextMenu(context, ref, n, pos),
                        onToggleSelect: _toggleSelect,
                      ),
          ),
        ],
      ),
    );
  }
}

// ── Grid view ─────────────────────────────────────────────────────────
class _GridContent extends StatelessWidget {
  const _GridContent({
    required this.folders,
    required this.notes,
    required this.onOpenFolder,
    required this.onFolderAction,
    required this.onOpenNote,
    required this.onNoteAction,
    required this.onToggleSelect,
    this.selectedIds = const {},
    this.onFolderContext,
    this.onNoteContext,
  });
  final List<Folder> folders;
  final List<NoteSummary> notes;
  final Set<String> selectedIds;
  final void Function(String) onOpenFolder;
  final void Function(Folder) onFolderAction;
  final void Function(String) onOpenNote;
  final void Function(NoteSummary) onNoteAction;
  final void Function(String id) onToggleSelect;
  final void Function(Folder, Offset)? onFolderContext;
  final void Function(NoteSummary, Offset)? onNoteContext;

  @override
  Widget build(BuildContext context) {
    return GridView(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        mainAxisExtent: 300,
        crossAxisSpacing: 28,
        mainAxisSpacing: 28,
      ),
      padding: const EdgeInsets.only(top: 8, bottom: 72),
      children: [
        for (final f in folders)
          _FolderTile(
            folder: f,
            onOpen: () => onOpenFolder(f.id),
            onLongPress: () => onFolderAction(f),
            onContextMenu: onFolderContext == null
                ? null
                : (pos) => onFolderContext!(f, pos),
          ),
        for (final n in notes)
          _SelectableWrapper(
            key: ValueKey(n.id),
            id: n.id,
            selected: selectedIds.contains(n.id),
            onToggleSelect: onToggleSelect,
            child: _NotebookCover(
              note: n,
              onTap: () => onOpenNote(n.id),
              onLongPress: () => onNoteAction(n),
              onContextMenu: onNoteContext == null
                  ? null
                  : (pos) => onNoteContext!(n, pos),
            ),
          ),
      ],
    );
  }
}

// ── List / rows view ──────────────────────────────────────────────────
class _ListContent extends StatelessWidget {
  const _ListContent({
    required this.folders,
    required this.notes,
    required this.onOpenFolder,
    required this.onFolderAction,
    required this.onOpenNote,
    required this.onNoteAction,
    required this.onToggleSelect,
    this.selectedIds = const {},
    this.onFolderContext,
    this.onNoteContext,
  });
  final List<Folder> folders;
  final List<NoteSummary> notes;
  final Set<String> selectedIds;
  final void Function(String) onOpenFolder;
  final void Function(Folder) onFolderAction;
  final void Function(String) onOpenNote;
  final void Function(NoteSummary) onNoteAction;
  final void Function(String id) onToggleSelect;
  final void Function(Folder, Offset)? onFolderContext;
  final void Function(NoteSummary, Offset)? onNoteContext;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(left: 16, right: 16, bottom: 72),
      children: [
        for (final f in folders) ...[
          _FolderListTile(
            folder: f,
            onOpen: () => onOpenFolder(f.id),
            onLongPress: () => onFolderAction(f),
            onContextMenu: onFolderContext == null
                ? null
                : (pos) => onFolderContext!(f, pos),
          ),
          const _ListDivider(),
        ],
        for (final n in notes) ...[
          _SelectableWrapper(
            key: ValueKey(n.id),
            id: n.id,
            selected: selectedIds.contains(n.id),
            onToggleSelect: onToggleSelect,
            child: _NoteListTile(
              note: n,
              onTap: () => onOpenNote(n.id),
              onLongPress: () => onNoteAction(n),
              onContextMenu: onNoteContext == null
                  ? null
                  : (pos) => onNoteContext!(n, pos),
            ),
          ),
          const _ListDivider(),
        ],
      ],
    );
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

/// Wraps a tile with Cmd+click selection support + selected highlight overlay.
class _SelectableWrapper extends StatelessWidget {
  const _SelectableWrapper({
    super.key,
    required this.id,
    required this.selected,
    required this.onToggleSelect,
    required this.child,
  });
  final String id;
  final bool selected;
  final void Function(String id) onToggleSelect;
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

/// Toolbar shown above the content when items are selected.
class _MultiSelectBar extends StatelessWidget {
  const _MultiSelectBar({
    required this.count,
    required this.onClear,
    required this.onDelete,
    required this.onMove,
  });
  final int count;
  final VoidCallback onClear;
  final VoidCallback onDelete;
  final VoidCallback onMove;

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.close),
          onPressed: onClear,
          iconSize: 18,
          color: t.inkDim,
          tooltip: '선택 해제',
        ),
        const SizedBox(width: 4),
        Text(
          '$count개 선택됨',
          style: TextStyle(
            fontFamily: 'Inter Tight',
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: t.ink,
          ),
        ),
        const Spacer(),
        TextButton.icon(
          onPressed: onMove,
          icon: const Icon(Icons.drive_file_move_outline, size: 16),
          label: const Text('이동'),
          style: TextButton.styleFrom(
            textStyle: const TextStyle(
              fontFamily: 'Inter Tight',
              fontSize: 13,
            ),
          ),
        ),
        const SizedBox(width: 4),
        TextButton.icon(
          onPressed: onDelete,
          icon: const Icon(Icons.delete_outline, size: 16),
          label: const Text('삭제'),
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFFEF4444),
            textStyle: const TextStyle(
              fontFamily: 'Inter Tight',
              fontSize: 13,
            ),
          ),
        ),
      ],
    );
  }
}

class _FolderListTile extends StatelessWidget {
  const _FolderListTile({
    required this.folder,
    required this.onOpen,
    required this.onLongPress,
    this.onContextMenu,
  });
  final Folder folder;
  final VoidCallback onOpen;
  final VoidCallback onLongPress;
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
    required this.onLongPress,
    this.onContextMenu,
  });
  final NoteSummary note;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final void Function(Offset globalPos)? onContextMenu;

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final bg = note.firstPageSpec?.background ?? const PageBackground.blank();
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
          // Mini cover thumbnail — sized to the actual page aspect ratio,
          // capped at 60pt tall.
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
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
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
    required this.onLongPress,
    this.onContextMenu,
  });
  final Folder folder;
  final VoidCallback onOpen;
  final VoidCallback onLongPress;
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
                  return Stack(children: [
                    // Back tab
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
                    // Body
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
                    // Paper peek (rotated -1deg)
                    Positioned(
                      left: 14,
                      right: 14,
                      top: 18,
                      bottom: 16,
                      child: Transform.rotate(
                        angle: -0.0175,
                        child: Container(
                          decoration: BoxDecoration(
                            color: t.page.withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(2),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.12),
                                blurRadius: 2,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // Top paper
                    Positioned(
                      left: 18,
                      right: 22,
                      top: 22,
                      bottom: 20,
                      child: Container(
                        decoration: BoxDecoration(
                          color: t.page,
                          borderRadius: BorderRadius.circular(2),
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

// ── Notebook cover ─────────────────────────────────────────────────────
// Shows the first page's background pattern as the cover thumbnail.
// A star button (top-right) toggles favorite status instantly.
class _NotebookCover extends ConsumerWidget {
  const _NotebookCover({
    required this.note,
    required this.onTap,
    required this.onLongPress,
    this.onContextMenu,
  });
  final NoteSummary note;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final void Function(Offset globalPos)? onContextMenu;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = NoteeProvider.of(context).tokens;
    final bg = note.firstPageSpec?.background ?? const PageBackground.blank();
    // Use the actual page aspect ratio so the thumbnail mirrors the page
    // dimensions 1:1. Falls back to a portrait ratio for legacy notes.
    final spec = note.firstPageSpec;
    final pageAspect = (spec != null && spec.heightPt > 0)
        ? spec.widthPt / spec.heightPt
        : 0.74;

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTapDown: onContextMenu == null
          ? null
          : (d) => onContextMenu!.call(d.globalPosition),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: pageAspect,
                  child: Container(
                    decoration: BoxDecoration(
                      color: t.page,
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: [
                        BoxShadow(color: t.pageEdge, spreadRadius: 0.5),
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.14),
                          blurRadius: 18,
                          offset: const Offset(0, 8),
                        ),
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.07),
                          blurRadius: 3,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(children: [
                    Positioned.fill(child: _CoverContent(note: note)),
                    // Cloud sync badge — top-left corner.
                    Positioned(
                      left: 6,
                      top: 6,
                      child: _CloudBadge(noteId: note.id),
                    ),
                    // Favorite star — top-right corner.
                    Positioned(
                      right: 6,
                      top: 6,
                      child: GestureDetector(
                        onTap: () => ref
                            .read(libraryProvider.notifier)
                            .toggleFavorite(note.id),
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: note.isFavorite
                                ? Colors.amber.withValues(alpha: 0.22)
                                : Colors.black.withValues(alpha: 0.10),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            note.isFavorite
                                ? Icons.star_rounded
                                : Icons.star_border_rounded,
                            size: 14,
                            color: note.isFavorite
                                ? Colors.amber
                                : Colors.white.withValues(alpha: 0.8),
                          ),
                        ),
                      ),
                    ),
                    ]),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              note.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Inter Tight',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: t.ink,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              '${note.pageCount} pages · ${_relTime(note.updatedAt)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Inter Tight',
                fontSize: 11,
                color: t.inkDim,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Unified cover content ─────────────────────────────────────────────
// Tries to show a pre-generated PNG thumbnail from ThumbnailService.
// Falls back to live painters while the cache is cold or not yet generated.
class _CoverContent extends StatefulWidget {
  const _CoverContent({required this.note});
  final NoteSummary note;

  @override
  State<_CoverContent> createState() => _CoverContentState();
}

class _CoverContentState extends State<_CoverContent> {
  Uint8List? _bytes;
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    _load();
    // Refresh when ThumbnailService finishes generating this note's cover.
    _sub = ThumbnailService.instance.onCoverGenerated.listen((noteId) {
      if (mounted && noteId == widget.note.id && _bytes == null) _load();
    });
  }

  @override
  void didUpdateWidget(_CoverContent old) {
    super.didUpdateWidget(old);
    if (old.note.id != widget.note.id) {
      _bytes = null;
      _load();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final bytes = await ThumbnailService.instance.getCached(widget.note.id);
    if (mounted && bytes != null) setState(() => _bytes = bytes);
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes != null) {
      return Image.memory(bytes, fit: BoxFit.fill);
    }

    // Fallback: live painters while thumbnail is being generated.
    final note = widget.note;
    final spec = note.firstPageSpec;
    final bg = spec?.background ?? const PageBackground.blank();
    return Stack(children: [
      Positioned.fill(
        child: CustomPaint(painter: BackgroundPainter(background: bg)),
      ),
      if (bg is ImageBackground || bg is PdfBackground)
        Positioned.fill(
          child: LayoutBuilder(
            builder: (_, c) => BackgroundImageLayer(
              background: bg,
              size: Size(c.maxWidth, c.maxHeight),
            ),
          ),
        ),
      if (spec != null) ...[
        if (note.firstPageStrokes.isNotEmpty)
          Positioned.fill(
            child: CustomPaint(
              painter: _CoverStrokesPainter(
                  spec: spec, strokes: note.firstPageStrokes),
            ),
          ),
        if (note.firstPageShapes.isNotEmpty)
          Positioned.fill(
            child: CustomPaint(
              painter: _CoverShapesPainter(
                  spec: spec, shapes: note.firstPageShapes),
            ),
          ),
        if (note.firstPageTexts.isNotEmpty)
          Positioned.fill(
            child: _CoverTextsPainter(
                spec: spec, texts: note.firstPageTexts),
          ),
        // Tape on top of everything.
        if (note.firstPageStrokes.any((s) => !s.deleted && s.tool == ToolKind.tape))
          Positioned.fill(
            child: CustomPaint(
              painter: _CoverTapePainter(
                  spec: spec, strokes: note.firstPageStrokes),
            ),
          ),
      ],
    ]);
  }
}

// ── Cover strokes painter ─────────────────────────────────────────────
// Renders the first page's committed strokes at the thumbnail scale so the
// library cover shows actual note content rather than just the background.
class _CoverStrokesPainter extends CustomPainter {
  const _CoverStrokesPainter({required this.spec, required this.strokes});

  final PageSpec spec;
  final List<Stroke> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    if (strokes.isEmpty) return;
    final sx = size.width / spec.widthPt;
    final sy = size.height / spec.heightPt;
    _paintPass(canvas, sx, sy, tapeOnly: false);
    _paintPass(canvas, sx, sy, tapeOnly: true);
  }

  void _paintPass(Canvas canvas, double sx, double sy, {required bool tapeOnly}) {
    for (final stroke in strokes) {
      if (stroke.deleted || stroke.points.length < 2) continue;
      final isTape = stroke.tool == ToolKind.tape;
      if (tapeOnly && !isTape) continue;
      if (!tapeOnly && isTape) continue;
      final paint = Paint()
        ..color = Color(stroke.colorArgb).withValues(alpha: isTape ? 1.0 : stroke.opacity)
        ..strokeWidth = isTape
            ? (stroke.widthPt * sx).clamp(0.4, double.infinity)
            : (stroke.widthPt * sx).clamp(0.4, 6.0)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      final path = Path()
        ..moveTo(stroke.points.first.x * sx, stroke.points.first.y * sy);
      for (final pt in stroke.points.skip(1)) {
        path.lineTo(pt.x * sx, pt.y * sy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_CoverStrokesPainter old) =>
      !identical(old.strokes, strokes) || old.spec != spec;
}

class _CoverTapePainter extends CustomPainter {
  const _CoverTapePainter({required this.spec, required this.strokes});

  final PageSpec spec;
  final List<Stroke> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / spec.widthPt;
    final sy = size.height / spec.heightPt;
    for (final s in strokes) {
      if (s.deleted || s.points.length < 2 || s.tool != ToolKind.tape) continue;
      final paint = Paint()
        ..color = Color(s.colorArgb)
        ..strokeWidth = (s.widthPt * sx).clamp(0.4, double.infinity)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      final path = Path()
        ..moveTo(s.points.first.x * sx, s.points.first.y * sy);
      for (final pt in s.points.skip(1)) {
        path.lineTo(pt.x * sx, pt.y * sy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_CoverTapePainter old) =>
      !identical(old.strokes, strokes) || old.spec != spec;
}

class _CoverShapesPainter extends CustomPainter {
  const _CoverShapesPainter({required this.spec, required this.shapes});

  final PageSpec spec;
  final List<ShapeObject> shapes;

  @override
  void paint(Canvas canvas, Size size) {
    if (shapes.isEmpty) return;
    final sx = size.width / spec.widthPt;
    final sy = size.height / spec.heightPt;
    canvas.save();
    canvas.scale(sx, sy);
    for (final s in shapes) {
      if (s.deleted) continue;
      final rect = Rect.fromLTRB(s.bbox.minX, s.bbox.minY, s.bbox.maxX, s.bbox.maxY);
      final sp = Paint()
        ..color = Color(s.colorArgb)
        ..style = PaintingStyle.stroke
        ..strokeWidth = s.strokeWidthPt
        ..isAntiAlias = true;
      if (s.shape == ShapeKind.arrow) {
        _drawArrow(canvas, rect, s.arrowFlipX, s.arrowFlipY, sp);
        continue;
      }
      if (s.shape == ShapeKind.line) {
        final aPt = Offset(
          s.arrowFlipX ? rect.right : rect.left,
          s.arrowFlipY ? rect.bottom : rect.top,
        );
        final bPt = Offset(
          s.arrowFlipX ? rect.left : rect.right,
          s.arrowFlipY ? rect.top : rect.bottom,
        );
        canvas.drawLine(aPt, bPt, sp);
        continue;
      }
      if (s.filled) {
        final fc = s.fillColorArgb != null ? Color(s.fillColorArgb!) : Color(s.colorArgb);
        final fp = Paint()..color = fc..style = PaintingStyle.fill..isAntiAlias = true;
        switch (s.shape) {
          case ShapeKind.rectangle:
            canvas.drawRect(rect, fp);
          case ShapeKind.ellipse:
            canvas.drawOval(rect, fp);
          case ShapeKind.triangle:
            canvas.drawPath(Path()
              ..moveTo(rect.center.dx, rect.top)
              ..lineTo(rect.right, rect.bottom)
              ..lineTo(rect.left, rect.bottom)
              ..close(), fp);
          case ShapeKind.diamond:
            canvas.drawPath(Path()
              ..moveTo(rect.center.dx, rect.top)
              ..lineTo(rect.right, rect.center.dy)
              ..lineTo(rect.center.dx, rect.bottom)
              ..lineTo(rect.left, rect.center.dy)
              ..close(), fp);
          case ShapeKind.arrow:
          case ShapeKind.line:
            break;
        }
      }
      switch (s.shape) {
        case ShapeKind.rectangle:
          canvas.drawRect(rect, sp);
        case ShapeKind.ellipse:
          canvas.drawOval(rect, sp);
        case ShapeKind.triangle:
          final path = Path()
            ..moveTo(rect.center.dx, rect.top)
            ..lineTo(rect.right, rect.bottom)
            ..lineTo(rect.left, rect.bottom)
            ..close();
          canvas.drawPath(path, sp);
        case ShapeKind.diamond:
          final path = Path()
            ..moveTo(rect.center.dx, rect.top)
            ..lineTo(rect.right, rect.center.dy)
            ..lineTo(rect.center.dx, rect.bottom)
            ..lineTo(rect.left, rect.center.dy)
            ..close();
          canvas.drawPath(path, sp);
        case ShapeKind.arrow:
        case ShapeKind.line:
          break; // handled above
      }
    }
    canvas.restore();
  }

  static void _drawArrow(
      Canvas canvas, Rect rect, bool flipX, bool flipY, Paint stroke) {
    final tail = Offset(
      flipX ? rect.right : rect.left,
      flipY ? rect.bottom : rect.top,
    );
    final head = Offset(
      flipX ? rect.left : rect.right,
      flipY ? rect.top : rect.bottom,
    );
    final dx = head.dx - tail.dx;
    final dy = head.dy - tail.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1) return;
    final ux = dx / len;
    final uy = dy / len;
    const headLen = 18.0;
    const headW = 9.0;
    final bx = head.dx - ux * headLen;
    final by = head.dy - uy * headLen;
    final perpX = -uy * headW;
    final perpY = ux * headW;
    canvas.drawLine(tail, head, stroke);
    canvas.drawLine(head, Offset(bx + perpX, by + perpY), stroke);
    canvas.drawLine(head, Offset(bx - perpX, by - perpY), stroke);
  }

  @override
  bool shouldRepaint(_CoverShapesPainter old) =>
      !identical(old.shapes, shapes) || old.spec != spec;
}

class _CoverTextsPainter extends StatelessWidget {
  const _CoverTextsPainter({required this.spec, required this.texts});

  final PageSpec spec;
  final List<TextBoxObject> texts;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, constraints) {
        final sx = constraints.maxWidth / spec.widthPt;
        final sy = constraints.maxHeight / spec.heightPt;
        return CustomPaint(
          painter: _CoverTextsCanvasPainter(spec: spec, texts: texts, sx: sx, sy: sy),
        );
      },
    );
  }
}

class _CoverTextsCanvasPainter extends CustomPainter {
  const _CoverTextsCanvasPainter({
    required this.spec,
    required this.texts,
    required this.sx,
    required this.sy,
  });

  final PageSpec spec;
  final List<TextBoxObject> texts;
  final double sx, sy;

  @override
  void paint(Canvas canvas, Size size) {
    for (final t in texts) {
      if (t.deleted || t.text.isEmpty) continue;
      final x = t.bbox.minX * sx;
      final y = t.bbox.minY * sy;
      final w = (t.bbox.maxX - t.bbox.minX) * sx;
      final tp = TextPainter(
        text: TextSpan(
          text: t.text,
          style: TextStyle(
            fontSize: (t.fontSizePt * sy).clamp(6.0, 24.0),
            color: Color(t.colorArgb),
            fontFamily: t.fontFamily,
            fontWeight: FontWeight.values.firstWhere(
              (fw) => fw.value == t.fontWeight,
              orElse: () => FontWeight.w400,
            ),
            fontStyle: t.italic ? FontStyle.italic : FontStyle.normal,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 5,
        ellipsis: '…',
      )
        ..layout(maxWidth: w.clamp(10.0, double.infinity));
      tp.paint(canvas, Offset(x, y));
    }
  }

  @override
  bool shouldRepaint(_CoverTextsCanvasPainter old) =>
      !identical(old.texts, texts) || old.sx != sx || old.sy != sy;
}

// ── Helpers ──────────────────────────────────────────────────────────

void _showFolderActions(BuildContext context, WidgetRef ref, Folder f) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('이름 수정'),
            onTap: () async {
              Navigator.pop(context);
              final name = await noteeAskName(context,
                  title: '폴더 이름 수정',
                  initial: f.name,
                  confirmLabel: '저장');
              if (name != null && name.trim().isNotEmpty) {
                await ref
                    .read(libraryProvider.notifier)
                    .renameFolder(f.id, name.trim());
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.color_lens_outlined),
            title: const Text('색상/아이콘 변경'),
            onTap: () async {
              Navigator.pop(context);
              if (!context.mounted) return;
              final result = await showDialog<(int, String)>(
                context: context,
                builder: (_) => _FolderAppearanceDialog(
                  initialColor: f.colorArgb,
                  initialIconKey: f.iconKey,
                ),
              );
              if (result != null) {
                await ref
                    .read(libraryProvider.notifier)
                    .updateFolderAppearance(f.id, result.$1, result.$2);
              }
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
            title: const Text('삭제',
                style: TextStyle(color: Colors.redAccent)),
            onTap: () async {
              Navigator.pop(context);
              if (!context.mounted) return;
              final ok = await noteeConfirm(context,
                  title: '"${f.name}" 삭제',
                  body: '폴더, 하위 폴더, 모든 노트북이 삭제됩니다.');
              if (ok) {
                await ref.read(libraryProvider.notifier).deleteFolder(f.id);
              }
            },
          ),
        ],
      ),
    ),
  );
}

void _showNotebookActions(
    BuildContext context, WidgetRef ref, NoteSummary n) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => SafeArea(
      child: SingleChildScrollView(child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('이름 수정'),
            onTap: () async {
              Navigator.pop(context);
              final name = await noteeAskName(context,
                  title: '노트 이름 수정',
                  initial: n.title,
                  confirmLabel: '저장');
              if (name != null && name.trim().isNotEmpty) {
                await ref
                    .read(libraryProvider.notifier)
                    .renameNotebook(n.id, name.trim());
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.copy_rounded),
            title: const Text('복제'),
            onTap: () async {
              Navigator.pop(context);
              await ref.read(libraryProvider.notifier).duplicateNotebook(n.id);
            },
          ),
          ListTile(
            leading: const Icon(Icons.drive_file_move_outline),
            title: const Text('이동'),
            onTap: () async {
              Navigator.pop(context);
              if (!context.mounted) return;
              final folderId =
                  await _pickFolder(context, ref, currentFolderId: n.folderId);
              if (folderId != null) {
                final target = folderId == '__root__' ? null : folderId;
                await ref
                    .read(libraryProvider.notifier)
                    .moveNotebook(n.id, target);
              }
            },
          ),
          ListTile(
            leading: Icon(
              n.isFavorite ? Icons.star_rounded : Icons.star_border_rounded,
              color: n.isFavorite ? Colors.amber : null,
            ),
            title: Text(n.isFavorite ? '즐겨찾기 해제' : '즐겨찾기 추가'),
            onTap: () {
              Navigator.pop(context);
              ref.read(libraryProvider.notifier).toggleFavorite(n.id);
            },
          ),
          ListTile(
            leading: const Icon(Icons.ios_share_rounded),
            title: const Text('내보내기'),
            onTap: () async {
              Navigator.pop(context);
              if (!context.mounted) return;
              final repo = ref.read(repositoryProvider);
              final nbState = await repo.loadByNoteId(n.id);
              if (nbState == null || !context.mounted) return;
              final path = await ExportDialog.show(context, nbState,
                  suggestedName: n.title);
              if (path != null && context.mounted) {
                ScaffoldMessenger.of(context)
                  ..clearSnackBars()
                  ..showSnackBar(SnackBar(
                    content: Text('저장됨: $path'),
                    duration: const Duration(seconds: 4),
                    action: SnackBarAction(
                      label: '닫기',
                      onPressed: () =>
                          ScaffoldMessenger.of(context).hideCurrentSnackBar(),
                    ),
                  ));
              }
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
            title: const Text('삭제',
                style: TextStyle(color: Colors.redAccent)),
            onTap: () async {
              Navigator.pop(context);
              if (!context.mounted) return;
              final ok = await noteeConfirm(context,
                  title: '"${n.title}" 삭제',
                  body: '모든 페이지와 스트로크가 삭제됩니다.');
              if (ok) {
                await ref.read(libraryProvider.notifier).deleteNotebook(n.id);
              }
            },
          ),
        ],
      )),
    ),
  );
}

String _relTime(DateTime t) {
  final d = DateTime.now().toUtc().difference(t.toUtc());
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 7) return '${d.inDays}d ago';
  return '${(d.inDays / 7).round()}w ago';
}

// ── Right-click context menus ─────────────────────────────────────────
enum _NoteCtx { rename, duplicate, move, favorite, export, delete }
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
  final ctl = ref.read(libraryProvider.notifier);
  switch (result) {
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
        // ('__root__' sentinel = root)
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
      final path = await ExportDialog.show(context, nbState,
          suggestedName: n.title);
      if (path != null && context.mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(
            content: Text('저장됨: $path'),
            duration: const Duration(seconds: 4),
            action: SnackBarAction(
              label: '닫기',
              onPressed: () =>
                  ScaffoldMessenger.of(context).hideCurrentSnackBar(),
            ),
          ));
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
}) async {
  final lib = ref.read(libraryProvider).value;
  if (lib == null) return null;
  final t = NoteeProvider.of(context).tokens;

  return showDialog<String>(
    context: context,
    builder: (_) => Dialog(
      backgroundColor: t.toolbar,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320, maxHeight: 420),
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
                      selected: currentFolderId == null,
                      onTap: () => Navigator.of(context).pop('__root__'),
                    ),
                    for (final (f, depth)
                        in _buildFolderTree(lib.folders, null, 0))
                      Padding(
                        padding: EdgeInsets.only(left: depth * 16.0),
                        child: ListTile(
                          dense: true,
                          leading: Icon(
                            _folderIconFor(f.iconKey),
                            color: Color(f.colorArgb),
                          ),
                          title: Text(
                            f.name,
                            style: TextStyle(
                              fontFamily: 'Inter Tight',
                              color: t.ink,
                            ),
                          ),
                          selected: currentFolderId == f.id,
                          onTap: () => Navigator.of(context).pop(f.id),
                        ),
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
    ),
  );
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
              // Color grid
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
              // Icon grid
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

    // Drive spinner while checking or syncing.
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

    // This note is actively being synced right now.
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

class _CloudPopover extends ConsumerWidget {
  const _CloudPopover({required this.tokens});
  final NoteeTokens tokens;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = tokens;
    final cloud = ref.watch(cloudSyncProvider);
    ref.watch(authProvider); // reactive rebuild on login/logout

    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status header.
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

          // Server URL.
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

          // Last checked.
          if (cloud.lastCheckedAt != null) ...[
            const SizedBox(height: 4),
            Text(
              '마지막 확인: ${_relativeTime(cloud.lastCheckedAt!)}',
              style: TextStyle(color: t.inkFaint, fontSize: 11),
            ),
          ],

          // Last sync stats.
          if (cloud.lastSyncTotal != null) ...[
            const SizedBox(height: 4),
            Text(
              '마지막 동기화: ${cloud.lastSyncTotal}개 노트, ${cloud.lastSyncPushed}개 항목 업로드',
              style: TextStyle(color: t.inkFaint, fontSize: 11),
            ),
          ],

          // Error message.
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

          // Actions.
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
