part of 'toolbar.dart';

// ── Text button (opens format bar when active) ───────────────────────
class _TextButton extends ConsumerStatefulWidget {
  @override
  ConsumerState<_TextButton> createState() => _TextButtonState();
}

class _TextButtonState extends ConsumerState<_TextButton> {
  final _key = GlobalKey();
  VoidCallback? _dismiss;
  bool _barOpen = false;

  @override
  void dispose() {
    _dismiss?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = NoteeProvider.of(context).tokens;
    final active =
        ref.watch(toolProvider.select((s) => s.activeTool == AppTool.text));

    ref.listen(toolProvider.select((s) => s.activeTool), (_, next) {
      if (next == AppTool.text && !_barOpen) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) { if (mounted) _openBar(); });
      } else if (next != AppTool.text && _barOpen) {
        _closeBar();
      }
    });

    return _GlyphButton(
      anchorKey: _key,
      active: active,
      onTap: () {
        if (active) {
          // Bar should always be visible while text is active — just re-anchor
          // it if somehow closed.
          if (!_barOpen) _openBar();
        } else {
          ref.read(toolProvider.notifier).setTool(AppTool.text);
        }
      },
      child: NoteeIconWidget(NoteeIcon.text,
          size: 15, color: active ? t.accent : t.ink),
    );
  }

  void _openBar() {
    if (_barOpen || !mounted) return;
    final dismiss = showNoteePassthroughPopover(
      context,
      anchorKey: _key,
      maxWidth: null, // size to the row's intrinsic width — no clipping
      placement: toolbarPopoverPlacement(ref),
      onDismiss: () {
        if (!mounted) return;
        setState(() { _dismiss = null; _barOpen = false; });
      },
      builder: (ctx, dismiss) => _TextFormatBarBody(dismiss: dismiss),
    );
    setState(() { _dismiss = dismiss; _barOpen = true; });
  }

  void _closeBar() {
    _dismiss?.call();
    if (mounted) setState(() { _dismiss = null; _barOpen = false; });
  }
}

/// A tap-to-type font-size widget used inside the text format bar.
class _FontSizeInput extends StatefulWidget {
  const _FontSizeInput({
    required this.value,
    required this.onChanged,
    required this.color,
  });
  final double value;
  final void Function(double) onChanged;
  final Color color;
  @override
  State<_FontSizeInput> createState() => _FontSizeInputState();
}

class _FontSizeInputState extends State<_FontSizeInput> {
  late final TextEditingController _ctl;
  late final FocusNode _node;

  @override
  void initState() {
    super.initState();
    _ctl = TextEditingController(text: widget.value.round().toString());
    _node = FocusNode();
    _node.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant _FontSizeInput old) {
    super.didUpdateWidget(old);
    if (!_node.hasFocus && widget.value.round().toString() != _ctl.text) {
      _ctl.text = widget.value.round().toString();
    }
  }

  @override
  void dispose() {
    _node.removeListener(_onFocusChange);
    _node.dispose();
    _ctl.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!_node.hasFocus) _commit();
  }

  void _commit() {
    final v = double.tryParse(_ctl.text);
    if (v == null) {
      _ctl.text = widget.value.round().toString();
      return;
    }
    final clamped = v.clamp(8.0, 200.0);
    if (clamped != widget.value) widget.onChanged(clamped);
    _ctl.text = clamped.round().toString();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 22,
      child: TextField(
        controller: _ctl,
        focusNode: _node,
        textAlign: TextAlign.center,
        keyboardType: TextInputType.number,
        style: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 12,
          color: widget.color,
          fontWeight: FontWeight.w600,
        ),
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.zero,
          border: InputBorder.none,
        ),
        onSubmitted: (_) => _commit(),
      ),
    );
  }
}

class _TextFormatBarBody extends ConsumerWidget {
  const _TextFormatBarBody({required this.dismiss});
  final VoidCallback dismiss;

  static const _families = <String, String>{
    // Use system fonts that are actually installed (we don't bundle font
    // assets) so the three options visibly differ. macOS / iOS resolve
    // these natively; other platforms fall back to a similar family.
    'Sans': 'Helvetica Neue',
    'Serif': 'Times New Roman',
    'Mono': 'Menlo',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(toolProvider);
    final ctl = ref.read(toolProvider.notifier);
    final t = NoteeProvider.of(context).tokens;

    final editingId = ref.watch(editingTextBoxIdProvider);
    TextBoxObject? editingBox;
    if (editingId != null) {
      final notebook = ref.read(notebookProvider);
      outer:
      for (final pageId in notebook.textsByPage.keys) {
        for (final b in notebook.textsByPage[pageId]!) {
          if (b.id == editingId && !b.deleted) {
            editingBox = b;
            break outer;
          }
        }
      }
    }
    final indicatorSize = editingBox?.fontSizePt ?? s.textFontSizePt;
    final indicatorWeight = editingBox?.fontWeight ?? s.textFontWeight;
    final indicatorFamily = editingBox?.fontFamily ?? s.textFontFamily;
    final indicatorItalic = editingBox?.italic ?? s.textItalic;
    final indicatorAlign = editingBox?.textAlign ?? s.textAlign;
    final indicatorBold = indicatorWeight >= 700;

    void applyToEditing(TextBoxObject Function(TextBoxObject) mutate) {
      final id = ref.read(editingTextBoxIdProvider);
      if (id == null) return;
      final notebook = ref.read(notebookProvider);
      for (final pageId in notebook.textsByPage.keys) {
        for (final box in notebook.textsByPage[pageId]!) {
          if (box.id != id || box.deleted) continue;
          final next = withRemeasuredHeight(
            mutate(box).copyWith(rev: box.rev + 1),
          );
          ref.read(notebookProvider.notifier).updateText(next);
          return;
        }
      }
    }

    Widget divider() => Container(
          width: 0.5, height: 18,
          margin: const EdgeInsets.symmetric(horizontal: 6),
          color: t.rule,
        );

    Widget fmtBtn({
      required IconData icon,
      required bool sel,
      required VoidCallback onTap,
      String? tooltip,
    }) {
      return Tooltip(
        message: tooltip ?? '',
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOut,
            width: 26, height: 26,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              color: sel ? t.accentSoft : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: sel ? t.accent.withValues(alpha: 0.6) : Colors.transparent,
                width: 0.5,
              ),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 15, color: sel ? t.accent : t.ink),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        GestureDetector(
          onTap: () {
            final v = (indicatorSize - 2).clamp(8.0, 96.0);
            ctl.setTextFontSize(v);
            applyToEditing((b) => b.copyWith(fontSizePt: v));
          },
          child: Icon(Icons.remove, size: 14, color: t.ink),
        ),
        _FontSizeInput(
          value: indicatorSize,
          onChanged: (v) {
            ctl.setTextFontSize(v);
            applyToEditing((b) => b.copyWith(fontSizePt: v));
          },
          color: t.ink,
        ),
        GestureDetector(
          onTap: () {
            final v = (indicatorSize + 2).clamp(8.0, 96.0);
            ctl.setTextFontSize(v);
            applyToEditing((b) => b.copyWith(fontSizePt: v));
          },
          child: Icon(Icons.add, size: 14, color: t.ink),
        ),
        divider(),
        for (final entry in _families.entries)
          GestureDetector(
            onTap: () {
              ctl.setTextFontFamily(entry.value);
              applyToEditing((b) => b.copyWith(fontFamily: entry.value));
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              margin: const EdgeInsets.symmetric(horizontal: 1),
              decoration: BoxDecoration(
                color: indicatorFamily == entry.value
                    ? t.accentSoft
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: indicatorFamily == entry.value
                    ? Border.all(
                        color: t.accent.withValues(alpha: 0.6), width: 0.5)
                    : null,
              ),
              child: Text(
                entry.key,
                style: TextStyle(
                  fontFamily: entry.value,
                  fontSize: 12,
                  color: indicatorFamily == entry.value ? t.accent : t.ink,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        divider(),
        fmtBtn(
          icon: Icons.format_bold_rounded,
          sel: indicatorBold,
          onTap: () {
            final w = indicatorBold ? 400 : 700;
            ctl.setTextFontWeight(w);
            applyToEditing((b) => b.copyWith(fontWeight: w));
          },
          tooltip: 'Bold',
        ),
        fmtBtn(
          icon: Icons.format_italic_rounded,
          sel: indicatorItalic,
          onTap: () {
            final v = !indicatorItalic;
            ctl.setTextItalic(v);
            applyToEditing((b) => b.copyWith(italic: v));
          },
          tooltip: 'Italic',
        ),
        divider(),
        fmtBtn(
          icon: Icons.format_align_left_rounded,
          sel: indicatorAlign == 0,
          onTap: () {
            ctl.setTextAlign(0);
            applyToEditing((b) => b.copyWith(textAlign: 0));
          },
          tooltip: 'Left',
        ),
        fmtBtn(
          icon: Icons.format_align_center_rounded,
          sel: indicatorAlign == 1,
          onTap: () {
            ctl.setTextAlign(1);
            applyToEditing((b) => b.copyWith(textAlign: 1));
          },
          tooltip: 'Center',
        ),
        fmtBtn(
          icon: Icons.format_align_right_rounded,
          sel: indicatorAlign == 2,
          onTap: () {
            ctl.setTextAlign(2);
            applyToEditing((b) => b.copyWith(textAlign: 2));
          },
          tooltip: 'Right',
        ),
      ]),
    );
  }
}
