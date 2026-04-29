part of 'library_screen.dart';

// ── Top bar ─────────────────────────────────────────────────────────────
class _TopBar extends ConsumerStatefulWidget {
  const _TopBar({
    required this.showMenuButton,
    required this.isGridView,
    required this.sortOrder,
    required this.onSearch,
    required this.onToggleView,
    required this.onSortChanged,
  });
  final bool showMenuButton;
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
  bool _searchExpanded = false;
  final _searchFocusNode = FocusNode();

  @override
  void dispose() {
    _searchFocusNode.dispose();
    super.dispose();
  }

  bool _hideLogo(BuildContext context) {
    if (!widget.showMenuButton) return false;
    if (_searchExpanded) return true;
    return MediaQuery.of(context).size.width < 380;
  }

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
        if (widget.showMenuButton) ...[
          Builder(
            builder: (ctx) => IconButton(
              icon: Icon(Icons.menu_rounded, size: 20, color: t.inkDim),
              tooltip: '메뉴',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              onPressed: () => Scaffold.of(ctx).openDrawer(),
            ),
          ),
          const SizedBox(width: 4),
        ],
        if (!_hideLogo(context)) ...[
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
        ],
        if (widget.showMenuButton && _searchExpanded) ...[
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: _SearchField(
                focusNode: _searchFocusNode,
                onChanged: widget.onSearch,
                onClose: () {
                  setState(() => _searchExpanded = false);
                  widget.onSearch('');
                },
              ),
            ),
          ),
        ] else ...[
          if (widget.showMenuButton)
            IconButton(
              icon: NoteeIconWidget(NoteeIcon.search, size: 17, color: t.inkDim),
              tooltip: '검색',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              onPressed: () {
                setState(() => _searchExpanded = true);
                Future.delayed(const Duration(milliseconds: 50), () {
                  if (mounted) _searchFocusNode.requestFocus();
                });
              },
            )
          else
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: _SearchField(onChanged: widget.onSearch),
                ),
              ),
            ),
          if (widget.showMenuButton) const Spacer(),
          const SizedBox(width: 4),
          KeyedSubtree(
            key: _cloudBtnKey,
            child: _CloudButton(anchorKey: _cloudBtnKey),
          ),
          const SizedBox(width: 4),
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
            child: widget.showMenuButton
                ? IconButton(
                    icon: const NoteeIconWidget(NoteeIcon.plus, size: 17, color: Colors.white),
                    style: IconButton.styleFrom(
                      backgroundColor: const Color(0xFF2563EB),
                      padding: const EdgeInsets.all(8),
                      minimumSize: const Size(36, 36),
                    ),
                    onPressed: _openNewItemMenu,
                  )
                : FilledButton.icon(
                    icon: const NoteeIconWidget(NoteeIcon.plus, size: 14, color: Colors.white),
                    label: const Text('새 항목'),
                    onPressed: _openNewItemMenu,
                  ),
          ),
        ],
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
  const _SearchField({
    super.key,
    required this.onChanged,
    this.focusNode,
    this.onClose,
  });
  final void Function(String) onChanged;
  final FocusNode? focusNode;
  final VoidCallback? onClose;

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
            focusNode: focusNode,
            onChanged: onChanged,
            style: TextStyle(fontSize: 12.5, color: t.ink),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: 'Search…',
              hintStyle: TextStyle(fontSize: 12.5, color: t.inkDim),
            ),
          ),
        ),
        if (onClose != null) ...[
          const SizedBox(width: 4),
          GestureDetector(
            onTap: onClose,
            child: Icon(Icons.close_rounded, size: 16, color: t.inkDim),
          ),
        ],
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
